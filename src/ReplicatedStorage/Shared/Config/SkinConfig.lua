--!strict
-- SkinConfig.lua — gun SKINS (the crate economy pays these out; guns themselves are bought with Coins).
-- Every gun gets one skin per entry in SKIN_NAMES below. A skin's MODEL is optional: name a Model
-- "<gunId>_<skinId>" (e.g. "revolver_gold") in Assets / tag it "WeaponModel" and it's used everywhere
-- (hand, back-carry, UI viewports); until the model exists the base gun model stands in, so skins are
-- fully functional as data from day one.
--
-- Add a skin line = every gun gets it. Add a per-gun exclusive later by inserting into Build's output.

local WeaponConfig = require(script.Parent.WeaponConfig)

local SkinConfig: { [string]: any } = {}

-- ===== TUNABLES =====
SkinConfig.SkinNames = {
	worn  = { name = "Worn",  rarity = "common" },
	toxic = { name = "Toxic", rarity = "rare" },
	gold  = { name = "Gold",  rarity = "legendary" },
	void  = { name = "Void",  rarity = "divine" },
	-- NEW: TINTED skins — no model needed: the base gun is cloned and recolored with `tint` in the
	-- hand. KEEP rarities in sync with the lobby's SKIN_NAMES BY HAND.
	red   = { name = "Red",   rarity = "rare",      tint = Color3.fromRGB(198, 30, 30) },
	pink  = { name = "Pink",  rarity = "legendary", tint = Color3.fromRGB(255, 105, 190) },
	black = { name = "Black", rarity = "divine",    tint = Color3.fromRGB(28, 28, 32) },
}

-- Duplicate skin pulls convert to Coins, by SKIN rarity.
SkinConfig.DupCoins = { common = 25, uncommon = 60, rare = 150, epic = 400, legendary = 1000, mythic = 2500, divine = 6000 }

-- ===== GENERATED CATALOG =====
-- Skins[fullId] = { id, gun, skin, name, rarity }, fullId = "<gunId>_<skinId>"
SkinConfig.Skins = {}
SkinConfig.ByRarity = {} -- rarity -> sorted { fullId }

for gunId, w in WeaponConfig do
	for skinId, s in SkinConfig.SkinNames do
		local fullId = gunId .. "_" .. skinId
		SkinConfig.Skins[fullId] = { id = fullId, gun = gunId, skin = skinId, name = s.name .. " " .. w.name, rarity = s.rarity, tint = s.tint }
		local list = SkinConfig.ByRarity[s.rarity]
		if not list then
			list = {}
			SkinConfig.ByRarity[s.rarity] = list
		end
		table.insert(list, fullId)
	end
end
for _, list in SkinConfig.ByRarity do
	table.sort(list) -- deterministic order (table iteration isn't)
end

return SkinConfig
