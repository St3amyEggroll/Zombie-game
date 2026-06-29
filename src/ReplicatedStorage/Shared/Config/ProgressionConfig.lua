--!strict
-- ProgressionConfig.lua — meta-progression: account XP, leveling, unlock economy.
-- DESIGN (your call): KILL-WEIGHTED. Most XP comes from kills; round reached is a small bonus.
-- Curve helpers at the bottom are pure functions driven entirely by the tunables above them.

local ProgressionConfig = {}

-- ===== XP SOURCES (kill-weighted) =====
ProgressionConfig.XPPerKill        = 12   -- the main driver
ProgressionConfig.XPPerSpecialKill = 25   -- elites/bosses: added ON TOP of XPPerKill
ProgressionConfig.XPPerRound       = 8    -- small per-round-reached bonus
ProgressionConfig.XPPerRevive      = 20   -- light teamwork reward

-- ===== LEVEL CURVE ===== (gentle-moderate; pairs well with a young audience)
ProgressionConfig.BaseLevelXP = 120   -- XP cost of level 1 -> 2
ProgressionConfig.LevelGrowth = 1.18  -- per-level cost multiplier
ProgressionConfig.MaxLevel    = 100

-- ===== UNLOCK TOKENS =====
ProgressionConfig.TokensPerLevel = 1  -- unlock tokens granted on each level-up

-- ===== UNLOCK CATALOG ===== (token cost to permanently unlock for future runs)
-- Weapons are bought with cash in the shop (ShopConfig); meta token-unlocks come in a later phase.
ProgressionConfig.WeaponUnlocks = {}   -- (cash shop handles weapons now; meta unlocks come in a later phase)
ProgressionConfig.PerkUnlocks   = {}

-- ===== CURVE HELPERS (pure; tunables above drive them) =====

-- XP cost to advance FROM `level` TO level+1.
function ProgressionConfig.XPForLevel(level: number): number
	return math.floor(ProgressionConfig.BaseLevelXP * (ProgressionConfig.LevelGrowth ^ (level - 1)))
end

-- Given cumulative account XP, return (level, xpIntoCurrentLevel, xpNeededForNextLevel).
function ProgressionConfig.LevelForXP(totalXP: number): (number, number, number)
	local level = 1
	local remaining = math.max(0, totalXP)
	while level < ProgressionConfig.MaxLevel do
		local need = ProgressionConfig.XPForLevel(level)
		if remaining < need then
			return level, remaining, need
		end
		remaining -= need
		level += 1
	end
	return ProgressionConfig.MaxLevel, 0, 0  -- capped
end

-- XP earned for a finished match (kill-weighted formula).
function ProgressionConfig.MatchXP(kills: number, specialKills: number, roundReached: number, revives: number): number
	return kills * ProgressionConfig.XPPerKill
		+ specialKills * ProgressionConfig.XPPerSpecialKill
		+ roundReached * ProgressionConfig.XPPerRound
		+ revives * ProgressionConfig.XPPerRevive
end

return ProgressionConfig
