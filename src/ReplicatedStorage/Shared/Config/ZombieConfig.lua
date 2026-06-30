--!strict
-- ZombieConfig.lua — archetypes. "isSpecial" = announce + unique VFX on spawn.
-- Enemies in the game: default, speedy, lead, tank, boss. Add an enemy = add a table entry (no logic edits).

export type ZombieType = {
	id: string, name: string,
	healthMult: number,  -- × the round's base health
	speedMult: number,   -- × the round's base speed
	damage: number,      -- per hit to a player
	pointsMult: number,  -- × base kill points
	isSpecial: boolean,
	minRound: number,
	spawnWeight: number, -- relative; 0 = never random (boss)
	tint: Color3,
	canLeap: boolean?,   -- behavior flag: periodically pounces in an arc toward the player (Leaper)
}

-- ===== ZOMBIE TABLE =====
-- The `id` must match your model's name under Assets > Zombies > <id> (else the default model is used).
-- The only enemies in the game: default, speedy, lead, tank, boss.
local ZombieConfig: { [string]: any } = {
	-- Default: the basic grunt. Uses your Assets > Zombies > default model.
	default = { id="default", name="Zombie", healthMult=1,    speedMult=1,    damage=20, pointsMult=1,   isSpecial=false, minRound=1,  spawnWeight=100, tint=Color3.fromRGB(90,110,80) },
	-- Speedy: fragile but FAST — rushes you, low HP, low damage. Forces you to keep moving.
	speedy  = { id="speedy",  name="Speedy", healthMult=0.55, speedMult=2.1,  damage=12, pointsMult=1.4, isSpecial=false, minRound=3,  spawnWeight=45,  tint=Color3.fromRGB(220,200,70) },
	-- Lead: a heavy mid-tier bullet-sponge — slowish, tanky, hits hard. The "lead-bellied" grunt.
	lead    = { id="lead",    name="Lead",   healthMult=2.6,  speedMult=0.85, damage=35, pointsMult=1.9, isSpecial=false, minRound=5,  spawnWeight=22,  tint=Color3.fromRGB(120,125,135) },
	-- Leaper: medium HP, springy — periodically POUNCES in an arc to close a big gap, so cover/distance
	-- doesn't keep you safe. `canLeap` is read by ZombieService. (Model this guy!)
	leaper  = { id="leaper",  name="Leaper", healthMult=0.8,  speedMult=1.15, damage=18, pointsMult=1.7, isSpecial=false, minRound=4,  spawnWeight=30,  tint=Color3.fromRGB(150,90,170), canLeap=true },
	-- Tank: rare, huge HP, slow, devastating melee. A mini-boss that makes you reposition.
	tank    = { id="tank",    name="Tank",   healthMult=7,    speedMult=0.5,  damage=55, pointsMult=3.5, isSpecial=true,  minRound=8,  spawnWeight=8,   tint=Color3.fromRGB(60,70,60) },
	-- Boss: spawned EXACTLY ONCE every BossInterval waves (never random — spawnWeight 0). Enormous HP,
	-- hits like a truck, big payout, gets a health bar + entrance.
	boss    = { id="boss",    name="Boss",   healthMult=25,   speedMult=0.7,  damage=75, pointsMult=10,  isSpecial=true,  minRound=10, spawnWeight=0,   tint=Color3.fromRGB(40,10,50) },
}

-- ===== BOSS RULES =====
ZombieConfig.BossInterval = 10   -- one boss every N waves (10, 20, 30, ...)
ZombieConfig.BossId       = "boss"

return ZombieConfig
