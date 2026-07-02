-- LobbyServer (LOBBY PLACE ONLY) — walkable hub with PARTY PADS + the inventory.
--
-- PARTY FLOW (one party per LoadingZone pad):
--   1. Player A steps on an empty pad -> becomes the HOST and gets the setup menu (Map / Difficulty / Size).
--      While A is setting up, the pad is LOCKED — anyone else stepping on is told to wait.
--   2. A presses PLAY -> settings are FINALIZED. A's menu collapses to just party info + a LEAVE button,
--      and a billboard above the pad shows the settings + player count + countdown.
--   3. Others step on the pad to JOIN — but only if they've UNLOCKED that map + difficulty (otherwise they
--      are told what they're missing). Members see party info + LEAVE.
--   4. The party launches when FULL, or when the 30s countdown ends (with whoever joined). Everyone
--      teleports together into a fresh private game server.
--
-- INVENTORY: 2-slot gun loadout (equip any 2 owned guns), 7 rarity-tiered cases (Common..Divine) opened
-- with the CS:GO reel, potions display. Your loadout guns show ON your character (slot 1 back, slot 2 hip).
--
-- BUILD (you): a SpawnLocation + one or more Parts named "LoadingZone..." (each is one party pad; its size
-- is the trigger volume). Gun models must also be in THIS place (tag "WeaponModel" or an Assets folder).
-- Sync with `rojo serve lobby.project.json`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

-- ===== CONFIG (keep in sync with the game's GameConfig) =====
local GAME_PLACE_ID    = 140566663451993 -- the gameplay place (PLAY teleports here; the lobby is the START place)
local STORE_NAME       = "PlayerData_v2"
local DIFFS            = { "easy", "medium", "hard", "nightmare" }
local WORLDS           = { "forest" }
local PARTY_WAIT       = 30   -- seconds an OPEN party waits before launching with whoever joined
local FULL_GRACE       = 5    -- once the party is FULL (incl. solo), the countdown drops to this — a short
                              -- window to hit LEAVE before launch (nobody teleports instantly)
local V_MARGIN         = 6
local TICK             = 0.25
local TELEPORT_RETRIES = 4

Players.CharacterAutoLoads = true

local rng = Random.new()

-- ===== INVENTORY CATALOG =====
-- The lobby is self-contained (it can't require the game's Shared config), so the catalog lives here and
-- is SENT to the client for display. Add a weapon = add a WEAPONS entry (+ case pool weights below).
local RARITY_ORDER = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "divine" }
local RARITY = {
	common    = { name = "Common",    color = { 185, 185, 185 } },
	uncommon  = { name = "Uncommon",  color = {  95, 205,  95 } },
	rare      = { name = "Rare",      color = {  80, 145, 255 } },
	epic      = { name = "Epic",      color = { 175,  95, 235 } },
	legendary = { name = "Legendary", color = { 255, 170,  60 } },
	mythic    = { name = "Mythic",    color = { 255,  80, 120 } },
	divine    = { name = "Divine",    color = { 120, 255, 235 } },
}

-- Stats mirror the game's WeaponConfig (kept in sync by hand) for the hover tooltips.
local WEAPONS = {
	pistol  = { name = "M1911",        tier = 1, rarity = "common",    damage = 30, fireRate = 5,   range = 200 },
	shotgun = { name = "Pump Shotgun", tier = 2, rarity = "uncommon",  damage = 16, fireRate = 1.2, range = 40, pellets = 6 },
	ak47    = { name = "AK-47",        tier = 3, rarity = "rare",      damage = 40, fireRate = 9,   range = 300 },
	minigun = { name = "Minigun",      tier = 4, rarity = "epic",      damage = 16, fireRate = 18,  range = 300 },
	raygun  = { name = "Ray Gun",      tier = 5, rarity = "legendary", damage = 80, fireRate = 4,   range = 250 },
}

