--!strict
-- BuffConfig.lua — the in-run LEVEL-UP BUFF DRAFT. Per-run XP (from kills) fills a level bar; each level
-- pops 3 buff options that are ALWAYS the same rarity. The rarity is rolled by climbing the ladder
-- (Common..Divine): each climb is a set chance that only goes UP with your Luck. Higher rarity = a bigger
-- increment. Buffs ADD across picks (never multiply) and RESET every run.
--
-- Add a buff = add a row to Buffs. Add/retune a rarity = edit Rarities + UpgradeChance. Tune values freely.

local BuffConfig = {}

-- ===== RARITIES (low -> high) ===== value at tier r = base * r  (so Common=1x ... Mythic=6x, Divine=7x)
BuffConfig.Rarities = {
	{ id = "common",    name = "Common",    color = Color3.fromRGB(185, 185, 185) },
	{ id = "uncommon",  name = "Uncommon",  color = Color3.fromRGB(95, 205, 95) },
	{ id = "rare",      name = "Rare",      color = Color3.fromRGB(80, 145, 255) },
	{ id = "epic",      name = "Epic",      color = Color3.fromRGB(175, 95, 235) },
	{ id = "legendary", name = "Legendary", color = Color3.fromRGB(255, 170, 60) },
	{ id = "mythic",    name = "Mythic",    color = Color3.fromRGB(255, 80, 120) },
	{ id = "divine",    name = "Divine",    color = Color3.fromRGB(120, 255, 235) },
}

-- Chance to climb from tier i -> i+1 BEFORE luck. (#entries = #Rarities - 1.)
BuffConfig.UpgradeChance   = { 0.60, 0.50, 0.40, 0.30, 0.20, 0.10 }
BuffConfig.MaxUpgradeChance = 0.95   -- luck can never push a climb roll above this

-- Each buff's COMMON (tier 1) increment. Additive fractions: 0.03 = +3%. A roll at tier r grants base*r.
-- (Crit Chance base 0.03 -> Common +3% ... Mythic +18% ... Divine +21%.)
BuffConfig.Buffs = {
	{ id = "damage",      name = "Damage",       stat = "damage",      base = 0.05 },
	-- (Attack Speed removed — fire rate is CONSTANT per weapon and nothing is allowed to change it.)
	{ id = "walkspeed",   name = "Move Speed",   stat = "walkspeed",   base = 0.03 },
	{ id = "range",       name = "Attack Range", stat = "range",       base = 0.05 },
	{ id = "critchance",  name = "Crit Chance",  stat = "critchance",  base = 0.03 },
	{ id = "critdamage",  name = "Crit Damage",  stat = "critdamage",  base = 0.10 },
	{ id = "luck",        name = "Luck",         stat = "luck",        base = 0.04 },
}

BuffConfig.OptionsPerDraft = 3
BuffConfig.AutoPickSeconds = 15   -- game never pauses; ignore the draft this long and option 1 is auto-taken

-- ===== PER-RUN XP (resets each run) ===== kills fill the bar; each level = one draft.
BuffConfig.XPPerKill        = 10
BuffConfig.XPPerSpecialKill = 25
BuffConfig.LevelBaseXP      = 100   -- XP for level 1 -> 2
BuffConfig.LevelGrowth      = 1.22  -- XP needed ×= this each level

function BuffConfig.XPForLevel(level: number): number
	return math.floor(BuffConfig.LevelBaseXP * BuffConfig.LevelGrowth ^ math.max(0, level - 1) + 0.5)
end

function BuffConfig.Magnitude(base: number, rarityIndex: number): number
	return base * rarityIndex
end

return BuffConfig
