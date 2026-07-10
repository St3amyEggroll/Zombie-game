--!strict
-- GameConfig.lua — global match tunables. Tune the whole game's feel + difficulty here.
-- This is the difficulty brain: round growth, health, speed, points, perf caps, rate limits.

local GameConfig = {}

-- ===== ROUNDS =====
GameConfig.BaseZombiesPerRound = 6
GameConfig.PlayerCountScale    = 0.5   -- +50% zombies per extra player
GameConfig.RoundZombieGrowth   = 1.20  -- zombie COUNT ×= this per round
GameConfig.RoundBreakSeconds   = 5     -- prep time between rounds (clients show a NEXT WAVE countdown)

-- ===== ROBUX (Developer Products) =====
-- SKIP WAVE (the small gold button beside the enemies bar). Create a Developer Product in
-- Creator Hub -> your experience -> Monetization -> Developer Products, then paste its id here.
-- 0 = not set up yet (the button warns in Output instead of prompting).
GameConfig.SkipWaveProductId = 0

-- NEW: ROBUX REVIVE (the gold button on the death screen). Same setup: create a Developer Product in
-- Creator Hub -> Monetization -> Developer Products and paste its id here. 0 = the button is hidden.
-- On a FULL TEAM WIPE the run holds for ReviveGraceSeconds before ending, so a solo player (or the
-- last one down) can buy back in; a revive cancels the wipe and the run rolls on.
GameConfig.ReviveProductId    = 0
GameConfig.ReviveGraceSeconds = 12

-- ===== PERFORMANCE (critical with hordes — see §13 of CLAUDE.md) =====
GameConfig.MaxAliveZombies   = 200     -- HARD cap on simultaneous zombies (owed extras wait for a kill,
                                       -- then spawn in — they don't despawn to make room)
GameConfig.ZombieAITickRate  = 0.45    -- seconds between AI re-targets (staggered across zombies)
GameConfig.PathRecompute     = 3.5    -- seconds between a zombie's path recomputes
GameConfig.MaxZombiesPerWave = 300    -- cap on a single wave's OWED count (deep Endless waves would
                                      -- otherwise owe thousands and never end)

-- ===== ZOMBIE SCALING =====
GameConfig.ZombieBaseHealth    = 50
GameConfig.ZombieHealthGrowth  = 1.1   -- health ×= this per round
GameConfig.ZombieBaseSpeed     = 8
GameConfig.ZombieSpeedPerRound = 0.15
GameConfig.ZombieMaxSpeed      = 22

-- ===== POINTS — the IN-WAVE cash from kills (resets every run; spent on TRAPS for now) =====
GameConfig.PointsPerHit       = 1      -- per-PELLET: shotguns land 6 of these per shell
GameConfig.PointsPerKill      = 15
GameConfig.PointsHeadshotKill = 25     -- replaces PointsPerKill on a headshot kill
GameConfig.StartingPoints     = 500

-- ===== LOBBY MONEY (the PERSISTENT currency — "Coins" — earned during a run, spent in the lobby) =====
-- Earned live as you play (so it ticks up on the HUD) and saved to your profile; the lobby menu shows the
-- total. This is separate from the in-wave cash above.
GameConfig.LobbyMoneyPerKill = 2
GameConfig.LobbyMoneyPerWave = 50

-- ===== CRIT ===== (crit chance/damage come from the in-run buff draft; this is the base a crit adds)
GameConfig.CritBaseBonus = 0.5   -- a crit does +50% damage baseline; the Crit Damage buff adds on top

-- ===== HEALTH =====
GameConfig.PlayerMaxHealth  = 100
GameConfig.ZombieDamageMult = 0.55 -- GLOBAL bite/explosion damage dial (zombies hit way too hard at 1)
GameConfig.HealthRegenDelay = 5        -- seconds undamaged before regen
GameConfig.HealthRegenRate  = 25       -- HP/sec once regenerating
GameConfig.LowHealthPct     = 0.4      -- at/below this fraction of max HP the red vignette + heartbeat kick in

