--!strict
-- GunLevelConfig.lua — PERSISTENT gun levels (the Clash-Royale system). Guns level up in the LOBBY by
-- collecting copies from cases and paying Coins; the level is saved on the profile (data.gunLevels) and
-- carried into every run. This file is the GAME place's view: how a level changes combat stats.
--
-- ===== HOW TO CUSTOMIZE (per level, per gun) =====
-- Every gun has its OWN 10-entry damage table below (index = level; level 1 = base stats). Tune each
-- gun's curve independently; a gun without its own table uses Default. The copy thresholds / Coin costs /
-- case payout matrix live in the LOBBY (LobbyServer's GUNLEVELS table) — keep MaxLevel in sync BY HAND.
--
-- >>> PLACEHOLDER BALANCE — tune the curves in your balancing pass. <<<
-- FUTURE: unique per-gun ABILITIES unlock at milestone levels (e.g. raygun splash growth, minigun faster
-- spin-up). When that lands, add an `Abilities[weaponId][level]` table here and apply it in CombatService —
-- the level plumbing already carries everything needed.

local GunLevelConfig = {}

GunLevelConfig.MaxLevel = 10

-- Damage multiplier vs base damage AT each level: LINEAR +10% of BASE per level (Lv10 = 1.9x).
-- Every gun has its own copy so you can retune any single gun later.
GunLevelConfig.Default = {
	[1] = 1.00, [2] = 1.10, [3] = 1.20, [4] = 1.30, [5] = 1.40,
	[6] = 1.50, [7] = 1.60, [8] = 1.70, [9] = 1.80, [10] = 1.90,
}

GunLevelConfig.Weapons = {
	pistol = {
		[1] = 1.00, [2] = 1.10, [3] = 1.20, [4] = 1.30, [5] = 1.40,
		[6] = 1.50, [7] = 1.60, [8] = 1.70, [9] = 1.80, [10] = 1.90,
	},
	shotgun = {
		[1] = 1.00, [2] = 1.10, [3] = 1.20, [4] = 1.30, [5] = 1.40,
		[6] = 1.50, [7] = 1.60, [8] = 1.70, [9] = 1.80, [10] = 1.90,
	},
	ak47 = {
		[1] = 1.00, [2] = 1.10, [3] = 1.20, [4] = 1.30, [5] = 1.40,
		[6] = 1.50, [7] = 1.60, [8] = 1.70, [9] = 1.80, [10] = 1.90,
	},
	minigun = {
		[1] = 1.00, [2] = 1.10, [3] = 1.20, [4] = 1.30, [5] = 1.40,
		[6] = 1.50, [7] = 1.60, [8] = 1.70, [9] = 1.80, [10] = 1.90,
	},
	raygun = {
		[1] = 1.00, [2] = 1.10, [3] = 1.20, [4] = 1.30, [5] = 1.40,
		[6] = 1.50, [7] = 1.60, [8] = 1.70, [9] = 1.80, [10] = 1.90,
	},
}

-- The damage multiplier for a gun at a level (per-gun table first, Default as the fallback).
function GunLevelConfig.DamageMult(weaponId: string, level: number?): number
	-- CHANGED: gun upgrading was REMOVED — every gun fires at its base stats regardless of any level
	-- still stored in old profiles. The curves above are kept only in case the feature returns.
	return 1
end

-- The weapon's combat stats at a persistent level. Same shape the old in-run upgrade system returned,
-- so CombatService/InputController read it identically: { damage, fireRate, range, pellets, knockback }.
-- Only damage scales today; the other fields pass through so future ability levels can bend them.
function GunLevelConfig.EffectiveStats(weapon: any, level: number?)
	return {
		damage = weapon.damage * GunLevelConfig.DamageMult(weapon.id, level),
		fireRate = weapon.fireRate,
		range = weapon.range,
		pellets = weapon.pellets or 1,
		knockback = weapon.knockback or 0,
	}
end

return GunLevelConfig
