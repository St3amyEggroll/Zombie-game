--!nonstrict
-- ProgressionService.lua — account XP + best wave, persisted via DataService (game place).
-- XP is KILL-WEIGHTED (CLAUDE.md): most XP from kills (+ bonus for specials/bosses), a small bonus per wave
-- reached. Best wave is recorded as you advance. It also grants persistent "Coins" (lobby money) live —
-- per kill + per wave — pushing the running total to the HUD. All of it persists to the shared DataStore;
-- the LOBBY place reads it back (read-only) to show level / coins / best wave on its menu.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local ProgressionConfig = require(Config.ProgressionConfig)
local GameConfig = require(Config.GameConfig)
local ClassConfig = require(Config.ClassConfig)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)
local TelemetryService = require(script.Parent.TelemetryService)

local ProgressionService = {}

-- ===== FRIEND BONUS (launch pass) ===== a player with at least one Roblox FRIEND in the server earns
-- GameConfig.FriendCoinMult × Coins all run. Recomputed on every join/leave (Player:IsFriendsWith is
-- cached by Roblox, but it's still pcall'd off-thread); mirrored to a player attribute for the HUD chip.
local friendBonus: { [number]: boolean } = {}

local function refreshFriendBonus()
	local list = Players:GetPlayers()
	for _, p in list do
		local has = false
		for _, o in list do
			if o ~= p then
				local ok, isFriend = pcall(p.IsFriendsWith, p, o.UserId)
				if ok and isFriend == true then
					has = true
					break
				end
			end
		end
		friendBonus[p.UserId] = has
		if p.Parent then
			p:SetAttribute("FriendBonus", has or nil)
		end
	end
end

-- Grant persistent "Coins" (lobby money): save it, track this run's earnings for the end-of-run summary,
-- and push the new total so the in-game HUD ticks up live.
local function awardCoins(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	do -- SCAVENGER class: every run coin payout scales up (stacks with the 2x Coins pass in AddMoney)
		local data = DataService.Get(player)
		local cls = data and ClassConfig.Get(data.class)
		if cls and cls.coinsMult then
			amount = math.floor(amount * cls.coinsMult + 0.5)
		end
	end
	-- NEW (launch pass): FRIEND BONUS — stacks after the class mult, before the 2x Coins pass.
	local friendMult = tonumber(GameConfig.FriendCoinMult) or 1
	if friendMult > 1 and friendBonus[player.UserId] then
		amount = math.floor(amount * friendMult + 0.5)
	end
	local before = DataService.GetMoney(player)
	DataService.AddMoney(player, amount)
	local after = DataService.GetMoney(player)
	local ps = MatchService.GetPlayerState(player)
	if ps then
		ps.lobbyEarned = (ps.lobbyEarned or 0) + amount
		-- Analytics: Coins are aggregated per WAVE (flushed on wave clear below) — never one event per kill.
		ps.telemCoins = (ps.telemCoins or 0) + math.max(0, after - before)
	end
	Remotes.Get("LobbyMoneyChanged"):FireClient(player, after)
end
-- NEW: public entry for event payouts (Bodyguards vault) — same pipe as kill coins, so the
-- Scavenger class mult applies and the amount counts in the end-of-run summary.
ProgressionService.AwardCoins = awardCoins

-- Grant XP + push it LIVE: the HUD's blue level bar listens to ProgressChanged (without this push it
-- only refreshed on spawn — the bar looked frozen all run).
local function awardXP(player: Player, amount: number)
	local before = DataService.Get(player)
	local beforeLevel = before and before.level or 0
	DataService.AddXP(player, amount)
	require(script.Parent.GunShopService).GrantUnlocks(player) -- level-ups grant guns LIVE (fires the showcase)
	local data = DataService.Get(player)
	if data then
		Remotes.Get("ProgressChanged"):FireClient(player, data.xp, data.level, data.lobbyMoney)
		if data.level ~= beforeLevel then
			-- REAL-TIME overhead tag: a mid-run level-up restamps "LVL n" immediately (it used to wait
			-- for the next respawn).
			require(script.Parent.PlayerTagService).Refresh(player)
			if data.level == 2 then
				TelemetryService.Onboarding(player, TelemetryService.Onboard.FirstLevelUp)
			end
		end
	end
end

-- XP + Coins per kill (+ special bonus) — fires on every zombie kill.
local function onKill(player: Player, model: Model, _isHead: boolean, _weaponId: string)
	-- (CUSTOM ENTITIES: CombatService passes the zombie MODEL — zombies have no Humanoid.)
	local special = model and model:GetAttribute("IsSpecial") == true
	local xp = ProgressionConfig.XPPerKill + (special and ProgressionConfig.XPPerSpecialKill or 0)
	awardXP(player, xp)
	DataService.IncrementStat(player, "totalKills", 1)
	-- BLOOD MOON (event wheel): kills pay double Coins for the whole wave (EventService.CoinMult).
	local mult = require(script.Parent.EventService).CoinMult()
	awardCoins(player, math.floor(GameConfig.LobbyMoneyPerKill * mult + 0.5))
end

function ProgressionService.Start()
	CombatService.Kill:Connect(onKill)

	-- Per-wave Coins pay out on WAVE CLEAR. Paying on clear (not wave start) also means the FINAL
	-- wave pays out. CHANGED: the bonus now honors the ended wave's coin event — surviving a Blood
	-- Moon / Gold Rush wave multiplies the clear payout too, not just the per-kill trickle.
	MatchService.WaveCleared:Connect(function(round)
		local mult = require(script.Parent.EventService).WaveCoinMult()
		local world = MatchService.GetState().map or GameConfig.DefaultMap
		MatchService.ForEachPlayer(function(player, ps)
			awardCoins(player, math.floor(GameConfig.LobbyMoneyPerWave * mult + 0.5))
			-- Analytics: this wave's Coins (kills + clear + event payouts) as ONE economy Source event.
			local earned = ps.telemCoins or 0
			if earned > 0 then
				ps.telemCoins = 0
				TelemetryService.Economy(player, "Source", earned, DataService.GetMoney(player), "Gameplay", "run_wave", world)
			end
		end)
	end)

	-- FRIEND BONUS bookkeeping: recompute whenever the server's roster changes.
	task.spawn(refreshFriendBonus)
	Players.PlayerAdded:Connect(function()
		task.delay(1, refreshFriendBonus) -- a beat so the newcomer's friend data is ready
	end)
	Players.PlayerRemoving:Connect(function(player)
		friendBonus[player.UserId] = nil
		task.defer(refreshFriendBonus) -- after the leaver is out of GetPlayers()
	end)

	-- Per-wave: small XP bonus + best-wave record for everyone currently playing.
	task.spawn(function()
		local lastRound = 0
		while true do
			local round = MatchService.GetRound()
			if round > lastRound and MatchService.GetPhase() == "Playing" then
				lastRound = round
				-- Only reward players actually IN the run.
				MatchService.ForEachPlayer(function(player)
					awardXP(player, ProgressionConfig.XPPerRound)
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
