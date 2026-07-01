-- LobbyServer (LOBBY PLACE ONLY) — walkable hub. Stand in a loading zone (any BasePart whose NAME starts
-- with "LoadingZone") to open the SELECTION menu: choose Map → Difficulty (gated by your progression) →
-- Party Size. Press PLAY to queue; a countdown runs and shortens to 3s once the party is full; at zero the
-- group teleports TOGETHER into a fresh private game server at that map/difficulty.
--
-- Progression (read from the shared DataStore): beat Easy → Medium unlocks → Hard → Nightmare; beating a
-- world's Nightmare unlocks the next world. Only Forest exists so far.
--
-- BUILD (you): a SpawnLocation + one or more Parts named "LoadingZone..." (the part's size is the trigger
-- volume). Sync with `rojo serve lobby.project.json`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ===== CONFIG (keep in sync with the game's GameConfig) =====
local GAME_PLACE_ID    = 140566663451993 -- the gameplay place (PLAY teleports here; the lobby is the START place)
local STORE_NAME       = "PlayerData_v2"
local DIFFS            = { "easy", "medium", "hard", "nightmare" }
local WORLDS           = { "forest" }
local COUNTDOWN        = 15
local FULL_PARTY_SECS  = 3
local V_MARGIN         = 6
local TICK             = 0.25
local TELEPORT_RETRIES = 4

Players.CharacterAutoLoads = true

local rng = Random.new()

-- ===== INVENTORY CATALOG =====
-- The lobby is self-contained (it can't require the game's Shared config), so the catalog lives here and is
-- SENT to the client for display. Add a weapon = add a WEAPONS entry (+ put it in a case pool to make it
-- droppable). TIERS: each weapon has a tier 1..TIER_COUNT; the loadout has one slot PER tier.
local TIER_COUNT = 5

local RARITY = {
	common    = { name = "Common",    color = { 165, 170, 180 } },
	uncommon  = { name = "Uncommon",  color = {  80, 200, 120 } },
	rare      = { name = "Rare",      color = {  70, 140, 255 } },
	epic      = { name = "Epic",      color = { 170,  90, 255 } },
	legendary = { name = "Legendary", color = { 255, 180,  40 } },
}

local WEAPONS = {
	pistol  = { name = "M1911",        tier = 1, rarity = "common" },
	shotgun = { name = "Pump Shotgun", tier = 2, rarity = "uncommon" },
	ak47    = { name = "AK-47",        tier = 3, rarity = "rare" },
	minigun = { name = "Minigun",      tier = 4, rarity = "epic" },
	raygun  = { name = "Ray Gun",      tier = 5, rarity = "legendary" },
}

local CASES = {
	standard = {
		name = "Standard Case",
		dupValue = 40, -- Coins refunded when you roll a weapon you already own
		pool = {
			{ id = "shotgun", weight = 48 },
			{ id = "ak47",    weight = 30 },
			{ id = "minigun", weight = 16 },
			{ id = "raygun",  weight = 6 },
		},
	},
}

local POTIONS = {
	luck = { name = "Luck Potion", rarity = "rare",     desc = "Boosts rare drops (coming soon)" },
	xp   = { name = "XP Potion",   rarity = "uncommon", desc = "Bonus run XP (coming soon)" },
}

-- Display catalog the client renders from (colors as {r,g,b} so it survives replication cleanly).
local CATALOG = {
	tierCount = TIER_COUNT,
	rarities = RARITY,
	weapons = WEAPONS,
	potions = POTIONS,
	cases = (function()
		local t = {}
		for id, c in CASES do
			local ids = {}
			for _, e in c.pool do
				table.insert(ids, e.id)
			end
			t[id] = { name = c.name, dupValue = c.dupValue, poolIds = ids }
		end
		return t
	end)(),
}

local function rollCase(caseId)
	local case = CASES[caseId]
	local total = 0
	for _, e in case.pool do
		total += e.weight
	end
	local r = rng:NextNumber(0, total)
	local acc = 0
	for _, e in case.pool do
		acc += e.weight
		if r <= acc then
			return e.id
		end
	end
	return case.pool[#case.pool].id
end

-- ===== REMOTES =====
local remotes = Instance.new("Folder")
remotes.Name = "LobbyRemotes"
remotes.Parent = ReplicatedStorage
local function mk(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end
local StatsRemote  = mk("Stats")       -- S->C: money/level/best wave
local ZoneEnter    = mk("ZoneEnter")    -- S->C: (payload) open the selection menu with unlock info
local ZoneLeave    = mk("ZoneLeave")    -- S->C: close the menu
local RequestQueue = mk("RequestQueue") -- C->S: {map, difficulty, size}
local LeaveQueue   = mk("LeaveQueue")   -- C->S: cancel
local QueueStatus  = mk("QueueStatus")  -- S->C: {map, difficulty, size, count, seconds}
-- Inventory (weapons / cases / potions)
local InvRequest   = mk("InvRequest")   -- C->S: (please send my inventory)
local InvSync      = mk("InvSync")      -- S->C: full inventory snapshot + catalog
local EquipTier    = mk("EquipTier")    -- C->S: {slot, weaponId} equip a weapon into a tier slot ("" clears)
local OpenCase     = mk("OpenCase")     -- C->S: {caseId} open a case
local CaseResult   = mk("CaseResult")   -- S->C: {caseId, wonId, duplicate, coins} the roll outcome (drives the reel)

-- ===== PROFILE + PROGRESSION =====
local store = DataStoreService:GetDataStore(STORE_NAME)
local profileCache = {} -- userId -> { level, lobbyMoney, bestWave, completed }

-- Coerce loaded inventory fields into valid shapes (defaults mirror the game's DataService template so a
-- brand-new player who joins the LOBBY first still gets a pistol + starter cases).
local function sanitizeOwned(v)
	local owned, seen = {}, {}
	if typeof(v) == "table" then
		for _, id in v do
			if WEAPONS[id] and not seen[id] then
				seen[id] = true
				table.insert(owned, id)
			end
		end
	end
	if not seen.pistol then
		table.insert(owned, 1, "pistol")
	end
	return owned
end

local function sanitizeTierLoadout(v, owned)
	local ownedSet = {}
	for _, id in owned do
		ownedSet[id] = true
	end
	local out = {}
	for slot = 1, TIER_COUNT do
		local id = (typeof(v) == "table") and v[slot] or nil
		if typeof(id) == "string" and WEAPONS[id] and WEAPONS[id].tier == slot and ownedSet[id] then
			out[slot] = id
		else
			out[slot] = ""
		end
	end
	if out[1] == "" and ownedSet.pistol then
		out[1] = "pistol" -- keep the starter equipped by default
	end
	return out
end

local function sanitizeCases(v)
	local out = {}
	if typeof(v) == "table" then
		for id, n in v do
			if CASES[id] and typeof(n) == "number" and n > 0 then
				out[id] = math.floor(n)
			end
		end
	else
		out.standard = 3 -- no field yet (first ever load) → grant the starter cases
	end
	return out
end

local function sanitizePotions(v)
	local out = {}
	if typeof(v) == "table" then
		for id, n in v do
			if POTIONS[id] and typeof(n) == "number" and n > 0 then
				out[id] = math.floor(n)
			end
		end
	end
	return out
end

local function readProfile(player)
	local ok, data = pcall(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)
	data = (ok and typeof(data) == "table") and data or {}
	local owned = sanitizeOwned(data.ownedWeapons)
	return {
		level = data.level or 1,
		lobbyMoney = data.lobbyMoney or 0,
		bestWave = data.bestWave or 0,
		completed = (typeof(data.completed) == "table") and data.completed or {},
		ownedWeapons = owned,
		tierLoadout = sanitizeTierLoadout(data.tierLoadout, owned),
		cases = sanitizeCases(data.cases),
		potions = sanitizePotions(data.potions),
	}
end

-- Merge the lobby-owned fields back into the shared profile WITHOUT clobbering game-owned fields
-- (completed/bestWave/level/stats). One player is only ever in one place at a time, so this is safe.
local function persist(player)
	local prof = profileCache[player.UserId]
	if not prof then
		return
	end
	pcall(function()
		store:UpdateAsync("Player_" .. player.UserId, function(old)
			old = (typeof(old) == "table") and old or {}
			old.ownedWeapons = prof.ownedWeapons
			old.tierLoadout = prof.tierLoadout
			old.cases = prof.cases
			old.potions = prof.potions
			old.lobbyMoney = prof.lobbyMoney
			return old
		end)
	end)
end

-- Snapshot sent to the client (everything the inventory UI needs).
local function invSnapshot(prof)
	return {
		catalog = CATALOG,
		owned = prof.ownedWeapons,
		tierLoadout = prof.tierLoadout,
		cases = prof.cases,
		potions = prof.potions,
		coins = prof.lobbyMoney,
	}
end

local function pushInv(player)
	local prof = profileCache[player.UserId]
	if prof then
		InvSync:FireClient(player, invSnapshot(prof))
	end
end

local function indexOf(t, v)
	for i, x in t do
		if x == v then
			return i
		end
	end
	return nil
end

local function worldUnlocked(completed, world)
	local i = indexOf(WORLDS, world) or 1
	if i <= 1 then
		return true
	end
	return completed[WORLDS[i - 1] .. ":" .. DIFFS[#DIFFS]] == true
end

local function diffUnlocked(completed, world, difficulty)
	if not worldUnlocked(completed, world) then
		return false
	end
	local di = indexOf(DIFFS, difficulty)
	if not di then
		return false
	end
	if di <= 1 then
		return true
	end
	return completed[world .. ":" .. DIFFS[di - 1]] == true
end

local function unlockPayload(profile)
	local worlds = {}
	for _, w in WORLDS do
		local diffs = {}
		for _, d in DIFFS do
			diffs[d] = diffUnlocked(profile.completed, w, d)
		end
		worlds[w] = { unlocked = worldUnlocked(profile.completed, w), diffs = diffs }
	end
	return { worldOrder = WORLDS, order = DIFFS, worlds = worlds }
end

-- ===== ZONES (found by name) =====
local zoneParts = {}
local lastZoneScan = -math.huge
local function refreshZones()
	local list = {}
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") and d.Name:lower():match("^loadingzone") then
			table.insert(list, d)
		end
	end
	zoneParts = list
end

local function inPart(pos, part)
	local rel = part.CFrame:PointToObjectSpace(pos)
	local s = part.Size * 0.5
	return math.abs(rel.X) <= s.X and math.abs(rel.Z) <= s.Z and rel.Y >= -s.Y - 1 and rel.Y <= s.Y + V_MARGIN
end

local inZone = {} -- userId -> bool

-- ===== QUEUES ===== keyed by "map:difficulty:size"
local queues = {}       -- key -> { map, difficulty, size, members = {player}, deadline }
local playerQueue = {}  -- userId -> key

local function removeFromQueue(player)
	local key = playerQueue[player.UserId]
	if not key then
		return
	end
	playerQueue[player.UserId] = nil
	local q = queues[key]
	if q then
		for i = #q.members, 1, -1 do
			if q.members[i] == player then
				table.remove(q.members, i)
			end
		end
		if #q.members == 0 then
			queues[key] = nil
		end
	end
	QueueStatus:FireClient(player, nil)
end

local function teleportGroup(list, map, difficulty)
	local ok, code = pcall(function()
		return TeleportService:ReserveServer(GAME_PLACE_ID)
	end)
	local options = Instance.new("TeleportOptions")
	if ok and code then
		options.ReservedServerAccessCode = code
	end
	options:SetTeleportData({ startRun = true, map = map, difficulty = difficulty })
	-- Save each traveler's inventory BEFORE they leave, so the game server loads their latest data.
	for _, pl in list do
		persist(pl)
	end
	for attempt = 1, TELEPORT_RETRIES do
		local tok = pcall(function()
			TeleportService:TeleportAsync(GAME_PLACE_ID, list, options)
		end)
		if tok then
			return
		end
		warn(("[LobbyServer] group teleport failed (attempt %d)"):format(attempt))
		task.wait(attempt)
	end
end

RequestQueue.OnServerEvent:Connect(function(player, sel)
	if typeof(sel) ~= "table" then
		return
	end
	local map, difficulty, size = tostring(sel.map), tostring(sel.difficulty), tonumber(sel.size)
	if not indexOf(WORLDS, map) or not indexOf(DIFFS, difficulty) then
		return
	end
	size = math.clamp(math.floor(size or 1), 1, 4)
	local profile = profileCache[player.UserId]
	if not profile or not diffUnlocked(profile.completed, map, difficulty) then
		return -- locked (server-side re-check)
	end
	removeFromQueue(player)
	local key = map .. ":" .. difficulty .. ":" .. size
	local q = queues[key]
	if not q then
		q = { map = map, difficulty = difficulty, size = size, members = {}, deadline = os.clock() + COUNTDOWN }
		queues[key] = q
	end
	table.insert(q.members, player)
	playerQueue[player.UserId] = key
end)

LeaveQueue.OnServerEvent:Connect(function(player)
	removeFromQueue(player)
end)

-- ===== INVENTORY HANDLERS =====
InvRequest.OnServerEvent:Connect(function(player)
	pushInv(player)
end)

EquipTier.OnServerEvent:Connect(function(player, req)
	if typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof then
		return
	end
	local slot = tonumber(req.slot)
	local weaponId = tostring(req.weaponId or "")
	if not slot or slot < 1 or slot > TIER_COUNT or slot ~= math.floor(slot) then
		return
	end
	if weaponId == "" then
		prof.tierLoadout[slot] = "" -- clear the slot
	else
		local w = WEAPONS[weaponId]
		if not w or w.tier ~= slot or not table.find(prof.ownedWeapons, weaponId) then
			return -- not a real weapon / wrong tier / not owned
		end
		prof.tierLoadout[slot] = weaponId
	end
	persist(player)
	pushInv(player)
end)

OpenCase.OnServerEvent:Connect(function(player, req)
	if typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof then
		return
	end
	local caseId = tostring(req.caseId or "")
	if not CASES[caseId] then
		return
	end
	local have = prof.cases[caseId] or 0
	if have < 1 then
		return -- you don't own one
	end
	-- Consume the case (authoritative) and roll the result server-side.
	prof.cases[caseId] = have - 1
	if prof.cases[caseId] <= 0 then
		prof.cases[caseId] = nil
	end
	local wonId = rollCase(caseId)
	local duplicate = table.find(prof.ownedWeapons, wonId) ~= nil
	local coins = 0
	if duplicate then
		coins = CASES[caseId].dupValue
		prof.lobbyMoney += coins
	else
		table.insert(prof.ownedWeapons, wonId)
		-- Auto-equip into its tier slot if that slot is empty (nice first-time-owned convenience).
		local tier = WEAPONS[wonId].tier
		if prof.tierLoadout[tier] == "" then
			prof.tierLoadout[tier] = wonId
		end
	end
	persist(player)
	-- Tell the client the outcome (drives the reel), then the fresh inventory + updated Coins stat.
	CaseResult:FireClient(player, { caseId = caseId, wonId = wonId, duplicate = duplicate, coins = coins })
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- ===== TICK =====
local function tick()
	if os.clock() - lastZoneScan > 3 then
		lastZoneScan = os.clock()
		refreshZones()
	end

	-- Zone presence → open/close the menu (and cancel the queue when you leave).
	for _, player in Players:GetPlayers() do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local nowIn = false
		if hrp then
			for _, part in zoneParts do
				if part.Parent and inPart(hrp.Position, part) then
					nowIn = true
					break
				end
			end
		end
		if nowIn ~= (inZone[player.UserId] == true) then
			inZone[player.UserId] = nowIn
			if nowIn then
				ZoneEnter:FireClient(player, unlockPayload(profileCache[player.UserId] or readProfile(player)))
			else
				ZoneLeave:FireClient(player)
				removeFromQueue(player)
			end
		end
	end

	-- Queues: prune, countdown, launch.
	local nowc = os.clock()
	for key, q in queues do
		for i = #q.members, 1, -1 do
			local pl = q.members[i]
			if not pl.Parent or playerQueue[pl.UserId] ~= key then
				table.remove(q.members, i)
			end
		end
		local n = #q.members
		if n == 0 then
			queues[key] = nil
		else
			if n >= q.size and (q.deadline - nowc) > FULL_PARTY_SECS then
				q.deadline = nowc + FULL_PARTY_SECS
			end
			local secs = math.max(0, math.ceil(q.deadline - nowc))
			for _, pl in q.members do
				QueueStatus:FireClient(pl, { map = q.map, difficulty = q.difficulty, size = q.size, count = n, seconds = secs })
			end
			if nowc >= q.deadline then
				local list = table.clone(q.members)
				local map, difficulty = q.map, q.difficulty
				queues[key] = nil
				for _, pl in list do
					playerQueue[pl.UserId] = nil
				end
				task.spawn(teleportGroup, list, map, difficulty)
			end
		end
	end
end

-- ===== LIFECYCLE =====
local function onJoin(player)
	task.spawn(function()
		local profile = readProfile(player)
		profileCache[player.UserId] = profile
		StatsRemote:FireClient(player, profile)
		pushInv(player) -- seed the inventory UI so it's ready the moment they open it
	end)
end

Players.PlayerAdded:Connect(onJoin)
for _, pl in Players:GetPlayers() do
	onJoin(pl)
end
Players.PlayerRemoving:Connect(function(pl)
	removeFromQueue(pl)
	persist(pl) -- save inventory/coins before their session ends
	profileCache[pl.UserId] = nil
	inZone[pl.UserId] = nil
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= TICK then
		acc = 0
		tick()
	end
end)

print(("[LobbyServer] started (hub + selection matchmaking%s)"):format(RunService:IsStudio() and " — Studio: teleports won't fire until published" or ""))
