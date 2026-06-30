--!nonstrict
-- ProgressionService.lua — account XP + best wave, persisted via DataService (game place).
-- XP is KILL-WEIGHTED (CLAUDE.md): most XP from kills (+ bonus for specials/bosses), a small bonus per wave
-- reached. Best wave is recorded as you advance. All of it persists to the shared DataStore; the LOBBY place
-- reads it back (read-only) to show level / money / best wave on its menu. (No live client push needed here.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")

local ProgressionConfig = require(Config.ProgressionConfig)

local DataService = require(script.Parent.DataService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)

local ProgressionService = {}

-- XP per kill (+ special bonus) — fires on every zombie kill.
local function onKill(player: Player, humanoid: Humanoid, _isHead: boolean, _weaponId: string)
	local model = humanoid.Parent
	local special = model and model:GetAttribute("IsSpecial") == true
	local xp = ProgressionConfig.XPPerKill + (special and ProgressionConfig.XPPerSpecialKill or 0)
	DataService.AddXP(player, xp)
	DataService.IncrementStat(player, "totalKills", 1)
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
				-- Only reward players actually IN the run.
				MatchService.ForEachPlayer(function(player)
					DataService.AddXP(player, ProgressionConfig.XPPerRound)
					DataService.UpdateBestWave(player, round)
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
