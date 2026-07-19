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

-- (FLAWLESS WAVES + KILL STREAK both REMOVED — owner call: per-wave Coins pay flat, kills pay flat.)

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

-- ===== THE EVENT ROLLER ===== (EventService) — EVERY wave break the roller flashes and locks next
-- wave's modifier. Events last the WHOLE wave they land on. Odds are PER EVENT (owner call — no
-- rarity tiers): each event's weight IS its slice, tuned as a descending ladder from everyday CALM
-- down to the 0.5% GOD MODE. Weights sum to ~100 so each number reads as its own percent on wave 1;
-- CALM thins per wave, which nudges everything else up as runs go deep. (0 disables an event.)
GameConfig.Events = {
	SpinSeconds = 3,          -- how long the client roller flashes before the reveal (< RoundBreakSeconds)
	Weights = {
		calm       = 18,
		fog        = 13,
		rain       = 12,
		meteors    = 10,
		bombsquad  = 9,
		earthquake = 8,
		bloodmoon  = 7,
		lightning  = 6,
		acidrain   = 5,
		hounds     = 4,
		purge      = 3,
		bodyguards = 2,
		goldrush   = 1.5,
		apocalypse = 1,
		godmode    = 0.5,
	},
	CalmDecayPerWave = 0.5,   -- calm's weight shrinks by this per wave...
	CalmMin = 8,              -- ...but never below this (a plain wave stays possible)

	-- BLOOD MOON (rare): the sky bleeds; the whole wave is faster zombies + DOUBLE Coins per kill.
	BloodMoonSpeedMult = 1.35, -- ×zombie speed for the wave
	BloodMoonCoinMult  = 2,    -- ×Coins per kill for the wave
	-- METEOR SHOWER (uncommon): telegraphed strikes all wave. OVERHAULED: real tumbling rocks (the
	-- owner's models in ReplicatedStorage > Assets > Meteors), never landing right on a player, and
	-- they crush ZOMBIES too (dead-center = death; edge = half max HP; bosses only chip).
	MeteorEvery      = 2.2,   -- seconds between strikes
	MeteorDamage     = 25,    -- to players inside the blast
	MeteorRadius     = 9,     -- studs
	MeteorMinDist    = 16,    -- strikes land in a ring this far from the anchor player...
	MeteorMaxDist    = 36,    -- ...out to this far (never on top of them — owner report)
	MeteorBossFrac   = 0.05,  -- bosses caught in a blast lose this fraction of MAX HP
	-- LIGHTNING STORM (rare): the INVERSE of meteors — bolts kill ZOMBIES in the blue circles all
	-- wave (kite the horde into them). Players are never hurt; bosses only take a chunk.
	LightningEvery     = 2.0,  -- seconds between bolts
	LightningRadius    = 10,   -- studs
	LightningBossFrac  = 0.05, -- bosses caught in a bolt lose this fraction of MAX HP (no instant kill)
	-- BOMB SQUAD (uncommon): the wave is salted with bomb zombies whose blasts CHAIN into other zombies.
	BombShare = 0.4,           -- fraction of spawns forced to bomb zombies
	-- EARTHQUAKE (uncommon): periodic tremors — screen shake + every non-boss zombie staggers.
	QuakeEvery = 8,            -- seconds between tremors
	QuakeStun  = 1.4,          -- zombie stagger seconds per tremor
	-- ACID RAIN (rare): green splashes leave sizzling puddles that burn PLAYERS standing in them.
	AcidEvery      = 1.7,      -- seconds between splashes
	AcidPuddleSecs = 8,        -- how long each puddle sizzles
	AcidDPS        = 8,        -- damage per second standing in one
	AcidRadius     = 6,        -- studs
	-- BLOODHOUNDS (rare): a hunting pack — a big share of spawns are sprinting dog zombies.
	HoundShare = 0.35,
	-- THE PURGE (epic): a SEA of regular zombies — nothing special, just far too many.
	PurgeCountMult = 3,        -- ×wave count (capped by MaxZombiesPerWave/MaxAliveZombies as usual)
	-- BODYGUARDS (epic): two brutes guard a coin pile; kill BOTH and the whole team gets paid.
	GuardCoins     = 400,      -- Coins for EVERY in-run player when both guards die
	GuardCountMult = 0.6,      -- the regular wave thins out so the duel is the focus
	-- GOLD RUSH (legendary): the greed print.
	GoldRushCoinMult = 5,      -- ×Coins per kill
	GoldRushHPMult   = 1.75,   -- ×zombie HP for the wave
	-- APOCALYPSE (mythic): meteors + acid rain + earthquakes all at once — paid like a jackpot.
	ApocCoinMult = 3,
	-- GOD MODE (divine): players take ZERO damage all wave. The 1% miracle; coins stay normal.
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
