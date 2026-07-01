-- LobbyServer (LOBBY PLACE ONLY) — a walkable hub with MATCHMAKING loading zones. Stand in a zone (a Part
-- tagged "LoadingZone") to queue; a countdown starts and SHORTENS to 3s once the zone hits its MaxParty; at
-- zero, everyone in the zone teleports TOGETHER into a fresh private game server at the zone's difficulty.
--
-- BUILD IN THIS PLACE (you): a SpawnLocation (so players spawn in the hub) + 3 Parts whose NAME starts with
-- "LoadingZone" (e.g. LoadingZoneEasy, LoadingZoneHard, LoadingZoneNightmare). Each part's size IS the
-- trigger volume (cover the standing area; a little headroom is added automatically). Difficulty comes from
-- the NAME (contains easy/medium/hard/nightmare) OR a "Difficulty" string attribute; optional number
-- attributes MaxParty (default 4) and Countdown (default 12). Sync with `rojo serve lobby.project.json`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ===== CONFIG =====
local GAME_PLACE_ID     = 109730423425701 -- the gameplay place
local STORE_NAME        = "PlayerData_v2" -- MUST match DataService.STORE_NAME in the game codebase
local DEFAULT_COUNTDOWN = 12
local FULL_PARTY_SECS   = 3
local DEFAULT_MAXPARTY  = 4
local V_MARGIN          = 6               -- extra studs of headroom above a zone part so a flat pad still works
local TICK              = 0.25            -- seconds between occupancy checks
local TELEPORT_RETRIES  = 4

Players.CharacterAutoLoads = true -- walkable hub

-- ===== REMOTES =====
local remotes = Instance.new("Folder")
remotes.Name = "LobbyRemotes"
remotes.Parent = ReplicatedStorage
local function mk(name: string): RemoteEvent
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end
local StatsRemote = mk("Stats")      -- S->C: (stats) money/level/best wave for the HUD
local ZoneRemote  = mk("ZoneStatus")  -- S->C: (info | nil) drives the countdown panel

-- ===== PROFILE (read-only, for the HUD) =====
local store = DataStoreService:GetDataStore(STORE_NAME)
local function readProfile(player: Player)
	local ok, data = pcall(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)
	if ok and typeof(data) == "table" then
		return { level = data.level or 1, lobbyMoney = data.lobbyMoney or 0, bestWave = data.bestWave or 0 }
	end
	return { level = 1, lobbyMoney = 0, bestWave = 0 }
end

-- ===== ZONES =====
local zones: { [BasePart]: any } = {}      -- part -> { deadline, launching }
local playerZone: { [number]: BasePart? } = {}

local function attr(part: BasePart, name: string, default)
	local v = part:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

local function inPart(pos: Vector3, part: BasePart): boolean
	local rel = part.CFrame:PointToObjectSpace(pos)
	local s = part.Size * 0.5
	return math.abs(rel.X) <= s.X and math.abs(rel.Z) <= s.Z and rel.Y >= -s.Y - 1 and rel.Y <= s.Y + V_MARGIN
end

-- Zones are found BY NAME: any BasePart whose name starts with "LoadingZone". Cached + refreshed slowly.
local zoneParts: { BasePart } = {}
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

-- Difficulty from a "Difficulty" attribute, else parsed from the NAME (…Easy/Medium/Hard/Nightmare), else medium.
local DIFFS = { "nightmare", "hard", "medium", "easy" }
local function difficultyOf(part: BasePart): string
	local a = part:GetAttribute("Difficulty")
	if type(a) == "string" and a ~= "" then
		return a:lower()
	end
	local n = part.Name:lower()
	for _, d in DIFFS do
		if n:find(d, 1, true) then
			return d
		end
	end
	return "medium"
end

local function teleportGroup(list: { Player }, difficulty: string)
	local ok, code = pcall(function()
		return TeleportService:ReserveServer(GAME_PLACE_ID) -- a fresh PRIVATE arena for this party
	end)
	local options = Instance.new("TeleportOptions")
	if ok and code then
		options.ReservedServerAccessCode = code
	end
	options:SetTeleportData({ startRun = true, difficulty = difficulty })
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

local function tick()
	-- Refresh the zone list slowly (found by name); use only ones still in the world.
	if os.clock() - lastZoneScan > 3 then
		lastZoneScan = os.clock()
		refreshZones()
	end
	local parts = {}
	for _, p in zoneParts do
		if p.Parent and p:IsDescendantOf(Workspace) then
			table.insert(parts, p)
		end
	end

	-- Who is standing in which zone (a player counts for at most one zone).
	local occByZone: { [BasePart]: { Player } } = {}
	local zoneOfPlayer: { [number]: BasePart } = {}
	for _, part in parts do
		local list = {}
		for _, pl in Players:GetPlayers() do
			if not zoneOfPlayer[pl.UserId] then
				local hrp = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
				if hrp and inPart(hrp.Position, part) then
					table.insert(list, pl)
					zoneOfPlayer[pl.UserId] = part
				end
			end
		end
		occByZone[part] = list
	end

	local nowc = os.clock()
	for _, part in parts do
		local z = zones[part]
		if not z then
			z = { deadline = nil, launching = false }
			zones[part] = z
		end
		if not z.launching then
			local occ = occByZone[part]
			local n = #occ
			if n == 0 then
				z.deadline = nil
			else
				local maxp = attr(part, "MaxParty", DEFAULT_MAXPARTY)
				local cd = attr(part, "Countdown", DEFAULT_COUNTDOWN)
				local diff = difficultyOf(part)
				if not z.deadline then
					z.deadline = nowc + cd
				end
				if n >= maxp and (z.deadline - nowc) > FULL_PARTY_SECS then
					z.deadline = nowc + FULL_PARTY_SECS -- full party → hurry up
				end
				local secs = math.max(0, math.ceil(z.deadline - nowc))
				for _, pl in occ do
					ZoneRemote:FireClient(pl, { difficulty = diff, count = n, maxParty = maxp, seconds = secs })
				end
				if nowc >= z.deadline then
					z.launching = true
					task.spawn(function()
						teleportGroup(occ, diff)
						task.wait(2)
						z.launching = false
						z.deadline = nil
					end)
				end
			end
		end
	end

	-- Clear the panel for anyone who stepped out of every zone.
	for _, pl in Players:GetPlayers() do
		local nowZone = zoneOfPlayer[pl.UserId]
		if nowZone ~= playerZone[pl.UserId] then
			if not nowZone then
				ZoneRemote:FireClient(pl, nil)
			end
			playerZone[pl.UserId] = nowZone
		end
	end
end

-- ===== LIFECYCLE =====
local function onJoin(player: Player)
	task.spawn(function()
		StatsRemote:FireClient(player, readProfile(player))
	end)
end

Players.PlayerAdded:Connect(onJoin)
for _, pl in Players:GetPlayers() do
	onJoin(pl)
end
Players.PlayerRemoving:Connect(function(pl)
	playerZone[pl.UserId] = nil
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= TICK then
		acc = 0
		tick()
	end
end)

print(("[LobbyServer] started (hub + matchmaking%s)"):format(RunService:IsStudio() and " — Studio: teleports won't fire until published" or ""))
