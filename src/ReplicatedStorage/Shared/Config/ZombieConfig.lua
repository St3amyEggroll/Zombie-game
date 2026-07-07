--!strict
-- ZombieConfig.lua — archetypes. "isSpecial" = announce + unique VFX on spawn. Add an enemy = add a table
-- entry (no logic edits). Behavior flags (isBomb / canFly / summons) are read by ZombieService.
--
-- World 1 (Forest) roster + when each first appears (minRound):
--   default 1 · speedy 3 · lead 6 · leaper 11 · tank 15 · bombzombie 21 · ghost 26
--   Tank variants: speedytank 17 · leapertank 18 · leadtank 22
-- Bosses (BossWaves): 10 = Boss · 20 = Lumberjack · 30 = Necromancer  (wave 25 has NO boss).

export type ZombieType = {
	id: string, name: string,
	healthMult: number,  -- × the round's base health
	speedMult: number,   -- × the round's base speed
	damage: number,      -- per hit to a player (bomb uses its own explosion damage instead)
	pointsMult: number,  -- × base kill points
	isSpecial: boolean,
	minRound: number,
	spawnWeight: number, -- relative; 0 = never random (bosses)
	tint: Color3,
	canLeap: boolean?,   -- pounces in an arc toward the player (Leaper)
	isBomb: boolean?,    -- lights a fuse near you, then explodes (BombZombie)
	canFly: boolean?,    -- hovers and dive-bombs from above (Ghost)
	summons: boolean?,   -- periodically spawns extra zombies (Necromancer)
}

-- ===== ZOMBIE TABLE =====
-- The `id` must match your model's name under Assets > Zombies > <id> (else the default model is used).
local ZombieConfig: { [string]: any } = {
	-- Basic grunt.
	default    = { id="default",    name="Zombie",      healthMult=1,    speedMult=1,    damage=20, pointsMult=1,   isSpecial=false, minRound=1,  spawnWeight=100, tint=Color3.fromRGB(90,110,80) },
	-- Fragile but FAST — rushes you.
	speedy     = { id="speedy",     name="Speedy",      healthMult=0.55, speedMult=2.1,  damage=12, pointsMult=1.4, isSpecial=false, minRound=3,  spawnWeight=45,  tint=Color3.fromRGB(220,200,70) },
	-- Heavy mid-tier bullet-sponge.
	lead       = { id="lead",       name="Lead",        healthMult=2.6,  speedMult=0.85, damage=35, pointsMult=1.9, isSpecial=false, minRound=6,  spawnWeight=22,  tint=Color3.fromRGB(120,125,135) },
	-- Springy — pounces to close the gap.
	leaper     = { id="leaper",     name="Leaper",      healthMult=0.8,  speedMult=1.15, damage=18, pointsMult=1.7, isSpecial=false, minRound=11, spawnWeight=30,  tint=Color3.fromRGB(150,90,170), canLeap=true },
	-- Rare, huge HP, slow, devastating melee.
	tank       = { id="tank",       name="Tank",        healthMult=7,    speedMult=0.5,  damage=55, pointsMult=3.5, isSpecial=true,  minRound=15, spawnWeight=8,   tint=Color3.fromRGB(60,70,60) },
	-- Runs at you, lights a short fuse when close, then explodes for AoE. damage=0: it NEVER bites —
	-- the creeper-style explosion (ZombieService BOMB_DAMAGE) is its only attack.
	bombzombie = { id="bombzombie", name="Bomb Zombie", healthMult=1.2,  speedMult=1.0,  damage=0,  pointsMult=2.2, isSpecial=false, minRound=21, spawnWeight=16,  tint=Color3.fromRGB(200,80,50),  isBomb=true },
	-- Hovers above and dive-bombs; as fast as a Speedy.
	ghost      = { id="ghost",      name="Ghost",       healthMult=0.7,  speedMult=2.1,  damage=16, pointsMult=2.0, isSpecial=false, minRound=26, spawnWeight=20,  tint=Color3.fromRGB(190,210,235), canFly=true },

	-- ===== TANK VARIANTS ===== tank-ified versions of smaller enemies.
	speedytank = { id="speedytank", name="Speedy Tank", healthMult=3.5, speedMult=1.5,  damage=30, pointsMult=3.0, isSpecial=true, minRound=17, spawnWeight=10, tint=Color3.fromRGB(160,140,40) },
	leapertank = { id="leapertank", name="Leaper Tank", healthMult=6,   speedMult=1.05, damage=40, pointsMult=3.5, isSpecial=true, minRound=18, spawnWeight=8,  tint=Color3.fromRGB(100,50,120), canLeap=true },
	leadtank   = { id="leadtank",   name="Lead Tank",   healthMult=9,   speedMult=0.45, damage=65, pointsMult=4.5, isSpecial=true, minRound=22, spawnWeight=6,  tint=Color3.fromRGB(70,75,85) },

	-- ===== BOSSES (spawnWeight 0 — only spawned by BossWaves) =====
	boss        = { id="boss",        name="Boss",        healthMult=100, speedMult=0.7,  damage=75, pointsMult=10, isSpecial=true, minRound=10, spawnWeight=0, tint=Color3.fromRGB(40,10,50) },
	lumberjack  = { id="lumberjack",  name="Lumberjack",  healthMult=140, speedMult=0.95, damage=80, pointsMult=12, isSpecial=true, minRound=20, spawnWeight=0, tint=Color3.fromRGB(120,70,40) },
	necromancer = { id="necromancer", name="Necromancer", healthMult=200, speedMult=0.7,  damage=60, pointsMult=18, isSpecial=true, minRound=30, spawnWeight=0, tint=Color3.fromRGB(70,20,90), summons=true },
}

-- ===== BOSS SCHEDULE ===== (wave -> boss id). Wave 25 intentionally has none.
ZombieConfig.BossWaves = {
	[10] = "boss",       -- mid-run boss (standard modes end at wave 15)
	[15] = "lumberjack", -- FINAL boss on the last wave of every standard mode
	[20] = "necromancer",-- (Endless depth beyond 15)
	[30] = "boss",
}

return ZombieConfig
