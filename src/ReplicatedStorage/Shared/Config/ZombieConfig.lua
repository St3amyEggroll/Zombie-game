--!strict
-- ZombieConfig.lua — archetypes. "isSpecial" = announce + unique VFX on spawn.
-- Bosses have spawnWeight 0 and are spawned on an interval by MatchService.

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
}

-- ===== ZOMBIE TABLE =====
-- The `id` must match your model's name under Assets > Zombies > <id> (else the default model is used).
local ZombieConfig: { [string]: any } = {
	walker = { id="walker", name="Walker", healthMult=1,   speedMult=1,   damage=20, pointsMult=1,   isSpecial=false, minRound=1,  spawnWeight=100, tint=Color3.fromRGB(90,110,80) },

	-- ===== NEW ENEMIES (owner-built models: speedy / lead / tank) =====
	-- Speedy: fragile but FAST — rushes you, low HP, low damage. Forces you to keep moving.
	speedy = { id="speedy", name="Speedy", healthMult=0.55, speedMult=2.1, damage=12, pointsMult=1.4, isSpecial=false, minRound=3,  spawnWeight=45, tint=Color3.fromRGB(220,200,70) },
	-- Lead: a heavy mid-tier bullet-sponge — slowish, tanky, hits hard. The "lead-bellied" grunt.
	lead   = { id="lead",   name="Lead",   healthMult=2.6,  speedMult=0.85, damage=35, pointsMult=1.9, isSpecial=false, minRound=5,  spawnWeight=22, tint=Color3.fromRGB(120,125,135) },
	-- Tank: rare, huge HP, slow, devastating melee. A mini-boss that makes you reposition.
	tank   = { id="tank",   name="Tank",   healthMult=7,    speedMult=0.5,  damage=55, pointsMult=3.5, isSpecial=true,  minRound=8,  spawnWeight=8,  tint=Color3.fromRGB(60,70,60) },

	-- elite "mutated" variant — rare + dangerous (rarity-tier callback)
	mutant = { id="mutant", name="Mutant", healthMult=6,   speedMult=1.2, damage=50, pointsMult=4,   isSpecial=true,  minRound=10, spawnWeight=5,   tint=Color3.fromRGB(150,60,200) },
	-- boss: spawned by MatchService on interval, never random
	abomination = { id="abomination", name="Abomination", healthMult=30, speedMult=0.8, damage=80, pointsMult=10, isSpecial=true, minRound=10, spawnWeight=0, tint=Color3.fromRGB(20,20,20) },
}

-- ===== BOSS RULES =====
ZombieConfig.BossInterval = 10   -- a boss every N rounds
ZombieConfig.BossId       = "abomination"

return ZombieConfig
