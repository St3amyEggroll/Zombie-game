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

-- Damage multiplier vs base damage AT each level (level 1 = 1.00 = base).
GunLevelConfig.Default = {
	[1] = 1.00, [2] = 1.08, [3] = 1.17, [4] = 1.27, [5] = 1.38,
	[6] = 1.50, [7] = 1.63, [8] = 1.77, [9] = 1.93, [10] = 2.10,
}

GunLevelConfig.Weapons = {
	pistol = { -- the starter scales hardest so it stays usable deep
		[1] = 1.00, [2] = 1.10, [3] = 1.21, [4] = 1.33, [5] = 1.46,
		[6] = 1.61, [7] = 1.77, [8] = 1.95, [9] = 2.14, [10] = 2.36,
	},
	shotgun = {
		[1] = 1.00, [2] = 1.08, [3] = 1.17, [4] = 1.27, [5] = 1.38,
		[6] = 1.50, [7] = 1.63, [8] = 1.77, [9] = 1.93, [10] = 2.10,
	},
	ak47 = {
		[1] = 1.00, [2] = 1.08, [3] = 1.17, [4] = 1.27, [5] = 1.38,
		[6] = 1.50, [7] = 1.63, [8] = 1.77, [9] = 1.93, [10] = 2.10,
	},
	minigun = { -- fires so fast its per-level bump is gentler
		[1] = 1.00, [2] = 1.07, [3] = 1.15, [4] = 1.24, [5] = 1.34,
		[6] = 1.45, [7] = 1.57, [8] = 1.70, [9] = 1.84, [10] = 2.00,
	},
	raygun = {
		[1] = 1.00, [2] = 1.07, [3] = 1.15, [4] = 1.24, [5] = 1.34,
		[6] = 1.45, [7] = 1.57, [8] = 1.70, [9] = 1.84, [10] = 2.00,
	},
}

-- The damage multiplier for a gun at a level (per-gun table first, Default as the fallback).
function GunLevelConfig.DamageMult(weaponId: string, level: number?): number
	local lv = math.clamp(level or 1, 1, GunLevelConfig.MaxLevel)
	local curve = GunLevelConfig.Weapons[weaponId] or GunLevelConfig.Default
	return curve[lv] or GunLevelConfig.Default[lv] or 1
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
