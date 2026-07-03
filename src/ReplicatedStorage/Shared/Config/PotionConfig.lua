--!strict
-- PotionConfig.lua — TIERED potions: 2 types (damage / regen) × 7 rarities = 14 potions. Drunk IN-RUN
-- from the inventory; the buff is TIMED (higher rarity = stronger AND longer). One ACTIVE buff per TYPE —
-- when it expires you can drink another (any tier). Ids are "<type>_<rarity>", e.g. "damage_epic".
-- Elites drop them with wave-weighted rarity odds (deeper waves favor higher tiers).
--
-- The LOBBY has a hand-synced copy of the display data in LobbyServer's POTION_TIERS — keep them matched.
-- >>> PLACEHOLDER BALANCE — tune Tiers / DropWeights in your balancing pass. <<<

local PotionConfig = {}

PotionConfig.RarityOrder = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "divine" }
local RARITY_NAME = {
	common = "Common", uncommon = "Uncommon", rare = "Rare", epic = "Epic",
	legendary = "Legendary", mythic = "Mythic", divine = "Divine",
}

PotionConfig.Types = {
	damage = { label = "Damage", hud = "DMG" },
	regen  = { label = "Regen",  hud = "REGEN" },
}

-- Per rarity: buff size per type (fraction) + how long the buff runs (seconds).
PotionConfig.Tiers = {
	common    = { damage = 0.10, regen = 0.25, duration = 30 },
	uncommon  = { damage = 0.15, regen = 0.40, duration = 40 },
	rare      = { damage = 0.20, regen = 0.60, duration = 55 },
	epic      = { damage = 0.30, regen = 0.85, duration = 75 },
	legendary = { damage = 0.40, regen = 1.20, duration = 100 },
	mythic    = { damage = 0.55, regen = 1.75, duration = 130 },
	divine    = { damage = 0.75, regen = 2.50, duration = 180 },
}

-- Elite drop RARITY roll: weight(tier) = base × growth^((tier-1) × stage), stage rises with the wave —
-- the same shifting-odds shape the case drops use.
PotionConfig.DropWeightsBase = { 50, 25, 12, 7, 4, 1.5, 0.5 }
PotionConfig.DropWeightGrowth = 1.35
PotionConfig.DropStageEvery = 10 -- stage = floor(wave / this)

-- "damage_epic" -> "damage", "epic" (nil, nil if not a valid potion id).
function PotionConfig.Parse(id: string): (string?, string?)
	local t, r = string.match(id, "^(%a+)_(%a+)$")
	if t and r and PotionConfig.Types[t] and PotionConfig.Tiers[r] then
		return t, r
	end
	return nil, nil
end

-- Full stats for an id: { type, rarity, pct, duration } (nil for a bad id).
function PotionConfig.Stats(id: string)
	local t, r = PotionConfig.Parse(id)
	if not t or not r then
		return nil
	end
	local tier = PotionConfig.Tiers[r]
	return { type = t, rarity = r, pct = tier[t], duration = tier.duration }
end

function PotionConfig.DisplayName(id: string): string
	local t, r = PotionConfig.Parse(id)
	if not t or not r then
		return id
	end
	return ("%s %s Potion"):format(RARITY_NAME[r], PotionConfig.Types[t].label)
end

-- The effect line shown on the potion card: "+30% damage for 75s".
function PotionConfig.Desc(id: string): string
	local s = PotionConfig.Stats(id)
	if not s then
		return ""
	end
	local what = (s.type == "damage") and "damage" or "health regen"
	return ("+%d%% %s for %ds"):format(math.floor(s.pct * 100 + 0.5), what, s.duration)
end

-- Every potion id, rarity-major then type (stable order for catalogs).
function PotionConfig.AllIds(): { string }
	local out = {}
	for _, r in PotionConfig.RarityOrder do
		for t in PotionConfig.Types do
			table.insert(out, t .. "_" .. r)
		end
	end
	return out
end

-- Roll an elite's drop: random type, wave-weighted rarity.
function PotionConfig.RollDropId(wave: number): string
	local types = {}
	for t in PotionConfig.Types do
		table.insert(types, t)
	end
	local t = types[math.random(1, #types)]
	local stage = math.max(0, math.floor((wave or 1) / PotionConfig.DropStageEvery))
	local weights, total = {}, 0
	for i, base in PotionConfig.DropWeightsBase do
		local w = base * (PotionConfig.DropWeightGrowth ^ ((i - 1) * stage))
		weights[i] = w
		total += w
	end
	local roll = math.random() * total
	local acc = 0
	for i, w in weights do
		acc += w
		if roll <= acc then
			return t .. "_" .. PotionConfig.RarityOrder[i]
		end
	end
	return t .. "_common"
end

return PotionConfig
