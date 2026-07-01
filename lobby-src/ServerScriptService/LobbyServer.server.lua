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
local GAME_PLACE_ID    = 140566663451993 -- the gameplay place (secondary; the lobby is the start place now)
local STORE_NAME       = "PlayerData_v2"
local DIFFS            = { "easy", "medium", "hard", "nightmare" }
local WORLDS           = { "forest" }
local COUNTDOWN        = 15
local FULL_PARTY_SECS  = 3
local V_MARGIN         = 6
local TICK             = 0.25
local TELEPORT_RETRIES = 4

Players.CharacterAutoLoads = true

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

-- ===== PROFILE + PROGRESSION =====
local store = DataStoreService:GetDataStore(STORE_NAME)
local profileCache = {} -- userId -> { level, lobbyMoney, bestWave, completed }

local function readProfile(player)
	local ok, data = pcall(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)
	if ok and typeof(data) == "table" then
		return {
			level = data.level or 1,
			lobbyMoney = data.lobbyMoney or 0,
			bestWave = data.bestWave or 0,
			completed = (typeof(data.completed) == "table") and data.completed or {},
		}
	end
	return { level = 1, lobbyMoney = 0, bestWave = 0, completed = {} }
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
	end)
end

Players.PlayerAdded:Connect(onJoin)
for _, pl in Players:GetPlayers() do
	onJoin(pl)
end
Players.PlayerRemoving:Connect(function(pl)
	removeFromQueue(pl)
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
