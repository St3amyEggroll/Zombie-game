--!strict
-- GameConfig.lua — global match tunables. Tune the whole game's feel + difficulty here.
-- This is the difficulty brain: round growth, health, speed, points, perf caps, rate limits.

local GameConfig = {}

-- ===== ROUNDS =====
GameConfig.BaseZombiesPerRound = 6
GameConfig.PlayerCountScale    = 0.5   -- +50% zombies per extra player
GameConfig.RoundZombieGrowth   = 1.15  -- zombie COUNT ×= this per round
GameConfig.RoundBreakSeconds   = 4     -- prep time between rounds

-- ===== PERFORMANCE (critical with hordes — see §13 of CLAUDE.md) =====
GameConfig.MaxAliveZombies   = 75      -- HARD cap on simultaneous zombies (owed extras wait for a kill,
                                       -- then spawn in — they don't despawn to make room)
GameConfig.ZombieAITickRate  = 0.2     -- seconds between AI re-targets (staggered across zombies)
GameConfig.PathRecompute     = 1.5     -- seconds between a zombie's path recomputes

-- ===== ZOMBIE SCALING =====
GameConfig.ZombieBaseHealth    = 50
GameConfig.ZombieHealthGrowth  = 1.1   -- health ×= this per round
GameConfig.ZombieBaseSpeed     = 8
GameConfig.ZombieSpeedPerRound = 0.15
GameConfig.ZombieMaxSpeed      = 22

-- ===== POINTS (CoD-Zombies style) — the IN-WAVE cash you spend at the shop (resets every run) =====
GameConfig.PointsPerHit       = 10
GameConfig.PointsPerKill      = 60
GameConfig.PointsHeadshotKill = 100    -- replaces PointsPerKill on a headshot kill
GameConfig.StartingPoints     = 500

-- ===== LOBBY MONEY (the PERSISTENT currency — "Coins" — earned during a run, spent in the lobby) =====
-- Earned live as you play (so it ticks up on the HUD) and saved to your profile; the lobby menu shows the
-- total. This is separate from the in-wave cash above.
GameConfig.LobbyMoneyPerKill = 1
GameConfig.LobbyMoneyPerWave = 25

-- ===== HEALTH =====
GameConfig.PlayerMaxHealth  = 100
GameConfig.HealthRegenDelay = 5        -- seconds undamaged before regen
GameConfig.HealthRegenRate  = 25       -- HP/sec once regenerating
GameConfig.LowHealthPct     = 0.4      -- at/below this fraction of max HP the red vignette + heartbeat kick in

-- ===== KILL STREAK ===== (chain kills WITHOUT taking damage for escalating cash)
GameConfig.KillStreakBonusPerKill = 0.08  -- +8% cash per kill in the current streak
GameConfig.KillStreakMaxMult      = 2.0   -- streak cash multiplier caps here
GameConfig.KillStreakShowAt       = 3     -- streak length before the on-screen flair appears

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

-- ===== TESTING / DEBUG ===== (turn these OFF for the real game)
GameConfig.DebugUnlockAllWeapons = true   -- every player starts owning every weapon
GameConfig.DebugStartWave        = 10     -- start the match at this wave (0 = normal, start at wave 1)

-- ===== MATCH FLOW =====
GameConfig.LobbyCountdown     = 5      -- seconds in lobby before a match auto-starts
GameConfig.MinPlayersToStart  = 1      -- solo-playable
GameConfig.GameOverHoldSeconds = 10    -- summary screen time before returning to lobby

-- ===== AUTO-AIM SHOOTING =====
GameConfig.ArcDegrees = 100   -- a shot auto-targets the CLOSEST zombie within this arc in front of your aim
                              -- (100 = a 100° cone, ±50° from where you face)
GameConfig.ArcRange   = 60    -- studs the auto-aim reaches

-- ===== RANGE FALLOFF ===== (damage drops with distance, so positioning matters)
-- Full damage out to FalloffStart, then linearly down to FalloffMinMult× at FalloffEnd and beyond.
GameConfig.FalloffStart   = 25   -- studs: closer than this = full damage
GameConfig.FalloffEnd     = 60   -- studs: at/after this = minimum damage (keep <= ArcRange)
GameConfig.FalloffMinMult = 0.45 -- damage multiplier at/after FalloffEnd

-- ===== RATE LIMITS (token bucket, max requests/sec per player) =====
GameConfig.RateLimits = {
	Fire = 20, Reload = 3, Buy = 6, Revive = 3, Interact = 8, Sprint = 10,
}

return GameConfig
