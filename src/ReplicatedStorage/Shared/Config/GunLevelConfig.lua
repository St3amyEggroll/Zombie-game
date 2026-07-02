--!strict
-- GunLevelConfig.lua — PERSISTENT gun levels (the Clash-Royale system). Guns level up in the LOBBY by
-- collecting copies from cases and paying Coins; the level is saved on the profile (data.gunLevels) and
-- carried into every run. This file is the GAME place's view: how a level changes combat stats.
--
-- The copy thresholds / Coin costs / case payout matrix live in the LOBBY (LobbyServer's GUNLEVELS
-- table) — keep MaxLevel and DamageMult in sync with it BY HAND (the lobby can't require this file).
--
-- >>> PLACEHOLDER BALANCE — tune DamageMult in your balancing pass. <<<
-- FUTURE: unique per-gun ABILITIES unlock at milestone levels (e.g. raygun splash growth, minigun
-- faster spin-up). When that lands, add an `Abilities[weaponId][level]` table here and apply it in
-- CombatService — the level plumbing below already carries everything needed.

local GunLevelConfig = {}

GunLevelConfig.MaxLevel = 10

-- Damage multiplier vs the gun's base damage AT each level (index = level; level 1 = base stats).
-- ~+8-9% compounding per level → a maxed gun hits a little over 2x base.
GunLevelConfig.DamageMult = {
	[1] = 1.00,
	[2] = 1.08,
	[3] = 1.17,
	[4] = 1.27,
	[5] = 1.38,
	[6] = 1.50,
	[7] = 1.63,
	[8] = 1.77,
	[9] = 1.93,
	[10] = 2.10,
}

-- The weapon's combat stats at a persistent level. Same shape the old in-run upgrade system returned,
-- so CombatService/InputController read it identically: { damage, fireRate, range, pellets, knockback }.
-- Only damage scales today; the other fields pass through so future ability levels can bend them.
function GunLevelConfig.EffectiveStats(weapon: any, level: number?)
	local lv = math.clamp(level or 1, 1, GunLevelConfig.MaxLevel)
	return {
		damage = weapon.damage * (GunLevelConfig.DamageMult[lv] or 1),
		fireRate = weapon.fireRate,
		range = weapon.range,
		pellets = weapon.pellets or 1,
		knockback = weapon.knockback or 0,
	}
end

return GunLevelConfig
