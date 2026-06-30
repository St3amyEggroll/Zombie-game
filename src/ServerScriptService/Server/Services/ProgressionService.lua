--!nonstrict
-- ProgressionService.lua — account XP + best wave, persisted via DataService.
-- XP is KILL-WEIGHTED (CLAUDE.md): most XP from kills (+ bonus for specials/bosses), a small bonus per wave
-- reached. Best wave is recorded as you advance. (Lobby money is banked at run-end in the lobby phase.)
-- Pushes ProgressChanged(xp, level, lobbyMoney) so the client can show level/XP/money.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local ProgressionConfig = require(Config.ProgressionConfig)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)

local ProgressionService = {}

local function push(player: Player)
	local data = DataService.Get(player)
	if data then
		Remotes.Get("ProgressChanged"):FireClient(player, data.xp, data.level, data.lobbyMoney)
	end
end

-- XP per kill (+ special bonus) — fires on every zombie kill.
local function onKill(player: Player, humanoid: Humanoid, _isHead: boolean, _weaponId: string)
	local model = humanoid.Parent
	local special = model and model:GetAttribute("IsSpecial") == true
	local xp = ProgressionConfig.XPPerKill + (special and ProgressionConfig.XPPerSpecialKill or 0)
	local _, levelsGained = DataService.AddXP(player, xp)
	DataService.IncrementStat(player, "totalKills", 1)
	if levelsGained > 0 then
		push(player) -- only push on a level-up to avoid spamming a remote per kill
	end
end

function ProgressionService.Start()
	CombatService.Kill:Connect(onKill)

	-- Per-wave: small XP bonus + best-wave record for everyone currently playing.
	task.spawn(function()
		local lastRound = 0
		while true do
			local round = MatchService.GetRound()
			if round > lastRound and MatchService.GetPhase() == "Playing" then
				lastRound = round
				-- Only reward players actually IN the run (lobby players are skipped).
				MatchService.ForEachPlayer(function(player)
					DataService.AddXP(player, ProgressionConfig.XPPerRound)
					DataService.UpdateBestWave(player, round)
					push(player)
				end)
			elseif round < lastRound then
				lastRound = round -- match ended / reset
			end
			task.wait(0.5)
		end
	end)

	print("[ProgressionService] started")
end

return ProgressionService
