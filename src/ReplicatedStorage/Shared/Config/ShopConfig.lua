--!strict
-- ShopConfig.lua — the Zombie Rush shop: which weapons you can buy for cash, and the weapon-upgrade curve.
-- Buying/upgrading happens in a MENU (no in-map doors or wall-buys). Tune prices + the upgrade curve here.

local ShopConfig = {}

-- ===== BUYABLE WEAPONS ===== (weaponId -> cash price). The pistol is your free starter, so it's not listed.
-- Only weapons with a model belong here. Add more as you build their models.
ShopConfig.Weapons = {
	ak47    = 3000,
	minigun = 8000,
}

-- Display order in the menu.
ShopConfig.Order = { "ak47", "minigun" }

-- ===== UPGRADES ===== each owned weapon can be upgraded up to MaxUpgradeLevel times.
ShopConfig.MaxUpgradeLevel       = 5
ShopConfig.UpgradeDamagePerLevel = 0.25   -- +25% weapon damage per level (additive: ×(1 + level×this))
ShopConfig.UpgradeBaseCost       = 750    -- cost of the FIRST upgrade (level 0 -> 1)
ShopConfig.UpgradeCostGrowth     = 1.6    -- upgrade cost ×= this each level

-- ===== HELPERS (pure; driven by the tunables above) =====

-- Cost to upgrade FROM `level` to level+1.
function ShopConfig.UpgradeCost(level: number): number
	return math.floor(ShopConfig.UpgradeBaseCost * (ShopConfig.UpgradeCostGrowth ^ level))
end

-- Weapon-damage multiplier at a given upgrade level.
function ShopConfig.DamageMultFor(level: number): number
	return 1 + level * ShopConfig.UpgradeDamagePerLevel
end

return ShopConfig