-- ===== FLAWLESS WAVES ===== (co-op care pays: clear a wave with NOBODY downed and the whole team's
-- per-wave Coin payout climbs; any down resets the streak)
GameConfig.FlawlessBonusPerWave = 0.25 -- +25% wave Coins per consecutive flawless wave
GameConfig.FlawlessMaxMult      = 2.0  -- the flawless multiplier caps here

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
-- Each mode defines its own wave count, roster, and boss schedule. Per-mode fields:
--   maxWave    = final wave (clearing it = victory; math.huge = Endless).
--   mult       = ×zombie HP + damage.
--   speedMult  = ×zombie speed (Nightmare/Endless run a touch faster).
--   roster     = ONLY these enemy ids spawn (whitelist). exclude = every enemy EXCEPT these (blacklist).
--                Omit both = every enemy allowed by the map/round. (Bosses are separate — see `bosses`.)
--   bosses     = { [wave] = bossId } scheduled bosses. Endless has none → it cycles bosses every 10th wave.
--   earlyBonus = extra zombies at wave 1, tapering to 0 by the final wave — front-loads the horde WITHOUT
--                changing the final-wave size (Nightmare piles them on early but ends like Hard).
GameConfig.Difficulties = {
	easy      = { name = "Easy",      maxWave = 10, mult = 1.0,
		roster = { "default", "speedy", "lead", "leaper" }, bosses = { [10] = "boss" } },
	medium    = { name = "Medium",    maxWave = 15, mult = 1.6,
		exclude = { bombzombie = true, leapertank = true, necromancer = true },
		bosses = { [10] = "boss", [15] = "lumberjack" } },
	hard      = { name = "Hard",      maxWave = 20, mult = 2.4,
		bosses = { [10] = "boss", [20] = "necromancer" } }, -- every enemy
	nightmare = { name = "Nightmare", maxWave = 20, mult = 2.4, speedMult = 1.12, earlyBonus = 1.5,
		bosses = { [10] = "boss", [20] = "necromancer" } }, -- = Hard, a bit faster + a lot more early
	-- Unlocked by BEATING Nightmare: no final wave, no victory — the run only ends on a wipe. Bosses cycle
	-- every 10th wave so case drops keep flowing at depth.
	endless   = { name = "Endless",   maxWave = math.huge, mult = 2.4, speedMult = 1.12 },
}
GameConfig.DefaultDifficulty = "nightmare"  -- used in Studio / if the lobby didn't send one
GameConfig.VictoryBonusCoins = 250          -- persistent Coins awarded for completing (winning) a run

-- Progression: difficulties unlock in ORDER (beat Easy → Medium unlocks, etc.); beating a world's LAST
-- difficulty (nightmare) unlocks the next World. Only Forest exists so far.
GameConfig.DifficultyOrder = { "easy", "medium", "hard", "nightmare", "endless" }
GameConfig.Worlds          = { "forest", "islands" }
GameConfig.DefaultMap      = "forest"
GameConfig.AllWorldsOpen   = true -- OPEN EVERY MAP for now (must mirror the lobby's ALL_WORLDS_OPEN, or the
                                  -- game re-validates the teleport and silently swaps the map back to Default)

-- ===== MAPS / WORLDS ===== how each world plays.
--   emerge         = how zombies surface: "grave" (dig out of the ground) | "water" (rise from the ocean).
--   useSpawnPoints = true → spawn AT ZombieSpawn-tagged parts (place them where zombies appear); false →
--                    spawn ~35 studs from a random living player (the Forest default).
-- Add a world = add a row here + build its map + tag its spawns (see MAPS.md).
GameConfig.Maps = {
	forest  = { emerge = "grave", useSpawnPoints = false },
	islands = { emerge = "water", useSpawnPoints = true },
}

-- ===== PRE-RUN COUNTDOWN ===== waves don't start until the whole party has loaded in (or the timer
-- runs out). Once everyone expected is present, the countdown snaps down to the quick value.
GameConfig.StartCountdownSeconds = 30  -- max wait for the party to load in
GameConfig.StartCountdownQuick   = 3   -- countdown once everyone is in

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
	Fire = 40, Buy = 6, Interact = 8, Sprint = 10, Revive = 10, -- Fire headroom for upgraded fire rates
	Settings = 3, -- volume-slider saves
	GetData = 3, InvSnapshot = 4, LoadoutResend = 4, -- read-only client-triggered pulls (anti-spam)
}

-- ===== CASE DROPS (every 10th wave cleared, EVERY player gets one random-rarity case) =====
-- The case pops out and homes to each player like a potion drop. Rarity odds shift UP the deeper you go:
-- weight(tier) = CaseWeightsBase[tier] * CaseWeightGrowth ^ ((tier-1) * stage), stage = wave/10 - 1.
GameConfig.CaseDropEvery   = 10
GameConfig.CaseRarities    = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "divine" }
GameConfig.CaseWeightsBase = { 50, 25, 12, 7, 4, 1.5, 0.5 } -- odds at wave 10 (per rarity, in order)
GameConfig.CaseWeightGrowth = 1.5                            -- higher = deeper waves upgrade odds faster

-- (ELITE golden zombies REMOVED — no more random 4×-HP glowing spawns.)

-- ===== DOWN / REVIVE (co-op) ===== at 0 HP with a teammate still UP you go DOWNED (crawl, untargetable)
-- instead of dying; a teammate holds E next to you to revive. Solo death — or bleeding out, or the whole
-- team being down — ends the run (back to the lobby).
GameConfig.BleedoutSeconds = 30   -- seconds downed before you bleed out (run ends for you)
GameConfig.ReviveSeconds   = 4    -- seconds a teammate must hold E to revive you
GameConfig.ReviveRange     = 6    -- studs the reviver must stay within
GameConfig.ReviveHealthPct = 0.5  -- revived players come back at this fraction of max health
GameConfig.DownedWalkSpeed = 4    -- crawl speed while downed

return GameConfig
