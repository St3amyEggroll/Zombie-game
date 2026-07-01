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

-- ===== POINTS — the IN-WAVE cash from kills (resets every run; spent on TRAPS for now) =====
GameConfig.PointsPerHit       = 10
GameConfig.PointsPerKill      = 60
GameConfig.PointsHeadshotKill = 100    -- replaces PointsPerKill on a headshot kill
GameConfig.StartingPoints     = 500

-- ===== LOBBY MONEY (the PERSISTENT currency — "Coins" — earned during a run, spent in the lobby) =====
-- Earned live as you play (so it ticks up on the HUD) and saved to your profile; the lobby menu shows the
-- total. This is separate from the in-wave cash above.
GameConfig.LobbyMoneyPerKill = 1
GameConfig.LobbyMoneyPerWave = 25

-- ===== CRIT ===== (crit chance/damage come from the in-run buff draft; this is the base a crit adds)
GameConfig.CritBaseBonus = 0.5   -- a crit does +50% damage baseline; the Crit Damage buff adds on top

-- ===== HEALTH =====
GameConfig.PlayerMaxHealth  = 100
GameConfig.HealthRegenDelay = 5        -- seconds undamaged before regen
GameConfig.HealthRegenRate  = 25       -- HP/sec once regenerating
GameConfig.LowHealthPct     = 0.4      -- at/below this fraction of max HP the red vignette + heartbeat kick in

-- ===== KILL STREAK ===== (chain kills WITHOUT taking damage for escalating cash)
GameConfig.KillStreakBonusPerKill = 0.08  -- +8% cash per kill in the current streak
GameConfig.KillStreakMaxMult      = 2.0   -- streak cash multiplier caps here
GameConfig.KillStreakShowAt       = 3     -- streak length before the on-screen flair appears

-- ===== MOVEMENT =====
GameConfig.PlayerWalkSpeed   = 16      -- base humanoid WalkSpeed (Stamin-Up multiplies this)
GameConfig.SprintMultiplier  = 1.4     -- sprint speed = WalkSpeed × this
GameConfig.SprintStaminaMax  = 100
GameConfig.SprintDrainPerSec = 25
GameConfig.SprintRegenPerSec = 15

-- ===== TESTING / DEBUG ===== (turn these OFF for the real game)
GameConfig.DebugUnlockAllWeapons = false  -- every player starts owning every weapon
GameConfig.DebugStartWave        = 0      -- start the match at this wave (0 = normal, start at wave 1)

-- ===== DIFFICULTY ===== (set by the lobby; caps how far a run goes — clearing the final wave = VICTORY)
GameConfig.Difficulties = {
	easy      = { name = "Easy",      maxWave = 10 },
	medium    = { name = "Medium",    maxWave = 20 },
	hard      = { name = "Hard",      maxWave = 25 },
	nightmare = { name = "Nightmare", maxWave = 30 },
}
GameConfig.DefaultDifficulty = "nightmare"  -- used in Studio / if the lobby didn't send one
GameConfig.VictoryBonusCoins = 250          -- persistent Coins awarded for completing (winning) a run

-- Progression: difficulties unlock in ORDER (beat Easy → Medium unlocks, etc.); beating a world's LAST
-- difficulty (nightmare) unlocks the next World. Only Forest exists so far.
GameConfig.DifficultyOrder = { "easy", "medium", "hard", "nightmare" }
GameConfig.Worlds          = { "forest" }
GameConfig.DefaultMap      = "forest"

-- ===== AUTO-AIM SHOOTING =====
GameConfig.ArcDegrees = 60    -- a shot auto-targets the CLOSEST zombie within this arc in front of your aim
                              -- (60 = a 60° cone, ±30° from where you face)
GameConfig.ArcRange   = 60    -- studs the auto-aim reaches

-- ===== RANGE FALLOFF ===== (damage drops with distance, so positioning matters)
-- Full damage out to FalloffStart, then linearly down to FalloffMinMult× at FalloffEnd and beyond.
GameConfig.FalloffStart   = 25   -- studs: closer than this = full damage
GameConfig.FalloffEnd     = 60   -- studs: at/after this = minimum damage (keep <= ArcRange)
GameConfig.FalloffMinMult = 0.45 -- damage multiplier at/after FalloffEnd

-- ===== RATE LIMITS (token bucket, max requests/sec per player) =====
GameConfig.RateLimits = {
	Fire = 20, Buy = 6, Interact = 8, Sprint = 10,
}

-- ===== ELITE (buffed) ZOMBIES ===== a small chance any spawned zombie is an "elite": tougher, glows
-- yellow (for testing), and DROPS A POTION on death (into your persistent potion inventory → usable in the
-- lobby/game). For now the only buff is health ×EliteHealthMult.
GameConfig.EliteChance         = 0.05                 -- 5% of normal spawns become elites
GameConfig.EliteHealthMult     = 4                    -- elites have 4× a normal same-type zombie's health
GameConfig.EliteHighlightColor = Color3.fromRGB(255, 225, 40) -- yellow test highlight
GameConfig.PotionDrops         = { "luck", "xp" }     -- potion ids an elite can drop (match the lobby POTIONS)

-- ===== POTION EFFECTS ===== consumed IN A RUN (in-game inventory → Use). Effects last the rest of the run
-- and stack. XP boosts how fast the run's buff-draft bar fills; Luck raises the buff-draft rarity odds.
GameConfig.PotionEffects = {
	xpMultBonus = 1.0,  -- XP Potion: +100% run XP per potion (2× with one, 3× with two, …)
	luckBonus   = 0.2,  -- Luck Potion: +0.2 to the run's Luck (better buff-draft rarities) per potion
}

return GameConfig
