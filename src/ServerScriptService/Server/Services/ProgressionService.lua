--!nonstrict
-- ProgressionService.lua — account XP + best wave, persisted via DataService (game place).
-- XP is KILL-WEIGHTED (CLAUDE.md): most XP from kills (+ bonus for specials/bosses), a small bonus per wave
-- reached. Best wave is recorded as you advance. It also grants persistent "Coins" (lobby money) live —
-- per kill + per wave — pushing the running total to the HUD. All of it persists to the shared DataStore;
-- the LOBBY place reads it back (read-only) to show level / coins / best wave on its menu.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local ProgressionConfig = require(Config.ProgressionConfig)
local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)

local ProgressionService = {}

-- Grant persistent "Coins" (lobby money): save it, track this run's earnings for the end-of-run summary,
-- and push the new total so the in-game HUD ticks up live.
local function awardCoins(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	DataService.AddMoney(player, amount)
	local ps = MatchService.GetPlayerState(player)
	if ps then
		ps.lobbyEarned = (ps.lobbyEarned or 0) + amount
	end
	Remotes.Get("LobbyMoneyChanged"):FireClient(player, DataService.GetMoney(player))
end

-- XP + Coins per kill (+ special bonus) — fires on every zombie kill.
local function onKill(player: Player, humanoid: Humanoid, _isHead: boolean, _weaponId: string)
	local model = humanoid.Parent
	local special = model and model:GetAttribute("IsSpecial") == true
	local xp = ProgressionConfig.XPPerKill + (special and ProgressionConfig.XPPerSpecialKill or 0)
	DataService.AddXP(player, xp)
	DataService.IncrementStat(player, "totalKills", 1)
	awardCoins(player, GameConfig.LobbyMoneyPerKill)
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
					awardCoins(player, GameConfig.LobbyMoneyPerWave)
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
