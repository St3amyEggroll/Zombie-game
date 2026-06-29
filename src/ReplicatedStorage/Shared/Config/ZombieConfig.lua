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
local ZombieConfig: { [string]: any } = {
	walker = { id="walker", name="Walker", healthMult=1,   speedMult=1,   damage=20, pointsMult=1,   isSpecial=false, minRound=1,  spawnWeight=100, tint=Color3.fromRGB(90,110,80) },
	runner = { id="runner", name="Runner", healthMult=0.7, speedMult=1.8, damage=15, pointsMult=1.2, isSpecial=false, minRound=4,  spawnWeight=40,  tint=Color3.fromRGB(140,120,60) },
	brute  = { id="brute",  name="Brute",  healthMult=4,   speedMult=0.6, damage=45, pointsMult=2,   isSpecial=true,  minRound=7,  spawnWeight=12,  tint=Color3.fromRGB(120,40,40) },
	-- elite "mutated" variant — rare + dangerous (rarity-tier callback)
	mutant = { id="mutant", name="Mutant", healthMult=6,   speedMult=1.2, damage=50, pointsMult=4,   isSpecial=true,  minRound=10, spawnWeight=5,   tint=Color3.fromRGB(150,60,200) },
	-- boss: spawned by MatchService on interval, never random
	abomination = { id="abomination", name="Abomination", healthMult=30, speedMult=0.8, damage=80, pointsMult=10, isSpecial=true, minRound=10, spawnWeight=0, tint=Color3.fromRGB(20,20,20) },
}

-- ===== BOSS RULES =====
ZombieConfig.BossInterval = 10   -- a boss every N rounds
ZombieConfig.BossId       = "abomination"

return ZombieConfig
