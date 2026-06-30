--!nonstrict
-- LobbyService.lua — runs ONLY in the lobby place (started by init.server.lua when Places.IsLobby). It shows
-- the lobby menu and turns a PLAY press into a teleport to the game place to start a run.
--
-- Persistent data (lobby money / XP / best wave / loadout) is read by the client from DataService, whose
-- DataStore is shared across BOTH places — so whatever a run banked in the game place is already loaded here.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local Places = require(Config.Places)
local Remotes = require(Modules.Remotes)

local LobbyService = {}

-- ===== TUNABLES =====
local TELEPORT_RETRIES = 4

local function safeTeleport(placeId: number, player: Player, options: TeleportOptions?): boolean
	for attempt = 1, TELEPORT_RETRIES do
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(placeId, { player }, options)
		end)
		if ok then
			return true
		end
		warn(("[LobbyService] teleport failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(err)))
		task.wait(attempt)
	end
	return false
end

-- Show the menu. If they arrived from a finished run, pass its summary so the menu can show the results.
local function onJoin(player: Player)
	local summary
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if ok and typeof(joinData) == "table" and typeof(joinData.TeleportData) == "table" then
		summary = joinData.TeleportData.summary
	end
	Remotes.Get("EnterLobby"):FireClient(player, summary)
end

function LobbyService.Start()
	Players.CharacterAutoLoads = false -- the lobby is a full-screen menu; no character needed

	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onJoin, player)
	end)

	-- PLAY → teleport to the game place, flagged to start a run on arrival.
	Remotes.Get("RequestPlay").OnServerEvent:Connect(function(player)
		local options = Instance.new("TeleportOptions")
		options:SetTeleportData({ startRun = true })
		safeTeleport(Places.Game, player, options)
	end)

	print("[LobbyService] started (lobby place)")
end

return LobbyService
