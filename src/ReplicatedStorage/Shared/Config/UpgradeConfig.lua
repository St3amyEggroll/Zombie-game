--!strict
-- UpgradeConfig.lua — the IN-RUN gun upgrade table. Each gun has 5 upgrade levels bought with in-run
-- cash (the UPGRADE button / B key upgrades the gun you're HOLDING). Upgrades last ONE run only — they
-- are never saved.
--
-- ===== HOW TO CUSTOMIZE (edit the tables below, nothing else) =====
-- Each weapon gets a list of 5 levels. Each level can set any of:
--   price        = cash cost to buy this level
--   damageMult   = multiplies damage (1.25 = +25%). COMPOUNDS with earlier levels.
--   fireRateAdd  = adds rounds/second. (To think in "seconds faster per shot": a gun firing at R shots/s
--                  shoots every 1/R seconds — e.g. shotgun at 1.2/s = 0.83s; +0.2 fireRateAdd ≈ 0.12s faster.)
--   rangeAdd     = adds studs of reach
--   knockbackAdd = adds knockback (studs/sec shove on non-lethal hits)
--   pelletsAdd   = adds pellets (shotgun-style guns)
-- Omit a field = no change at that level. A weapon without its own entry uses Default.

local UpgradeConfig = {}

UpgradeConfig.MaxLevel = 5

export type UpgradeLevel = {
	price: number,
	damageMult: number?,
	fireRateAdd: number?,
	rangeAdd: number?,
	knockbackAdd: number?,
	pelletsAdd: number?,
}

UpgradeConfig.Default = {
	{ price = 1000,  damageMult = 1.20 },
	{ price = 2500,  damageMult = 1.20 },
	{ price = 5000,  damageMult = 1.25, fireRateAdd = 0.5 },
	{ price = 10000, damageMult = 1.25 },
	{ price = 20000, damageMult = 1.30, rangeAdd = 10 },
} :: { UpgradeLevel }

UpgradeConfig.Weapons = {
	pistol = {
		{ price = 1000,  damageMult = 1.25 },
		{ price = 2500,  damageMult = 1.20, fireRateAdd = 0.5 },
		{ price = 5000,  damageMult = 1.25 },
		{ price = 10000, damageMult = 1.25, fireRateAdd = 0.5 },
		{ price = 20000, damageMult = 1.35 },
	},
	shotgun = {
		{ price = 1000,  damageMult = 1.25, fireRateAdd = 0.2 },
		{ price = 2500,  damageMult = 1.20, pelletsAdd = 1 },
		{ price = 5000,  damageMult = 1.25, fireRateAdd = 0.2 },
		{ price = 10000, damageMult = 1.25, pelletsAdd = 1 },
		{ price = 20000, damageMult = 1.30, knockbackAdd = 12 },
	},
	ak47 = {
		{ price = 1000,  damageMult = 1.20 },
		{ price = 2500,  damageMult = 1.20, fireRateAdd = 1 },
		{ price = 5000,  damageMult = 1.25 },
		{ price = 10000, damageMult = 1.25, fireRateAdd = 1 },
		{ price = 20000, damageMult = 1.30, rangeAdd = 10 },
	},
	minigun = {
		{ price = 1000,  damageMult = 1.20, fireRateAdd = 1 },
		{ price = 2500,  damageMult = 1.20, fireRateAdd = 1 },
		{ price = 5000,  damageMult = 1.25, fireRateAdd = 2 },
		{ price = 10000, damageMult = 1.25 },
		{ price = 20000, damageMult = 1.30, knockbackAdd = 8 },
	},
	raygun = {
		{ price = 1000,  damageMult = 1.20 },
		{ price = 2500,  damageMult = 1.20, fireRateAdd = 0.5 },
		{ price = 5000,  damageMult = 1.25, rangeAdd = 10 },
		{ price = 10000, damageMult = 1.25, fireRateAdd = 0.5 },
		{ price = 20000, damageMult = 1.35, knockbackAdd = 15 },
	},
} :: { [string]: { UpgradeLevel } }

-- ===== READ HELPERS (logic — no need to touch) =====

function UpgradeConfig.Levels(weaponId: string): { UpgradeLevel }
	return UpgradeConfig.Weapons[weaponId] or UpgradeConfig.Default
end

-- Price to buy the NEXT level after `currentLevel` (nil if already maxed).
function UpgradeConfig.NextPrice(weaponId: string, currentLevel: number): number?
	local levels = UpgradeConfig.Levels(weaponId)
	local nextLevel = levels[currentLevel + 1]
	return nextLevel and nextLevel.price or nil
end

-- The weapon's stats with upgrade levels 1..level applied cumulatively.
-- Returns { damage, fireRate, range, pellets, knockback }.
function UpgradeConfig.EffectiveStats(weapon: any, level: number)
	local out = {
		damage = weapon.damage,
		fireRate = weapon.fireRate,
		range = weapon.range,
		pellets = weapon.pellets or 1,
		knockback = weapon.knockback or 0,
	}
	local levels = UpgradeConfig.Levels(weapon.id)
	for i = 1, math.min(level, UpgradeConfig.MaxLevel) do
		local lv = levels[i]
		if lv then
			out.damage = out.damage * (lv.damageMult or 1)
			out.fireRate = out.fireRate + (lv.fireRateAdd or 0)
			out.range = out.range + (lv.rangeAdd or 0)
			out.pellets = out.pellets + (lv.pelletsAdd or 0)
			out.knockback = out.knockback + (lv.knockbackAdd or 0)
		end
	end
	return out
end

return UpgradeConfig
