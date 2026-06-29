--!nonstrict
-- MatchService.lua — match lifecycle + round manager. **THE core service.**
--
-- ⚠ PHASE 0 SKELETON. This owns the ephemeral per-match state table (CLAUDE.md §6) and runs the
-- lobby -> starting -> playing state machine so it's verifiable now. The REAL round loop (compute
-- zombie count, tell ZombieService to spawn over time, wait for the round to clear, run the break,
-- advance, spawn bosses on BossInterval) lands in Phase 2 and replaces runMatch()'s body — the
-- public API and the state table below are the stable seam everything else plugs into.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local Remotes = require(Modules.Remotes)

local MatchService = {}

-- ===== EPHEMERAL MATCH STATE (server memory only; discarded at game over) =====
local state = {
	phase = "Lobby",        -- Lobby | Starting | Playing | RoundBreak | GameOver
	round = 0,
	zombiesRemaining = 0,   -- still owed to spawn this round (Phase 2 uses this)
	zombiesAlive = 0,       -- currently alive in the world (Phase 2 uses this)
	players = {},           -- [userId] = PlayerMatchState
	startedAt = 0,
}
MatchService.State = state

local matchRunning = false

-- ===== INTERNAL =====
local function setPhase(phase: string)
	state.phase = phase
	Remotes.Get("MatchStateChanged"):FireAllClients(phase, state.round)
	print(("[MatchService] phase -> %s (round %d)"):format(phase, state.round))
end

-- Build a fresh per-match state for a player. Everyone starts with a pistol (CoD-classic).
local function makePlayerState(player: Player)
	local pistol = WeaponConfig.pistol
	return {
		userId = player.UserId,
		points = GameConfig.StartingPoints,
		ownedWeapons = { "pistol" },
		equippedWeapon = "pistol",
		ammo = { pistol = { mag = pistol.magSize, reserve = pistol.reserveAmmo } },
		perks = {},
		packAPunched = {},
		isDown = false,
		isDead = false,
		health = GameConfig.PlayerMaxHealth,
		maxHealth = GameConfig.PlayerMaxHealth,
		kills = 0,
		specialKills = 0,
		revives = 0,
	}
end

-- The match coroutine. PHASE 0: lobby countdown -> round 1, then hold in Playing.
local function runMatch()
	setPhase("Starting")
	for _ = GameConfig.LobbyCountdown, 1, -1 do
		task.wait(1)
	end

	state.round = 1
	state.startedAt = os.clock()
	setPhase("Playing")
	Remotes.Get("RoundChanged"):FireAllClients(state.round)

	-- ── PHASE 2 REPLACES EVERYTHING BELOW ──────────────────────────────────────────
	-- while not all players down/dead do
	--   count = floor(BaseZombiesPerRound × RoundZombieGrowth^(round-1) × (1+(players-1)×scale))
	--   ZombieService.SpawnWave(round, count)  -- respects MaxAliveZombies
	--   wait until round cleared
	--   setPhase("RoundBreak"); task.wait(RoundBreakSeconds)
	--   MatchService.AdvanceRound()
	--   if round % ZombieConfig.BossInterval == 0 then ZombieService.SpawnBoss(round) end
	-- end
	-- MatchService.EndMatch()
	-- ────────────────────────────────────────────────────────────────────────────────
	print("[MatchService] Phase 0 skeleton: holding at round 1 (round loop arrives in Phase 2).")
end

local function tryStartMatch()
	if matchRunning or state.phase ~= "Lobby" then
		return
	end
	if #Players:GetPlayers() < GameConfig.MinPlayersToStart then
		return
	end
	matchRunning = true
	task.spawn(runMatch)
end

-- ===== PUBLIC API (stable seam for other services) =====
function MatchService.GetState()
	return state
end

function MatchService.GetPhase(): string
	return state.phase
end

function MatchService.GetRound(): number
	return state.round
end

function MatchService.GetPlayerState(player: Player)
	return state.players[player.UserId]
end

-- Run `fn(player, playerState)` for every connected player that has match state.
function MatchService.ForEachPlayer(fn: (Player, any) -> ())
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps then
			fn(player, ps)
		end
	end
end

-- Advance to the next round (called by the Phase 2 round loop).
function MatchService.AdvanceRound()
	state.round += 1
	Remotes.Get("RoundChanged"):FireAllClients(state.round)
	Remotes.Get("MatchStateChanged"):FireAllClients(state.phase, state.round)
	print(("[MatchService] advanced to round %d"):format(state.round))
end

-- Force a phase transition (used by later phases, e.g. RoundBreak).
function MatchService.SetPhase(phase: string)
	setPhase(phase)
end

-- End the match. Progression/leaderboard hook into GameOver in later phases.
function MatchService.EndMatch()
	if state.phase == "GameOver" then
		return
	end
	setPhase("GameOver")
	-- (Phase 8: ProgressionService awards XP + updates bestRound here; then we reset to Lobby.)
end

-- ===== LIFECYCLE =====
function MatchService.Start()
	for _, player in Players:GetPlayers() do
		state.players[player.UserId] = makePlayerState(player)
	end

	Players.PlayerAdded:Connect(function(player)
		state.players[player.UserId] = makePlayerState(player)
		-- Sync the freshly-joined client to the current phase.
		Remotes.Get("MatchStateChanged"):FireClient(player, state.phase, state.round)
		tryStartMatch()
	end)

	Players.PlayerRemoving:Connect(function(player)
		state.players[player.UserId] = nil
	end)

	tryStartMatch()
	print("[MatchService] started (Phase 0 skeleton)")
end

return MatchService
