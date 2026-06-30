--!strict
-- GameConfig.lua — global match tunables. Tune the whole game's feel + difficulty here.
-- This is the difficulty brain: round growth, health, speed, points, perf caps, rate limits.

local GameConfig = {}

-- ===== ROUNDS =====
GameConfig.BaseZombiesPerRound = 6
GameConfig.PlayerCountScale    = 0.5   -- +50% zombies per extra player
GameConfig.RoundZombieGrowth   = 1.15  -- zombie COUNT ×= this per round
GameConfig.RoundBreakSeconds   = 8     -- prep time between rounds

-- ===== PERFORMANCE (critical with hordes — see §13 of CLAUDE.md) =====
GameConfig.MaxAliveZombies   = 24      -- HARD cap on simultaneous zombies
GameConfig.ZombieAITickRate  = 0.2     -- seconds between AI re-targets (staggered across zombies)
GameConfig.PathRecompute     = 1.5     -- seconds between a zombie's path recomputes

-- ===== ZOMBIE SCALING =====
GameConfig.ZombieBaseHealth    = 50
GameConfig.ZombieHealthGrowth  = 1.1   -- health ×= this per round
GameConfig.ZombieBaseSpeed     = 8
GameConfig.ZombieSpeedPerRound = 0.15
GameConfig.ZombieMaxSpeed      = 22

-- ===== POINTS (CoD-Zombies style) =====
GameConfig.PointsPerHit       = 10
GameConfig.PointsPerKill      = 60
GameConfig.PointsHeadshotKill = 100    -- replaces PointsPerKill on a headshot kill
GameConfig.StartingPoints     = 500

-- ===== HEALTH =====
GameConfig.PlayerMaxHealth  = 100
GameConfig.HealthRegenDelay = 5        -- seconds undamaged before regen
GameConfig.HealthRegenRate  = 25       -- HP/sec once regenerating

-- ===== DOWN / REVIVE =====
GameConfig.BleedoutSeconds = 30
GameConfig.ReviveSeconds   = 4
GameConfig.ReviveHealthPct = 0.5       -- revived players come back at this % of max health

-- ===== MOVEMENT =====
GameConfig.PlayerWalkSpeed   = 16      -- base humanoid WalkSpeed (Stamin-Up multiplies this)
GameConfig.SprintMultiplier  = 1.4     -- sprint speed = WalkSpeed × this
GameConfig.SprintStaminaMax  = 100
GameConfig.SprintDrainPerSec = 25
GameConfig.SprintRegenPerSec = 15

-- ===== MATCH FLOW =====
GameConfig.LobbyCountdown     = 5      -- seconds in lobby before a match auto-starts
GameConfig.MinPlayersToStart  = 1      -- solo-playable
GameConfig.GameOverHoldSeconds = 10    -- summary screen time before returning to lobby

-- ===== AUTO-AIM SHOOTING =====
GameConfig.ArcDegrees = 180   -- a shot auto-targets the CLOSEST zombie within this arc in front of your aim
GameConfig.ArcRange   = 60    -- studs the auto-aim reaches

-- ===== RATE LIMITS (token bucket, max requests/sec per player) =====
GameConfig.RateLimits = {
	Fire = 20, Reload = 3, Buy = 6, Revive = 3, Interact = 8, Sprint = 10,
}

return GameConfig
