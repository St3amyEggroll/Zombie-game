--!strict
-- GameConfig.lua — global match tunables. Tune the whole game's feel + difficulty here.
-- This is the difficulty brain: round growth, health, speed, points, perf caps, rate limits.

local GameConfig = {}

-- ===== ROUNDS =====
GameConfig.BaseZombiesPerRound = 6
GameConfig.PlayerCountScale    = 0.5   -- +50% zombies per extra player
GameConfig.RoundZombieGrowth   = 1.20  -- zombie COUNT ×= this per round
GameConfig.RoundBreakSeconds   = 8     -- prep time between rounds (the EVENT WHEEL spins + NEXT WAVE countdown)

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

-- NEW: COIN BUNDLES sellable IN-GAME too — the gold "+" beside the HUD coin counter opens a buy card
-- (broke mid-run at the gun shop = the moment that matters). These are the SAME four Developer
-- Products as the lobby's PASSES & COINS tab: create them ONCE in Creator Hub, then paste each id
-- BOTH here and in the lobby's SHOP.CoinBundles. Purchased coins are granted RAW (the 2x Coins
-- gamepass never doubles Robux-bought coins). id = 0 → that row shows COMING SOON.
GameConfig.CoinBundleProducts = {
	{ id = 0, coins = 1000 },
	{ id = 0, coins = 5000,  bonus = "+5%" },
	{ id = 0, coins = 15000, bonus = "+15%" },
	{ id = 0, coins = 50000, bonus = "+30%" },
}

-- ===== GAMEPASSES ===== (owner-created in Creator Hub → Passes). Benefits are server-side:
-- 2x Coins doubles every Coin grant in a run, 2x XP doubles account XP, VIP = overhead tag + a free
-- rare crate daily (the lobby handles the crate). Keep ids in sync with the lobby's GAMEPASSES table.
GameConfig.GamepassCoins2x = 1906963090
GameConfig.GamepassXP2x    = 1907131130
GameConfig.GamepassVIP     = 1906069123

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

-- ===== ONE DIFFICULTY (the old Easy..Nightmare/Endless system is GONE) =====
-- Every world runs ENDLESS waves with ONE tuning curve; a run only ends by EXTRACTION (cash out) or a
-- team wipe. Worlds get harder via their own mult/speedMult (see Maps below) on top of these baselines.
GameConfig.WaveMult   = 1.6                                    -- ×zombie HP + damage baseline (all worlds)
GameConfig.BossEvery  = 10                                     -- a boss every Nth wave...
GameConfig.BossRoster = { "boss", "lumberjack", "necromancer" } -- ...cycling this roster forever

GameConfig.Worlds        = { "forest", "islands" }
GameConfig.DefaultMap    = "forest"
GameConfig.AllWorldsOpen = true -- OPEN EVERY MAP for now (must mirror the lobby's ALL_WORLDS_OPEN, or the
                                -- game re-validates the teleport and silently swaps the map back to Default)
-- Worlds unlock by ACCOUNT LEVEL now (no more "beat Nightmare" gates). Tune per world; 0 = always open.
GameConfig.WorldUnlockLevel = { forest = 0, islands = 8 }

-- (EXTRACTION and the CONTINUOUS-HORDE/POWER-DRAFT experiments are both DEAD — the shipped loop is
-- wave-based + the EVENT WHEEL below. Extraction's table is kept so stale reads don't explode.)
GameConfig.Extraction = { Every = 0, WindowSeconds = 20, MultPerStage = 0.5 }

-- ===== THE EVENT WHEEL ===== (EventService) — EVERY wave break the wheel visibly SPINS and lands on
-- next wave's modifier. Events last the WHOLE wave they land on. CALM (a normal wave) is on the wheel
-- too — its weight shrinks as waves climb, so deep runs get wilder. (0 weight disables an outcome.)
GameConfig.Events = {
	SpinSeconds = 3,          -- how long the client wheel animates before the reveal (< RoundBreakSeconds)
	Weights = { calm = 0, bloodmoon = 3, fog = 3, meteors = 3, lightning = 3 }, -- base weights (calm's is computed below)
	CalmBase = 10,            -- calm's weight on wave 1...
	CalmDecayPerWave = 0.5,   -- ...shrinking by this per wave...
	CalmMin = 2,              -- ...but never below this (a breather is always possible)
	-- BLOOD MOON: the sky bleeds; the whole wave is faster zombies + DOUBLE Coins per kill.
	BloodMoonSpeedMult = 1.35, -- ×zombie speed for the wave
	BloodMoonCoinMult  = 2,    -- ×Coins per kill for the wave
	-- METEOR SHOWER: red target circles rain the whole wave.
	MeteorEvery  = 2.2,        -- seconds between strikes
	MeteorDamage = 25,         -- to players inside a blast
	MeteorRadius = 9,          -- studs
	-- LIGHTNING STORM: the INVERSE of meteors — bolts kill ZOMBIES in the blue circles all wave
	-- (kite the horde into them). Players are never hurt; bosses only take a chunk, never the kill.
	LightningEvery     = 2.0,  -- seconds between bolts
	LightningRadius    = 10,   -- studs
	LightningBossFrac  = 0.05, -- bosses caught in a bolt lose this fraction of MAX HP (no instant kill)
}

-- ===== MAPS / WORLDS ===== how each world plays (this IS the difficulty table now — one row per world).
--   emerge         = how zombies surface: "grave" (dig out of the ground) | "water" (rise from the ocean).
--   useSpawnPoints = true → spawn AT ZombieSpawn-tagged parts (place them where zombies appear); false →
--                    spawn ~35 studs from a random living player (the Forest default).
--   mult/speedMult = ×zombie HP+damage / ×speed for THIS world (on top of GameConfig.WaveMult).
-- Add a world = add a row here + build its map + tag its spawns (see MAPS.md).
GameConfig.Maps = {
	forest  = { emerge = "grave", useSpawnPoints = false, mult = 1.0, speedMult = 1.0 },
	islands = { emerge = "water", useSpawnPoints = true, mult = 1.3, speedMult = 1.06 },
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