-- 7 rarity-tiered cases (wave rewards + starter grants). Higher case rarity = better guns + bigger
-- duplicate Coin refunds. Pools are { weaponId = weight }.
local CASES = {
	common    = { dupValue = 25,  pool = { shotgun = 70, ak47 = 24, minigun = 5,  raygun = 1 } },
	uncommon  = { dupValue = 40,  pool = { shotgun = 55, ak47 = 32, minigun = 10, raygun = 3 } },
	rare      = { dupValue = 60,  pool = { shotgun = 35, ak47 = 40, minigun = 18, raygun = 7 } },
	epic      = { dupValue = 90,  pool = { shotgun = 20, ak47 = 38, minigun = 30, raygun = 12 } },
	legendary = { dupValue = 140, pool = { shotgun = 10, ak47 = 28, minigun = 38, raygun = 24 } },
	mythic    = { dupValue = 220, pool = { shotgun = 5,  ak47 = 18, minigun = 40, raygun = 37 } },
	divine    = { dupValue = 350, pool = { shotgun = 2,  ak47 = 10, minigun = 33, raygun = 55 } },
}
for rarity, c in CASES do
	c.name = RARITY[rarity].name .. " Case"
end

local POTIONS = {
	damage = { name = "Damage Potion", rarity = "rare",     desc = "Use in a run: +15% damage (once per run)" },
	regen  = { name = "Regen Potion",  rarity = "uncommon", desc = "Use in a run: +50% health regen (once per run)" },
}

-- Display catalog the client renders from.
local CATALOG = {
	rarities = RARITY,
	rarityOrder = RARITY_ORDER,
	weapons = WEAPONS,
	potions = POTIONS,
	cases = (function()
		local t = {}
		for rarity, c in CASES do
			local ids, byRarity, total = {}, {}, 0
			for weaponId, weight in c.pool do
				table.insert(ids, weaponId)
				total += weight
				local wr = WEAPONS[weaponId].rarity
				byRarity[wr] = (byRarity[wr] or 0) + weight
			end
			local odds = {}
			for _, wr in RARITY_ORDER do
				if byRarity[wr] then
					table.insert(odds, { rarity = wr, pct = (byRarity[wr] / total) * 100 })
				end
			end
			t[rarity] = { name = c.name, rarity = rarity, dupValue = c.dupValue, poolIds = ids, odds = odds }
		end
		return t
	end)(),
}

local function rollCase(caseId)
	local case = CASES[caseId]
	local total = 0
	for _, weight in case.pool do
		total += weight
	end
	local r = rng:NextNumber(0, total)
	local acc = 0
	for weaponId, weight in case.pool do
		acc += weight
		if r <= acc then
			return weaponId
		end
	end
	local last
	for weaponId in case.pool do
		last = weaponId
	end
	return last
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
local StatsRemote   = mk("Stats")         -- S->C: money/best wave
local ZoneEnter     = mk("ZoneEnter")     -- S->C: ({mode="config"|"party"|"blocked", ...}) pad UI state
local ZoneLeave     = mk("ZoneLeave")     -- S->C: close the pad UI
local FinalizeParty = mk("FinalizeParty") -- C->S: {map, difficulty, size} host locks in the settings
local LeaveParty    = mk("LeaveParty")    -- C->S: leave the party (moves you off the pad)
local PartyStatus   = mk("PartyStatus")   -- S->C: {map, difficulty, size, count, seconds} live party state
-- Inventory
local InvRequest    = mk("InvRequest")    -- C->S: (please send my inventory)
local InvSync       = mk("InvSync")       -- S->C: full inventory snapshot + catalog
local EquipSlot     = mk("EquipSlot")     -- C->S: {slot=1|2, weaponId} put a gun in a loadout slot
local OpenCase      = mk("OpenCase")      -- C->S: {caseId} open a case (caseId = its rarity)
local CaseResult    = mk("CaseResult")    -- S->C: {caseId, wonId, duplicate, coins} the roll (drives the reel)

-- ===== PROFILE =====
local store = DataStoreService:GetDataStore(STORE_NAME)
local profileCache = {} -- userId -> profile

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

-- The up-to-2 guns carried into runs. Migration: selectedWeapon (single-gun era), then tierLoadout.
local function sanitizeLoadout(v, legacySelected, owned)
	local ownedSet = {}
	for _, id in owned do
		ownedSet[id] = true
	end
	local out, seen = {}, {}
	if typeof(v) == "table" then
		for slot = 1, 2 do
			local id = v[slot]
			if typeof(id) == "string" and WEAPONS[id] and ownedSet[id] and not seen[id] then
				seen[id] = true
				table.insert(out, id)
			end
		end
	end
	if #out == 0 then
		local sel = (typeof(legacySelected) == "string" and WEAPONS[legacySelected] and ownedSet[legacySelected])
			and legacySelected or "pistol"
		out = { sel }
	end
	return out
