--!strict
-- PerkConfig.lua — CoD-Zombies-style perks, bought at machines with points.
-- nil-able effect fields mean "this perk doesn't touch that stat".

export type Perk = {
	id: string, name: string, cost: number, description: string,
	healthBonus: number?,   -- flat max-health add (Juggernog)
	reloadMult: number?,    -- × reload time   (Speed Cola, <1 faster)
	fireRateMult: number?,  -- × fire rate      (Double Tap, >1 faster)
	reviveMult: number?,    -- × revive time    (Quick Revive)
	moveSpeedMult: number?, -- × move speed      (Stamin-Up)
}

-- ===== PERK TABLE =====
local PerkConfig: { [string]: any } = {
	jug       = { id="jug",       name="Juggernog",    cost=2500, description="+150 max health",  healthBonus=150 },
	speed     = { id="speed",     name="Speed Cola",   cost=3000, description="Reload 50% faster", reloadMult=0.5 },
	doubletap = { id="doubletap", name="Double Tap",   cost=2000, description="Fire 33% faster",   fireRateMult=1.33 },
	revive    = { id="revive",    name="Quick Revive", cost=1500, description="Revive faster",     reviveMult=0.5 },
	stamin    = { id="stamin",    name="Stamin-Up",    cost=2000, description="Move 15% faster",   moveSpeedMult=1.15 },
}

-- ===== RULES =====
PerkConfig.LoseOnDown = true   -- classic = true; friendlier = false
PerkConfig.MaxPerks   = 4      -- CoD-classic perk slot cap (set high to disable)

return PerkConfig
