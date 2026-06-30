-- LobbyServer (LOBBY PLACE ONLY) — this place is a standalone menu, NOT the game. It does one job: when a
-- player presses PLAY, teleport them to the game place to start a run. It also reads their saved profile
-- (read-only) so the menu can show money / level / best wave, and forwards any run summary they arrived with.
--
-- This is deliberately separate from the game codebase — the lobby place contains only this script and the
-- matching LobbyClient. Sync it with `rojo serve lobby.project.json`.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ===== CONFIG =====
local GAME_PLACE_ID    = 109730423425701 -- the gameplay place (where PLAY sends you)
local STORE_NAME       = "PlayerData_v2" -- MUST match DataService.STORE_NAME in the game codebase
local TELEPORT_RETRIES = 4

Players.CharacterAutoLoads = false -- the lobby is a full-screen menu; no character needed

-- ===== REMOTES (this place builds its own; the game place's remotes don't exist here) =====
local remotes = Instance.new("Folder")
remotes.Name = "LobbyRemotes"
remotes.Parent = ReplicatedStorage

local function makeRemote(name: string): RemoteEvent
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end

local PlayRemote = makeRemote("Play")     -- C->S: player pressed PLAY
local MenuRemote = makeRemote("ShowMenu")  -- S->C: (stats, summary) -> populate + show the menu

local store = DataStoreService:GetDataStore(STORE_NAME)

-- Read just the few fields the menu shows. Read-only — the game place owns all writes. Falls back to a clean
-- profile if DataStores are unavailable (e.g. Studio with API access off) so the menu always works.
local function readProfile(player: Player)
	local ok, data = pcall(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)
	if ok and typeof(data) == "table" then
		return {
			level = data.level or 1,
			lobbyMoney = data.lobbyMoney or 0,
			bestWave = data.bestWave or 0,
		}
	end
	return { level = 1, lobbyMoney = 0, bestWave = 0 }
end

local function onJoin(player: Player)
	-- The run summary the player arrived with (set by the game place when they died), if any.
	local summary
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if ok and typeof(joinData) == "table" and typeof(joinData.TeleportData) == "table" then
		summary = joinData.TeleportData.summary
	end
	MenuRemote:FireClient(player, readProfile(player), summary)
end

local function play(player: Player)
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ startRun = true })
	for attempt = 1, TELEPORT_RETRIES do
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(GAME_PLACE_ID, { player }, options)
		end)
		if ok then
			return
		end
		warn(("[LobbyServer] teleport failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(err)))
		task.wait(attempt)
	end
end

PlayRemote.OnServerEvent:Connect(play)

Players.PlayerAdded:Connect(function(player)
	task.spawn(onJoin, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(onJoin, player)
end

print(("[LobbyServer] started (lobby place%s)"):format(RunService:IsStudio() and " — Studio: PLAY can't teleport until published" or ""))