end

local function sanitizeCases(v)
	local out = {}
	if typeof(v) == "table" then
		for id, n in v do
			if typeof(n) == "number" and n > 0 then
				if CASES[id] then
					out[id] = (out[id] or 0) + math.floor(n)
				elseif id == "standard" then
					out.common = (out.common or 0) + math.floor(n) -- legacy Standard Cases -> Common
				end
			end
		end
	else
		out.common = 3 -- first ever load -> starter cases
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
	-- Retry with backoff: a transient DataStore error must NOT make a veteran look brand-new (persisting
	-- that fallback would wipe their profile).
	local ok, data = false, nil
	for attempt = 1, 4 do
		ok, data = pcall(function()
			return store:GetAsync("Player_" .. player.UserId)
		end)
		if ok then
			break
		end
		warn(("[LobbyServer] profile load failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(data)))
		task.wait(attempt)
		if not player.Parent then
			break
		end
	end
	local loadFailed = not ok
	data = (ok and typeof(data) == "table") and data or {}
	local owned = sanitizeOwned(data.ownedWeapons)
	return {
		lobbyMoney = data.lobbyMoney or 0,
		bestWave = data.bestWave or 0,
		completed = (typeof(data.completed) == "table") and data.completed or {},
		ownedWeapons = owned,
		loadout = sanitizeLoadout(data.loadout, data.selectedWeapon, owned),
		cases = sanitizeCases(data.cases),
		potions = sanitizePotions(data.potions),
		noPersist = loadFailed, -- fallback profile: NEVER write it back
	}
end

-- Merge the lobby-owned fields back into the shared profile WITHOUT clobbering game-owned fields.
local function persist(player)
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	pcall(function()
		store:UpdateAsync("Player_" .. player.UserId, function(old)
			old = (typeof(old) == "table") and old or {}
			old.ownedWeapons = prof.ownedWeapons
			old.loadout = prof.loadout
			old.selectedWeapon = prof.loadout[1] -- legacy field (older game builds read it)
			old.cases = prof.cases
			old.potions = prof.potions
			old.lobbyMoney = prof.lobbyMoney
			return old
		end)
	end)
end

local function invSnapshot(prof)
	return {
		catalog = CATALOG,
		owned = prof.ownedWeapons,
		loadout = prof.loadout,
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

-- ===== ON-BODY GUNS (hub cosmetic) =====
-- Loadout guns ride on your character: SLOT 1 across the BACK, SLOT 2 on the HIP (a lone small gun sits
-- on the hip). Models: tag gun Models "WeaponModel" or put them in an "Assets" folder — named after the
-- weapon id or display name, same contract as the game place. Missing model = skipped quietly.
local CARRY_SMALL = { pistol = true } -- "small" guns prefer the hip when alone
local BACK_CF = CFrame.new(0, 0.2, 0.75) * CFrame.Angles(math.rad(-90), 0, math.rad(-40))
local HIP_CF  = CFrame.new(1.1, -0.95, 0.05) * CFrame.Angles(math.rad(-90), 0, math.rad(90))

local carryTemplates = nil

local function sanitizeName(s)
	return (s:lower():gsub("[%s%-_]", ""))
end

local function scanCarryTemplates()
	carryTemplates = {}
	local nameMap = {}
	for id, w in WEAPONS do
		nameMap[sanitizeName(id)] = id
		nameMap[sanitizeName(w.name)] = id
	end
	local function consider(inst)
		if inst:IsA("Model") then
			local id = nameMap[sanitizeName(inst.Name)]
			if id and not carryTemplates[id] then
				carryTemplates[id] = inst
			end
		end
	end
	for _, inst in CollectionService:GetTagged("WeaponModel") do
		consider(inst)
	end
	for _, container in { ReplicatedStorage, ServerStorage, Workspace } do
		for _, child in container:GetChildren() do
			if child.Name:lower() == "assets" then
				for _, d in child:GetDescendants() do
					consider(d)
				end
			end
		end
	end
end

local function attachCarry(char, torso, weaponId, mountCF, name)
	local template = carryTemplates[weaponId]
	if not template then
		return
	end
	local model = template:Clone()
	model.Name = name
	local handle = model:FindFirstChild("Handle") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not handle or not handle:IsA("BasePart") then
		model:Destroy()
		return
	end
	model.PrimaryPart = handle
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Anchored = false
			if d ~= handle then
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = handle
				wc.Part1 = d
				wc.Parent = handle
			end
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	handle.CFrame = torso.CFrame * mountCF
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = handle
	weld.Parent = handle
	model.Parent = char
end

local function refreshCarry(player)
	local char = player.Character
	local prof = profileCache[player.UserId]
	if not char or not prof then
		return
	end
	for _, name in { "CarriedWeapon1", "CarriedWeapon2" } do
		local old = char:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	if not carryTemplates then
		scanCarryTemplates()
	end
	local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
	if not torso then
		return
	end
	local g1, g2 = prof.loadout[1], prof.loadout[2]
	if g1 and not g2 then
		-- One gun: small guns sit on the hip, big ones on the back.
		attachCarry(char, torso, g1, CARRY_SMALL[g1] and HIP_CF or BACK_CF, "CarriedWeapon1")
	else
		if g1 then
			attachCarry(char, torso, g1, BACK_CF, "CarriedWeapon1")
		end
		if g2 then
			attachCarry(char, torso, g2, HIP_CF, "CarriedWeapon2")
		end
	end
end

-- ===== PROGRESSION =====
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

-- ===== INVENTORY HANDLERS =====
InvRequest.OnServerEvent:Connect(function(player)
	pushInv(player)
end)

EquipSlot.OnServerEvent:Connect(function(player, req)
	if typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local slot = tonumber(req.slot)
	local weaponId = tostring(req.weaponId or "")
	if not slot or (slot ~= 1 and slot ~= 2) then
		return
	end
	if not WEAPONS[weaponId] or not table.find(prof.ownedWeapons, weaponId) then
		return
	end
	local other = (slot == 1) and 2 or 1
	if prof.loadout[other] == weaponId then
		-- Already in the other slot: swap the two.
		prof.loadout[other] = prof.loadout[slot]
	end
	prof.loadout[slot] = weaponId
	-- Compact: slot 1 must always hold a gun.
	if not prof.loadout[1] and prof.loadout[2] then
		prof.loadout[1] = prof.loadout[2]
		prof.loadout[2] = nil
	end
	persist(player)
	pushInv(player)
	refreshCarry(player)
end)

OpenCase.OnServerEvent:Connect(function(player, req)
	if typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local caseId = tostring(req.caseId or "")
	if not CASES[caseId] then
		return
	end
	local have = prof.cases[caseId] or 0
	if have < 1 then
		return
	end
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
		-- First real gun: drop it into the empty slot 2 automatically.
		if not prof.loadout[2] and prof.loadout[1] ~= wonId then
			prof.loadout[2] = wonId
			refreshCarry(player)
		end
	end
	persist(player)
	CaseResult:FireClient(player, { caseId = caseId, wonId = wonId, duplicate = duplicate, coins = coins })
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- ===== PARTY PADS =====
-- parties[zonePart] = { state="config"|"open", host, map, difficulty, size, members={}, deadline, billboard }
local parties = {}
local playerParty = {}  -- userId -> party
local inZonePart = {}   -- userId -> zone Part they're standing in
local lastMode = {}     -- userId -> last ZoneEnter signature sent (avoids respamming the client)

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

local function cap(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

local function updateBillboard(zone, party)
	local bb = zone:FindFirstChild("PartyBillboard")
	if not party then
		if bb then
			bb:Destroy()
		end
		return
	end
	local label
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "PartyBillboard"
		bb.Size = UDim2.fromOffset(240, 60)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		bb.AlwaysOnTop = true
		bb.Parent = zone
		label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
		label.BackgroundTransparency = 0.25
		label.Font = Enum.Font.GothamBold
		label.TextSize = 16
		label.TextColor3 = Color3.fromRGB(238, 240, 245)
		label.Parent = bb
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = label
	else
		label = bb:FindFirstChild("Label")
	end
	if not label then
		return
	end
	if party.state == "config" then
		label.Text = "Setting up..."
	else
		local secs = math.max(0, math.ceil(party.deadline - os.clock()))
		label.Text = ("%s · %s\n%d/%d · %ds"):format(cap(party.map), cap(party.difficulty), #party.members, party.size, secs)
	end
end

local function sendMode(player, sig, payload)
	if lastMode[player.UserId] == sig then
		return
	end
	lastMode[player.UserId] = sig
	ZoneEnter:FireClient(player, payload)
end

local function removeFromParty(player)
	local party = playerParty[player.UserId]
	if not party then
		return
	end
	playerParty[player.UserId] = nil
	for i = #party.members, 1, -1 do
		if party.members[i] == player then
			table.remove(party.members, i)
		end
	end
	-- A host abandoning setup — or the last member leaving — dissolves the party.
	if (party.state == "config" and party.host == player) or #party.members == 0 then
		parties[party.zone] = nil
		updateBillboard(party.zone, nil)
	else
		updateBillboard(party.zone, party)
	end
end

local function dissolveAndLaunch(party)
	parties[party.zone] = nil
	updateBillboard(party.zone, nil)
	local list = {}
	for _, pl in party.members do
		if pl.Parent then
			table.insert(list, pl)
			playerParty[pl.UserId] = nil
			ZoneLeave:FireClient(pl)
		end
	end
	if #list == 0 then
		return
	end
	task.spawn(function()
		-- Save everyone's inventory BEFORE they leave, so the game server loads their latest data.
		for _, pl in list do
			persist(pl)
		end
		local ok, code = pcall(function()
			return TeleportService:ReserveServer(GAME_PLACE_ID)
		end)
		local options = Instance.new("TeleportOptions")
		if ok and code then
			options.ReservedServerAccessCode = code
		end
		options:SetTeleportData({ startRun = true, map = party.map, difficulty = party.difficulty })
		for attempt = 1, TELEPORT_RETRIES do
			local alive = {}
			for _, pl in list do
				if pl.Parent then
					table.insert(alive, pl)
				end
			end
			if #alive == 0 then
				return
			end
			local tok = pcall(function()
				TeleportService:TeleportAsync(GAME_PLACE_ID, alive, options)
			end)
			if tok then
				return
			end
			warn(("[LobbyServer] party teleport failed (attempt %d)"):format(attempt))
			task.wait(attempt)
		end
	end)
end

-- What this player should see for the pad they're standing on (runs every tick; only sends on change).
local function evaluateZone(player, zone)
	local prof = profileCache[player.UserId]
	local party = parties[zone]

	if party and playerParty[player.UserId] == party then
		if party.state == "config" and party.host == player then
			sendMode(player, "config", { mode = "config", unlocks = prof and unlockPayload(prof) or nil })
		else
			sendMode(player, "party", {
				mode = "party",
				map = party.map, difficulty = party.difficulty, size = party.size,
				isHost = party.host == player,
			})
		end
		return
	end

	if not prof then
		sendMode(player, "loading", { mode = "blocked", reason = "Loading your profile..." })
		return
	end

	if not party then
		-- Empty pad: this player becomes the HOST and starts configuring.
		party = { zone = zone, state = "config", host = player, members = { player } }
		parties[zone] = party
		playerParty[player.UserId] = party
		updateBillboard(zone, party)
		sendMode(player, "config", { mode = "config", unlocks = unlockPayload(prof) })
	elseif party.state == "config" then
		sendMode(player, "blockedSetup", { mode = "blocked", reason = "This pad is being set up — wait for the host to press PLAY." })
	else -- open
		if #party.members >= party.size then
			sendMode(player, "blockedFull", { mode = "blocked", reason = "This party is full." })
		elseif not diffUnlocked(prof.completed, party.map, party.difficulty) then
			sendMode(player, "blockedLock", {
				mode = "blocked",
				reason = ("You haven't unlocked %s · %s yet."):format(cap(party.map), cap(party.difficulty)),
			})
		else
			table.insert(party.members, player)
			playerParty[player.UserId] = party
			updateBillboard(zone, party)
			sendMode(player, "party", {
				mode = "party",
				map = party.map, difficulty = party.difficulty, size = party.size,
				isHost = false,
			})
		end
	end
end

FinalizeParty.OnServerEvent:Connect(function(player, sel)
	if typeof(sel) ~= "table" then
		return
	end
	local party = playerParty[player.UserId]
	if not party or party.state ~= "config" or party.host ~= player then
		return
	end
	local prof = profileCache[player.UserId]
	local map, difficulty, size = tostring(sel.map), tostring(sel.difficulty), tonumber(sel.size)
	if not indexOf(WORLDS, map) or not indexOf(DIFFS, difficulty) then
		return
	end
	if not prof or not diffUnlocked(prof.completed, map, difficulty) then
		return
	end
	party.map = map
	party.difficulty = difficulty
	party.size = math.clamp(math.floor(size or 1), 1, 4)
	party.state = "open"
	party.deadline = os.clock() + PARTY_WAIT
	lastMode[player.UserId] = nil -- re-send: host's UI flips from config to party view
	updateBillboard(party.zone, party)
end)

LeaveParty.OnServerEvent:Connect(function(player)
	local party = playerParty[player.UserId]
	removeFromParty(player)
	lastMode[player.UserId] = nil
	ZoneLeave:FireClient(player)
	-- Step them off the pad so they don't instantly re-enter.
	if party then
		local zone = party.zone
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and zone.Parent then
			local out = zone.CFrame.LookVector
			root.CFrame = CFrame.new(zone.Position + out * (zone.Size.Z * 0.5 + 6) + Vector3.new(0, 4, 0))
		end
	end
end)

-- ===== TICK =====
local function tick()
	if os.clock() - lastZoneScan > 3 then
		lastZoneScan = os.clock()
		refreshZones()
	end

	-- Zone presence.
	for _, player in Players:GetPlayers() do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local currentZone = nil
		if hrp then
			for _, part in zoneParts do
				if part.Parent and inPart(hrp.Position, part) then
					currentZone = part
					break
				end
			end
		end
		local prevZone = inZonePart[player.UserId]
		if currentZone ~= prevZone then
			inZonePart[player.UserId] = currentZone
			lastMode[player.UserId] = nil
			if prevZone then
				removeFromParty(player)
				ZoneLeave:FireClient(player)
			end
		end
		if currentZone then
			evaluateZone(player, currentZone)
		end
	end

	-- Open parties: prune leavers, live status, launch on full or timeout.
	local now = os.clock()
	for zone, party in parties do
		if not zone.Parent then
			parties[zone] = nil
		elseif party.state == "open" then
			for i = #party.members, 1, -1 do
				if not party.members[i].Parent then
					local pl = party.members[i]
					playerParty[pl.UserId] = nil
					table.remove(party.members, i)
				end
			end
			if #party.members == 0 then
				parties[zone] = nil
				updateBillboard(zone, nil)
			else
				-- Full party (incl. solo): shorten the countdown to FULL_GRACE — never launch instantly,
				-- so there's always a window to press LEAVE. If someone drops back out, the grace stays
				-- (they chose to fill it once; the timer keeps things moving).
				if #party.members >= party.size and (party.deadline - now) > FULL_GRACE then
					party.deadline = now + FULL_GRACE
				end
				local secs = math.max(0, math.ceil(party.deadline - now))
				for _, pl in party.members do
					PartyStatus:FireClient(pl, {
						map = party.map, difficulty = party.difficulty, size = party.size,
						count = #party.members, seconds = secs,
					})
				end
				updateBillboard(zone, party)
				if now >= party.deadline then
					dissolveAndLaunch(party)
				end
			end
		end
	end
end

-- ===== LIFECYCLE =====
local function onJoin(player)
	player.CharacterAdded:Connect(function()
		task.defer(refreshCarry, player)
	end)
	task.spawn(function()
		local profile = readProfile(player)
		profileCache[player.UserId] = profile
		StatsRemote:FireClient(player, profile)
		pushInv(player)
		refreshCarry(player)
	end)
end

Players.PlayerAdded:Connect(onJoin)
for _, pl in Players:GetPlayers() do
	onJoin(pl)
end
Players.PlayerRemoving:Connect(function(pl)
	removeFromParty(pl)
	persist(pl)
	profileCache[pl.UserId] = nil
	inZonePart[pl.UserId] = nil
	lastMode[pl.UserId] = nil
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= TICK then
		acc = 0
		tick()
	end
end)

print(("[LobbyServer] started (party pads + 2-slot loadout%s)"):format(RunService:IsStudio() and " — Studio: teleports won't fire until published" or ""))
