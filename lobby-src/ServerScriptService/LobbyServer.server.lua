-- LobbyServer (LOBBY PLACE ONLY) — walkable hub with PARTY PADS + the inventory.
--
-- PARTY FLOW (one party per LoadingZone pad):
--   1. Player A steps on an empty pad -> becomes the HOST and gets the setup menu (Map / Difficulty / Size).
--      While A is setting up, the pad is LOCKED — anyone else stepping on is told to wait.
--   2. A presses PLAY -> settings are FINALIZED. A's menu collapses to just party info + a LEAVE button,
--      and a billboard above the pad shows the settings + player count + countdown.
--   3. Others step on the pad to JOIN — but only if they've UNLOCKED that map + difficulty (otherwise they
--      are told what they're missing). Members see party info + LEAVE.
--   4. The party launches when FULL, or when the 30s countdown ends (with whoever joined). Everyone
--      teleports together into a fresh private game server.
--
-- INVENTORY: 2-slot gun loadout (equip any 2 owned guns), 7 rarity-tiered cases (Common..Divine) opened
-- with the CS:GO reel, potions display. Your loadout guns show ON your character (slot 1 back, slot 2 hip).
--
-- SHOP: a rotating case storefront (the Coin sink). Global stock reroll every 30 minutes (seeded from the
-- clock, identical on every server), 6 slots, per-player stock limits, one discounted "deal" slot. Walk
-- onto the ShopZone part to browse; BUY banks the case, BUY & OPEN spins the reel right there.
--
-- BUILD (you): a SpawnLocation + one or more Parts named "LoadingZone..." (each is one party pad; its size
-- is the trigger volume) + a Part named "ShopZone" in front of your shop stall (its size is the browse
-- area). Gun models must also be in THIS place (tag "WeaponModel" or an Assets folder).
-- Sync with `rojo serve lobby.project.json`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

-- ===== CONFIG (keep in sync with the game's GameConfig) =====
local GAME_PLACE_ID    = 140566663451993 -- the gameplay place (PLAY teleports here; the lobby is the START place)
local STORE_NAME       = "PlayerData_v2"
local DIFFS            = { "easy", "medium", "hard", "nightmare", "endless" } -- endless: beat Nightmare to unlock
local FINAL_DIFF       = "nightmare" -- beating THIS unlocks the next world (Endless is a bonus mode, not a gate)
local WORLDS           = { "forest", "islands" } -- islands unlocks after beating forest:nightmare (worldUnlocked)
local PARTY_WAIT       = 30   -- seconds an OPEN party waits before launching with whoever joined
local FULL_GRACE       = 5    -- once the party is FULL (incl. solo), the countdown drops to this — a short
                              -- window to hit LEAVE before launch (nobody teleports instantly)
local V_MARGIN         = 6
local TICK             = 0.25
local TELEPORT_RETRIES = 4

Players.CharacterAutoLoads = true

local rng = Random.new()

-- ===== BILLBOARD THEME (mirrors the client's gritty-apocalypse kit) =====
-- Paste the same Creator Store font ids as the client's FONT_IDS when you have them.
local BB_FONT_IDS = { Title = "", Body = "" } -- Black Ops One / Orbitron
local function bbFace(id, weight, fallbackEnum)
	if id and id ~= "" then
		local ok, face = pcall(function()
			return Font.new("rbxassetid://" .. id, weight)
		end)
		if ok and face then
			return face
		end
	end
	return Font.new(Font.fromEnum(fallbackEnum).Family, weight)
end
local BB_TITLE = bbFace(BB_FONT_IDS.Title, Enum.FontWeight.Regular, Enum.Font.Sarpanch)
local BB_BODY = bbFace(BB_FONT_IDS.Body, Enum.FontWeight.Bold, Enum.Font.Michroma)
local BB_PANEL = Color3.fromRGB(21, 24, 17)
local BB_TEXT = Color3.fromRGB(222, 227, 209)
local BB_GOLD = Color3.fromRGB(230, 180, 76)

-- ===== PLAYER-PLAYER COLLISION OFF ===== (same group setup as the game place)
local PhysicsService = game:GetService("PhysicsService")
local PLAYER_GROUP = "Players"
pcall(function()
	PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
	PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, PLAYER_GROUP, false)
end)
local function setCollisionGroup(character)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = PLAYER_GROUP
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = PLAYER_GROUP
		end
	end)
end

-- ===== INVENTORY CATALOG =====
-- The lobby is self-contained (it can't require the game's Shared config), so the catalog lives here and
-- is SENT to the client for display. Add a weapon = add a WEAPONS entry (+ case pool weights below).
local RARITY_ORDER = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "divine" }
local RARITY = {
	common    = { name = "Common",    color = { 185, 185, 185 } },
	uncommon  = { name = "Uncommon",  color = {  95, 205,  95 } },
	rare      = { name = "Rare",      color = {  80, 145, 255 } },
	epic      = { name = "Epic",      color = { 175,  95, 235 } },
	legendary = { name = "Legendary", color = { 255, 170,  60 } },
	mythic    = { name = "Mythic",    color = { 255,  80, 120 } },
	divine    = { name = "Divine",    color = { 120, 255, 235 } },
}

-- Stats mirror the game's WeaponConfig (kept in sync by hand) for the hover tooltips.
-- CHANGED: guns are BOUGHT with Coins (price below; pistol is the free starter). Crates pay SKINS.
local WEAPONS = {
	pistol    = { name = "M1911",        tier = 1, rarity = "common",    damage = 30,  fireRate = 5,   range = 200, price = 0, slot = "secondary" },
	revolver  = { name = "Revolver",     tier = 2, rarity = "uncommon",  damage = 70,  fireRate = 1.8, range = 220, price = 1500, slot = "secondary",
		ability = "PIERCE — rounds punch through up to 3 zombies in a line" },
	shotgun   = { name = "Pump Shotgun", tier = 2, rarity = "uncommon",  damage = 16,  fireRate = 1.2, range = 40, pellets = 6, price = 2500, slot = "primary" },
	ak47      = { name = "AK-47",        tier = 3, rarity = "rare",      damage = 40,  fireRate = 9,   range = 300, price = 6000, slot = "primary" },
	crossbow  = { name = "Crossbow",     tier = 3, rarity = "rare",      damage = 110, fireRate = 1.0, range = 260, price = 8000, slot = "primary",
		ability = "PIN — bolts nail zombies in place for 2s" },
	minigun   = { name = "Minigun",      tier = 4, rarity = "epic",      damage = 16,  fireRate = 18,  range = 300, price = 15000, slot = "primary" },
	freezeray = { name = "Freeze Ray",   tier = 4, rarity = "epic",      damage = 10,  fireRate = 10,  range = 180, price = 20000, slot = "primary",
		ability = "CRYO — chills 30%; chilled zombies SHATTER on death" },
	raygun    = { name = "Ray Gun",      tier = 5, rarity = "legendary", damage = 80,  fireRate = 4,   range = 250, price = 40000, slot = "primary" },
	m4        = { name = "M4 Carbine",         tier = 3, rarity = "rare",      damage = 34,  fireRate = 11,  range = 300, price = 7000,  slot = "primary" },
	tommygun  = { name = "Tommy Gun",          tier = 2, rarity = "uncommon",  damage = 18,  fireRate = 12,  range = 170, price = 3500,  slot = "primary" },
	sniper    = { name = "Bolt-Action Sniper", tier = 4, rarity = "epic",      damage = 150, fireRate = 0.9, range = 400, price = 12000, slot = "primary",
		ability = "PIERCE — one shot punches through a whole line" },
	flamethrower = { name = "Flamethrower",    tier = 4, rarity = "epic",      damage = 9,   fireRate = 12,  range = 38, pellets = 3, price = 18000, slot = "primary",
		ability = "INFERNO — sprays a short cone of fire" },
	rocket    = { name = "Rocket Launcher",    tier = 5, rarity = "legendary", damage = 20,  fireRate = 0.7, range = 300, price = 35000, slot = "primary",
		ability = "EXPLOSIVE — the blast damages everything nearby" },
	plasma    = { name = "Plasma Rifle",       tier = 5, rarity = "legendary", damage = 30,  fireRate = 6,   range = 280, price = 30000, slot = "primary",
		ability = "PLASMA — bolts splash on impact" },
	honeybadger = { name = "Honey Badger",     tier = 3, rarity = "rare",      damage = 30,  fireRate = 10,  range = 260, price = 6500,  slot = "primary" },
	p90       = { name = "P90",                tier = 3, rarity = "rare",      damage = 16,  fireRate = 13,  range = 180, price = 5000,  slot = "primary" },
}

-- ===== ACCOUNT-LEVEL GUN UNLOCKS =====
-- A gun can't be bought until your ACCOUNT LEVEL reaches its unlock level (Coins still pay for it — level
-- gates access, Coins are the price). Level comes from XP earned in runs, shared with the game place.
-- Tune freely: raising a number pushes that gun later. pistol = 0 (free starter, always available).
local WEAPON_UNLOCK = {
	pistol = 0, tommygun = 2, shotgun = 3, revolver = 4, p90 = 5, honeybadger = 6, ak47 = 7,
	m4 = 8, crossbow = 9, sniper = 12, minigun = 14, flamethrower = 16, freezeray = 18,
	plasma = 22, rocket = 25, raygun = 28,
}
for id, w in WEAPONS do
	w.unlock = WEAPON_UNLOCK[id] or 0 -- rides in the catalog sent to the client (drives the "next unlock" UI)
end

-- Account level from cumulative XP — mirrors the game place's ProgressionConfig curve (keep in sync).
local LEVEL_BASE_XP, LEVEL_GROWTH, LEVEL_MAX = 120, 1.18, 100
local function accountLevel(totalXP)
	local level, remaining = 1, math.max(0, tonumber(totalXP) or 0)
	while level < LEVEL_MAX do
		local need = math.floor(LEVEL_BASE_XP * (LEVEL_GROWTH ^ (level - 1)))
		if remaining < need then
			break
		end
		remaining -= need
		level += 1
	end
	return level
end

-- Each gun belongs to a fixed loadout slot: 1 = PRIMARY, 2 = SECONDARY (WEAPONS[id].slot).
local function slotFor(weaponId)
	return (WEAPONS[weaponId] and WEAPONS[weaponId].slot == "secondary") and 2 or 1
end

-- ===== SKINS ===== (what crates pay out — synced with the game's SkinConfig; models are optional:
-- name a Model "<gunId>_<skinId>" in Assets and it's used everywhere, else the base gun stands in)
local SKIN_NAMES = {
	worn  = { name = "Worn",  rarity = "common" },
	toxic = { name = "Toxic", rarity = "rare" },
	gold  = { name = "Gold",  rarity = "legendary" },
	void  = { name = "Void",  rarity = "divine" },
}
local SKINS = {}        -- [fullId "revolver_gold"] = { id, gun, skin, name, rarity }
local SKINS_BY_RARITY = {} -- rarity -> sorted { fullId }
for gunId, w in WEAPONS do
	for skinId, s in SKIN_NAMES do
		local fullId = gunId .. "_" .. skinId
		SKINS[fullId] = { id = fullId, gun = gunId, skin = skinId, name = s.name .. " " .. w.name, rarity = s.rarity }
		SKINS_BY_RARITY[s.rarity] = SKINS_BY_RARITY[s.rarity] or {}
		table.insert(SKINS_BY_RARITY[s.rarity], fullId)
	end
end
for _, list in SKINS_BY_RARITY do
	table.sort(list)
end
local SKIN_DUP_COINS = { common = 25, uncommon = 60, rare = 150, epic = 400, legendary = 1000, mythic = 2500, divine = 6000 }

-- 7 rarity-tiered cases (wave rewards + starter grants + the shop). Higher case rarity = better guns +
-- bigger COPY payouts (see GUNLEVELS.CopyPayout). Pools are { weaponId = weight }.
-- PHOTOS: add image = "rbxassetid://..." to any CASES entry (and to WEAPONS/POTIONS entries) and the
-- inventory/shop UI shows the picture on cards + detail panes automatically.
-- CHANGED: crates roll a SKIN — a skin RARITY from these weights, then a uniform skin of that rarity.
local CASES = {
	common    = { skinWeights = { common = 70, rare = 24, legendary = 5,  divine = 1 } },
	uncommon  = { skinWeights = { common = 60, rare = 30, legendary = 8,  divine = 2 } },
	rare      = { skinWeights = { common = 45, rare = 38, legendary = 13, divine = 4 } },
	epic      = { skinWeights = { common = 30, rare = 42, legendary = 20, divine = 8 } },
	legendary = { skinWeights = { common = 18, rare = 40, legendary = 28, divine = 14 } },
	mythic    = { skinWeights = { common = 10, rare = 32, legendary = 36, divine = 22 } },
	divine    = { skinWeights = { common = 5,  rare = 22, legendary = 38, divine = 35 } },
}
for rarity, c in CASES do
	c.name = RARITY[rarity].name .. " Skin Crate"
end

-- ===== GUN LEVELS (the Clash-Royale copies system) =====
-- Cases pay out COPIES of the rolled gun. Stack enough copies + pay Coins to level the gun up (10 levels);
-- upgrading CONSUMES the copies. The LEVEL is what the game place reads for combat stats — keep MaxLevel
-- in sync with the game's GunLevelConfig (which owns the damage curve) BY HAND.
-- >>> PLACEHOLDER BALANCE — tune Thresholds / CoinCosts / CopyPayout / Overflow in your balancing pass. <<<
local GUNLEVELS = {
	MaxLevel = 10,
	-- Copies needed to go FROM level L to L+1, by GUN rarity (index 1 = Lv1→2 ... index 9 = Lv9→10).
	Thresholds = {
		common    = { 10, 20, 50, 100, 200, 350, 600, 1000, 1600 },
		uncommon  = { 6, 12, 30, 60, 120, 220, 400, 700, 1100 },
		rare      = { 4, 8, 20, 40, 80, 150, 280, 500, 800 },
		epic      = { 2, 5, 12, 25, 50, 100, 180, 320, 550 },
		legendary = { 1, 3, 8, 16, 32, 65, 120, 220, 400 },
		mythic    = { 1, 2, 5, 10, 20, 40, 80, 150, 280 },
		divine    = { 1, 2, 4, 8, 16, 32, 64, 120, 240 },
	},
	-- Coin cost of each level-up (index 1 = Lv1→2 ... index 9 = Lv9→10), same for every rarity.
	CoinCosts = { 100, 250, 600, 1200, 2500, 5000, 9000, 15000, 25000 },
	-- Copies a case pays out: [case rarity][gun rarity] — rarer guns come in smaller stacks.
	CopyPayout = {
		common    = { common = 20,  uncommon = 12,  rare = 6,   epic = 3,  legendary = 2,  mythic = 1,  divine = 1 },
		uncommon  = { common = 30,  uncommon = 18,  rare = 9,   epic = 5,  legendary = 3,  mythic = 1,  divine = 1 },
		rare      = { common = 45,  uncommon = 28,  rare = 14,  epic = 7,  legendary = 4,  mythic = 2,  divine = 1 },
		epic      = { common = 70,  uncommon = 42,  rare = 20,  epic = 11, legendary = 6,  mythic = 3,  divine = 2 },
		legendary = { common = 110, uncommon = 65,  rare = 32,  epic = 17, legendary = 9,  mythic = 4,  divine = 2 },
		mythic    = { common = 200, uncommon = 120, rare = 60,  epic = 30, legendary = 15, mythic = 7,  divine = 3 },
		divine    = { common = 340, uncommon = 200, rare = 100, epic = 50, legendary = 25, mythic = 12, divine = 6 },
	},
	-- Coins per copy once a gun is MAX level (by gun rarity) — overflow auto-converts.
	Overflow = { common = 2, uncommon = 3, rare = 5, epic = 8, legendary = 12, mythic = 20, divine = 30 },
	-- Display-only: damage gained per level as a fraction of BASE (linear; keep in sync with the game's
	-- GunLevelConfig curves — Lv N = 1 + DamagePerLevel × (N-1)).
	DamagePerLevel = 0.10,
}

-- Copies needed to go from `level` to level+1 for this gun (nil = already max).
local function thresholdFor(weaponId, level)
	local w = WEAPONS[weaponId]
	if not w or level >= GUNLEVELS.MaxLevel then
		return nil
	end
	local t = GUNLEVELS.Thresholds[w.rarity] or GUNLEVELS.Thresholds.common
	return t[level] or t[#t]
end


-- ===== SHOP (rotating case storefront — the Coin sink) =====
-- GLOBAL rotation: stock is rolled from a seed derived from the clock window, so every server on Earth
-- shows the same 6 slots and rerolls at the same moment. Stock counts are PER PLAYER (in their profile).
-- >>> PLACEHOLDER BALANCE — tune Prices / Stock / Weights in your balancing pass. <<<
local SHOP = {
	RestockSeconds = 1800, -- 30 minutes per rotation
	Slots = 6,
	-- Coin price per case rarity (placeholder: ~4x the dupe refund).
	Prices = { common = 100, uncommon = 160, rare = 240, epic = 360, legendary = 560, mythic = 880, divine = 1400 },
	-- Per-PLAYER purchasable stock per slot per rotation (commons plentiful, top rarities scarce).
	Stock = { common = 5, uncommon = 4, rare = 3, epic = 2, legendary = 2, mythic = 1, divine = 1 },
	-- Per-slot rarity weights. Tuned so across 6 slots a MYTHIC appears in ~1 of 20 rotations and a
	-- DIVINE in ~1 of 120.
	Weights = { common = 100, uncommon = 60, rare = 35, epic = 18, legendary = 8, mythic = 1.9, divine = 0.31 },
	DealMinPct = 10, -- one seeded "Deal" slot per rotation gets a discount in this range
	DealMaxPct = 25,
	-- Robux-ready: map a rarity to a developer product id later and the buy path can branch to Robux
	-- without a rework (ids ride along in every ShopSync slot).
	RobuxProducts = {},
}

local shopCache = nil -- { window, slots } for the current rotation

local function shopWindow()
	return math.floor(os.time() / SHOP.RestockSeconds)
end

-- The 6 slots for the current rotation — deterministic for a given window (same on all servers).
local function currentShop()
	local window = shopWindow()
	if shopCache and shopCache.window == window then
		return shopCache
	end
	local r = Random.new(window)
	local weightTotal = 0
	for _, rid in RARITY_ORDER do
		weightTotal += SHOP.Weights[rid] or 0
	end
	local dealIndex = r:NextInteger(1, SHOP.Slots)
	local dealPct = r:NextInteger(SHOP.DealMinPct, SHOP.DealMaxPct)
	local slots = {}
	for i = 1, SHOP.Slots do
		local roll = r:NextNumber(0, weightTotal)
		local acc, rarity = 0, RARITY_ORDER[1]
		for _, rid in RARITY_ORDER do
			acc += SHOP.Weights[rid] or 0
			if roll <= acc then
				rarity = rid
				break
			end
		end
		local slot = {
			caseId = rarity,
			price = SHOP.Prices[rarity] or 100,
			stock = SHOP.Stock[rarity] or 1,
			robuxProductId = SHOP.RobuxProducts[rarity],
		}
		if i == dealIndex then
			slot.basePrice = slot.price
			slot.dealPct = dealPct
			slot.price = math.max(1, math.floor(slot.price * (100 - dealPct) / 100 + 0.5))
		end
		slots[i] = slot
	end
	shopCache = { window = window, slots = slots }
	return shopCache
end

-- Display catalog the client renders from.
local CATALOG = {
	rarities = RARITY,
	rarityOrder = RARITY_ORDER,
	weapons = WEAPONS,
	skins = SKINS,
	cases = (function()
		local t = {}
		local allSkinIds = {}
		for id in SKINS do
			table.insert(allSkinIds, id)
		end
		table.sort(allSkinIds)
		for rarity, c in CASES do
			local total = 0
			for _, weight in c.skinWeights do
				total += weight
			end
			local odds = {}
			for _, sr in RARITY_ORDER do
				if c.skinWeights[sr] then
					table.insert(odds, { rarity = sr, pct = (c.skinWeights[sr] / total) * 100 })
				end
			end
			t[rarity] = { name = c.name, rarity = rarity, poolIds = allSkinIds, odds = odds, image = c.image }
		end
		return t
	end)(),
}

local function rollCase(caseId)
	local case = CASES[caseId]
	local total = 0
	for _, weight in case.skinWeights do
		total += weight
	end
	local r = rng:NextNumber(0, total)
	local acc, chosen = 0, nil
	for rarity, weight in case.skinWeights do
		acc += weight
		if r <= acc then
			chosen = rarity
			break
		end
	end
	local list = SKINS_BY_RARITY[chosen or "common"] or SKINS_BY_RARITY.common
	return list[rng:NextInteger(1, #list)]
end

-- ===== REMOTES =====
local remotes = Instance.new("Folder")
remotes.Name = "LobbyRemotes"
remotes.Parent = ReplicatedStorage
local function mk(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end
local StatsRemote   = mk("Stats")         -- S->C: money/best wave
local ZoneEnter     = mk("ZoneEnter")     -- S->C: ({mode="config"|"party"|"blocked", ...}) pad UI state
local ZoneLeave     = mk("ZoneLeave")     -- S->C: close the pad UI
local FinalizeParty = mk("FinalizeParty") -- C->S: {map, difficulty, size} host locks in the settings
local LeaveParty    = mk("LeaveParty")    -- C->S: leave the party (moves you off the pad)
local PartyStatus   = mk("PartyStatus")   -- S->C: {map, difficulty, size, count, seconds} live party state
-- Inventory
local InvRequest    = mk("InvRequest")    -- C->S: (please send my inventory)
local InvSync       = mk("InvSync")       -- S->C: full inventory snapshot + catalog
local EquipSlot     = mk("EquipSlot")     -- C->S: {slot=1|2, weaponId} put a gun in a loadout slot
local OpenCase      = mk("OpenCase")      -- C->S: {caseId} open a case (caseId = its rarity)
local CaseResult    = mk("CaseResult")    -- S->C: {caseId, wonId, duplicate, coins} the roll (drives the reel)
                                          --       or {failed=true} — ALWAYS replied so the client never sticks
-- Shop
local ShopSync      = mk("ShopSync")      -- S->C: {enter?, window, endsIn, coins, slots} storefront snapshot
local ShopClose     = mk("ShopClose")     -- S->C: you left the shop zone; close the panel
local ShopBuy       = mk("ShopBuy")       -- C->S: {slot=1..6, open=bool} buy (and optionally reel-open) a case
-- Guns & skins
local BuyGun    = mk("BuyGun")    -- C->S: {weaponId} buy a gun outright with Coins
local EquipSkin = mk("EquipSkin") -- C->S: {weaponId, skinId?} equip a skin (nil/false = back to base look)
-- Sound
local SetSoundSettings = mk("SetSoundSettings") -- C->S: ({master, music, sfx} 0..1) persist volume sliders
local SetShake      = mk("SetShake")      -- C->S: (bool) persist the camera-shake on/off preference (shared with the game place)

-- ===== PROFILE =====
local store = DataStoreService:GetDataStore(STORE_NAME)
local profileCache = {} -- userId -> profile

local function sanitizeOwned(v)
	local owned, seen = {}, {}
	if typeof(v) == "table" then
		for _, id in v do
			if WEAPONS[id] and not seen[id] then
				seen[id] = true
				table.insert(owned, id)
			end
		end
	end
	if not seen.pistol then
		table.insert(owned, 1, "pistol")
	end
	return owned
end

-- The up-to-2 guns carried into runs. Migration: selectedWeapon (single-gun era), then tierLoadout.
-- Loadout is fixed-slot: [1] = a PRIMARY gun, [2] = a SECONDARY gun (either may be empty). A gun is only
-- kept in the slot it belongs to; mismatches/unowned are dropped. Empty until nothing valid -> pistol (2).
local function sanitizeLoadout(v, legacySelected, owned)
	local ownedSet = {}
	for _, id in owned do
		ownedSet[id] = true
	end
	local out = {}
	if typeof(v) == "table" then
		for slot = 1, 2 do
			local id = v[slot]
			if typeof(id) == "string" and WEAPONS[id] and ownedSet[id] and slotFor(id) == slot then
				out[slot] = id
			end
		end
	end
	if not out[1] and not out[2] then
		local sel = (typeof(legacySelected) == "string" and WEAPONS[legacySelected] and ownedSet[legacySelected])
			and legacySelected or "pistol"
		out[slotFor(sel)] = sel
	end
	return out
end

local function sanitizeCases(v)
	local out = {}
	if typeof(v) == "table" then
		for id, n in v do
			if typeof(n) == "number" and n > 0 then
				if CASES[id] then
					out[id] = (out[id] or 0) + math.floor(n)
				elseif id == "standard" then
					out.common = (out.common or 0) + math.floor(n) -- legacy Standard Cases -> Common
				end
			end
		end
	else
		out.common = 3 -- first ever load -> starter cases
	end
	return out
end

-- CHANGED: potions were removed from the game. Old profile data is dropped on load (nothing reads it).
local function sanitizePotions(_v)
	return {}
end

-- Persistent gun levels ([weaponId] = 1..MaxLevel). Migration: every owned gun is at least level 1.
local function sanitizeGunLevels(v, owned)
	local out = {}
	if typeof(v) == "table" then
		for id, n in v do
			if WEAPONS[id] and typeof(n) == "number" then
				out[id] = math.clamp(math.floor(n), 1, GUNLEVELS.MaxLevel)
			end
		end
	end
	for _, id in owned do
		if not out[id] then
			out[id] = 1
		end
	end
	return out
end

-- Unspent gun copies ([weaponId] = count) — consumed by upgrades.
local function sanitizeGunCopies(v)
	local out = {}
	if typeof(v) == "table" then
		for id, n in v do
			if WEAPONS[id] and typeof(n) == "number" and n > 0 then
				out[id] = math.floor(n)
			end
		end
	end
	return out
end

-- Per-player shop state: which rotation window they last bought in + purchases per slot ("1".."6").
-- LOBBY-OWNED field — the game place's save merge never touches it.
local function sanitizeShop(v)
	local out = { window = 0, bought = {} }
	if typeof(v) == "table" then
		out.window = tonumber(v.window) or 0
		if typeof(v.bought) == "table" then
			for k, n in v.bought do
				local idx = tonumber(k)
				if idx and idx >= 1 and idx <= SHOP.Slots and typeof(n) == "number" and n > 0 then
					out.bought[tostring(math.floor(idx))] = math.floor(n)
				end
			end
		end
	end
	return out
end

-- Sound/volume settings ride in the SHARED `settings` table (the game place owns other keys in it, like
-- sfx/music toggles) — keep everything as-is and only normalize the .vol sliders the lobby edits.
local function sanitizeSettings(v)
	local out = (typeof(v) == "table") and v or {}
	local vol = (typeof(out.vol) == "table") and out.vol or {}
	out.vol = {
		master = math.clamp(tonumber(vol.master) or 1, 0, 1),
		music = math.clamp(tonumber(vol.music) or 0.6, 0, 1),
		sfx = math.clamp(tonumber(vol.sfx) or 1, 0, 1),
	}
	-- Camera-shake preference (shared with the game place). Default ON; only false when explicitly disabled.
	out.shake = (out.shake ~= false)
	return out
end

-- Skins: owned set + one equipped skin per gun (both validated against the SKINS catalog).
local function sanitizeSkins(v)
	local out = { owned = {}, equipped = {} }
	if typeof(v) == "table" then
		if typeof(v.owned) == "table" then
			for id, on in v.owned do
				if SKINS[id] and on then
					out.owned[id] = true
				end
			end
		end
		if typeof(v.equipped) == "table" then
			for gunId, skinId in v.equipped do
				local fullId = tostring(gunId) .. "_" .. tostring(skinId)
				if WEAPONS[gunId] and out.owned[fullId] then
					out.equipped[gunId] = skinId
				end
			end
		end
	end
	return out
end

local function readProfile(player)
	-- Retry with backoff: a transient DataStore error must NOT make a veteran look brand-new (persisting
	-- that fallback would wipe their profile).
	local ok, data = false, nil
	for attempt = 1, 4 do
		ok, data = pcall(function()
			return store:GetAsync("Player_" .. player.UserId)
		end)
		if ok then
			break
		end
		warn(("[LobbyServer] profile load failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(data)))
		task.wait(attempt)
		if not player.Parent then
			break
		end
	end
	local loadFailed = not ok
	data = (ok and typeof(data) == "table") and data or {}
	local owned = sanitizeOwned(data.ownedWeapons)
	return {
		lobbyMoney = data.lobbyMoney or 0,
		bestWave = data.bestWave or 0,
		xp = tonumber(data.xp) or 0, -- account XP (game-owned; read-only here, drives level-gated unlocks)
		completed = (typeof(data.completed) == "table") and data.completed or {},
		ownedWeapons = owned,
		loadout = sanitizeLoadout(data.loadout, data.selectedWeapon, owned),
		cases = sanitizeCases(data.cases),
		potions = sanitizePotions(data.potions),
		gunLevels = sanitizeGunLevels(data.gunLevels, owned),
		gunCopies = sanitizeGunCopies(data.gunCopies),
		shop = sanitizeShop(data.shop),
		skins = sanitizeSkins(data.skins),
		settings = sanitizeSettings(data.settings),
		noPersist = loadFailed, -- fallback profile: NEVER write it back
	}
end

-- Merge the lobby-owned fields back into the shared profile WITHOUT clobbering game-owned fields.
-- IMMEDIATE write — call this only at must-not-lose moments (leave, teleport, shutdown). Everything
-- else goes through markDirty(); a background loop batches those writes so a case-opening spree doesn't
-- hammer the same DataStore key (Roblox throttles same-key writes to ~1 per 6s).
local dirty = {} -- userId -> true (profile changed since the last write)
local PERSIST_FLUSH_SECONDS = 30

local function persist(player)
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		dirty[player.UserId] = nil
		return
	end
	local ok = pcall(function()
		store:UpdateAsync("Player_" .. player.UserId, function(old)
			old = (typeof(old) == "table") and old or {}
			old.ownedWeapons = prof.ownedWeapons
			old.loadout = prof.loadout
			old.selectedWeapon = prof.loadout[1] -- legacy field (older game builds read it)
			old.cases = prof.cases
			old.potions = prof.potions
			old.gunLevels = prof.gunLevels
			old.gunCopies = prof.gunCopies
			old.lobbyMoney = prof.lobbyMoney
			old.shop = prof.shop
			old.skins = prof.skins
			old.settings = prof.settings
			return old
		end)
	end)
	if ok then
		dirty[player.UserId] = nil
	end -- on failure the dirty flag stays; the flush loop retries
end

local function markDirty(player)
	if profileCache[player.UserId] then
		dirty[player.UserId] = true
	end
end

local function invSnapshot(prof)
	return {
		catalog = CATALOG,
		owned = prof.ownedWeapons,
		loadout = prof.loadout,
		cases = prof.cases,
		potions = prof.potions,
		gunLevels = prof.gunLevels,
		gunCopies = prof.gunCopies,
		skins = prof.skins,
		coins = prof.lobbyMoney,
	}
end

local function pushInv(player)
	local prof = profileCache[player.UserId]
	if prof then
		InvSync:FireClient(player, invSnapshot(prof))
	end
end

-- ===== ON-BODY GUNS (hub cosmetic) =====
-- Loadout guns ride on your character: SLOT 1 across the BACK, SLOT 2 on the HIP (a lone small gun sits
-- on the hip). Models: tag gun Models "WeaponModel" or put them in an "Assets" folder — named after the
-- weapon id or display name, same contract as the game place. Missing model = skipped quietly.
local CARRY_SMALL = { pistol = true, revolver = true } -- "small" guns prefer the hip when alone
-- Carried guns use the SAME orientation fix as the in-hand hold — the new Handle-only models need it, or
-- they sit wonky. CARRY_BASE matches the game place's HANDLE_ROT (points a gun forward + upright relative
-- to a body part; all body parts share the torso's axes). Each mount = a position offset (studs from the
-- torso) + a small pose tilt layered on top of CARRY_BASE.
--   pos = { right, up, back } in studs   ·   tilt below is pitch / yaw / roll in degrees
local CARRY_BASE = CFrame.Angles(math.rad(90), 0, math.rad(180))
local BACK_CF = CFrame.new(0, 0.4, 0.8)   * CARRY_BASE * CFrame.Angles(math.rad(55), 0, math.rad(-20)) -- slung high across the back
local HIP_CF  = CFrame.new(1.0, -0.9, 0.2) * CARRY_BASE * CFrame.Angles(math.rad(-15), 0, 0)            -- holstered low on the right hip

local carryTemplates = nil

local function sanitizeName(s)
	return (s:lower():gsub("[%s%-_]", ""))
end

-- Client-visible display clones for the UI's spinning 3D previews (same contract as the game place):
-- GunDisplay (weapons, named the weaponId) + CrateDisplay (Assets models named "<Rarity>Crate"/"Case").
local function displayFolder(name)
	local folder = ReplicatedStorage:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = ReplicatedStorage
	end
	return folder
end

local function publishOne(folder, id, inst)
	if folder:FindFirstChild(id) then
		return
	end
	local c = inst:Clone()
	CollectionService:RemoveTag(c, "WeaponModel")
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("BaseScript") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	c.Name = id
	c.Parent = folder
end

local function publishDisplayModels()
	local gunFolder = displayFolder("GunDisplay")
	for id, inst in carryTemplates do
		publishOne(gunFolder, id, inst)
	end
	local crateFolder = displayFolder("CrateDisplay")
	local wanted = {} -- "commoncrate" -> "common", "commoncase" -> "common", ...
	for rarity in CASES do
		wanted[rarity .. "crate"] = rarity
		wanted[rarity .. "case"] = rarity
	end
	for _, container in { ReplicatedStorage, ServerStorage, Workspace } do
		for _, child in container:GetChildren() do
			if child.Name:lower() == "assets" then
				for _, d in child:GetDescendants() do
					if d:IsA("Model") then
						local rarity = wanted[sanitizeName(d.Name)]
						if rarity then
							publishOne(crateFolder, rarity, d)
						end
					end
				end
			end
		end
	end
end

local function scanCarryTemplates()
	carryTemplates = {}
	local nameMap = {}
	for id, w in WEAPONS do
		nameMap[sanitizeName(id)] = id
		nameMap[sanitizeName(w.name)] = id
	end
	for fullId, s in SKINS do
		nameMap[sanitizeName(fullId)] = fullId -- "revolvergold" -> revolver_gold
		nameMap[sanitizeName(s.name)] = fullId -- "Gold Revolver" too
	end
	local function consider(inst)
		if inst:IsA("Model") then
			local id = nameMap[sanitizeName(inst.Name)]
			if id and not carryTemplates[id] then
				carryTemplates[id] = inst
			end
		end
	end
	for _, inst in CollectionService:GetTagged("WeaponModel") do
		consider(inst)
	end
	for _, container in { ReplicatedStorage, ServerStorage, Workspace } do
		for _, child in container:GetChildren() do
			if child.Name:lower() == "assets" then
				for _, d in child:GetDescendants() do
					consider(d)
				end
			end
		end
	end
	publishDisplayModels()
end

local function attachCarry(char, torso, weaponId, mountCF, name, prof)
	-- Equipped skin's model first, base gun as fallback.
	local template
	local skinId = prof and prof.skins and prof.skins.equipped and prof.skins.equipped[weaponId]
	if skinId then
		template = carryTemplates[weaponId .. "_" .. skinId]
	end
	template = template or carryTemplates[weaponId]
	if not template then
		return
	end
	local model = template:Clone()
	model.Name = name
	local handle = model:FindFirstChild("Handle") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not handle or not handle:IsA("BasePart") then
		model:Destroy()
		return
	end
	model.PrimaryPart = handle
	-- Move the WHOLE model into its mount pose FIRST (PivotTo shifts every part together), and only THEN
	-- create the welds. WeldConstraints capture their offsets when they activate — welding while the parts
	-- still sit at the template's position froze those faraway offsets in, which is why multi-part guns
	-- floated way off the player's back.
	model:PivotTo(torso.CFrame * mountCF)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Anchored = false
			if d ~= handle then
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = handle
				wc.Part1 = d
				wc.Parent = handle
			end
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = handle
	weld.Parent = handle
	model.Parent = char
end

local function refreshCarry(player)
	local char = player.Character
	local prof = profileCache[player.UserId]
	if not char or not prof then
		return
	end
	for _, name in { "CarriedWeapon1", "CarriedWeapon2" } do
		local old = char:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	if not carryTemplates then
		scanCarryTemplates()
	end
	local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
	if not torso then
		return
	end
	local g1, g2 = prof.loadout[1], prof.loadout[2]
	if g1 and not g2 then
		-- One gun: small guns sit on the hip, big ones on the back.
		attachCarry(char, torso, g1, CARRY_SMALL[g1] and HIP_CF or BACK_CF, "CarriedWeapon1", prof)
	else
		if g1 then
			attachCarry(char, torso, g1, BACK_CF, "CarriedWeapon1", prof)
		end
		if g2 then
			attachCarry(char, torso, g2, HIP_CF, "CarriedWeapon2", prof)
		end
	end
end

-- ===== PROGRESSION =====
local function indexOf(t, v)
	for i, x in t do
		if x == v then
			return i
		end
	end
	return nil
end

local function worldUnlocked(completed, world)
	local i = indexOf(WORLDS, world) or 1
	if i <= 1 then
		return true
	end
	return completed[WORLDS[i - 1] .. ":" .. FINAL_DIFF] == true
end

local function diffUnlocked(completed, world, difficulty)
	if not worldUnlocked(completed, world) then
		return false
	end
	local di = indexOf(DIFFS, difficulty)
	if not di then
		return false
	end
	if di <= 1 then
		return true
	end
	return completed[world .. ":" .. DIFFS[di - 1]] == true
end

local function unlockPayload(profile)
	local worlds = {}
	for _, w in WORLDS do
		local diffs = {}
		for _, d in DIFFS do
			diffs[d] = diffUnlocked(profile.completed, w, d)
		end
		worlds[w] = { unlocked = worldUnlocked(profile.completed, w), diffs = diffs }
	end
	return { worldOrder = WORLDS, order = DIFFS, worlds = worlds }
end

-- ===== RATE LIMITING (token buckets — the lobby's SecurityService-lite) =====
-- Every C->S remote passes through allow() so a spamming client burns its bucket, not the DataStore.
local RATE = { Inv = 2, Equip = 4, Case = 2, Party = 3, Shop = 4, Settings = 3, Buy = 3, Skin = 4 } -- refill/second (burst = 2s worth)
local buckets = {} -- userId -> { [action] = { tokens, last } }

local function allow(player, action)
	local rate = RATE[action] or 2
	local b = buckets[player.UserId]
	if not b then
		b = {}
		buckets[player.UserId] = b
	end
	local s = b[action]
	local now = os.clock()
	if not s then
		s = { tokens = rate * 2, last = now }
		b[action] = s
	end
	s.tokens = math.min(rate * 2, s.tokens + (now - s.last) * rate)
	s.last = now
	if s.tokens < 1 then
		return false
	end
	s.tokens -= 1
	return true
end

-- ===== INVENTORY HANDLERS =====
InvRequest.OnServerEvent:Connect(function(player)
	if allow(player, "Inv") then
		pushInv(player)
	end
end)

EquipSlot.OnServerEvent:Connect(function(player, req)
	if not allow(player, "Equip") or typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local weaponId = tostring(req.weaponId or "")
	-- UNEQUIP: a falsy weaponId clears the given slot (1 or 2).
	if req.weaponId == false or weaponId == "" then
		local slot = tonumber(req.slot)
		if slot == 1 or slot == 2 then
			prof.loadout[slot] = nil
			markDirty(player)
			pushInv(player)
			refreshCarry(player)
		end
		return
	end
	if not WEAPONS[weaponId] or not table.find(prof.ownedWeapons, weaponId) then
		return
	end
	-- The gun goes in ITS slot (primary/secondary), replacing whatever was there.
	prof.loadout[slotFor(weaponId)] = weaponId
	markDirty(player)
	pushInv(player)
	refreshCarry(player)
end)

-- Consume one case (caller has already verified the player HAS one) and roll a SKIN. First-ever pull
-- unlocks the skin; a duplicate converts straight to Coins by skin rarity. Shared with BUY & OPEN.
local function doOpenCase(player, prof, caseId)
	prof.cases[caseId] = (prof.cases[caseId] or 0) - 1
	if prof.cases[caseId] <= 0 then
		prof.cases[caseId] = nil
	end
	local wonId = rollCase(caseId)
	local skin = SKINS[wonId]
	local unlocked = not prof.skins.owned[wonId]
	local coins = 0
	if unlocked then
		prof.skins.owned[wonId] = true
	else
		coins = SKIN_DUP_COINS[skin.rarity] or 25
		prof.lobbyMoney += coins
	end
	return { caseId = caseId, wonId = wonId, coins = coins, unlocked = unlocked, maxed = not unlocked }
end

OpenCase.OnServerEvent:Connect(function(player, req)
	-- EVERY exit replies: the client sets `rolling` the moment it asks, and only a CaseResult (success
	-- OR {failed=true}) clears it — a silent drop here used to lock the whole inventory until rejoin.
	local function fail()
		CaseResult:FireClient(player, { failed = true })
	end
	if not allow(player, "Case") then
		return fail()
	end
	if typeof(req) ~= "table" then
		return fail()
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return fail()
	end
	local caseId = tostring(req.caseId or "")
	if not CASES[caseId] or (prof.cases[caseId] or 0) < 1 then
		return fail()
	end
	local result = doOpenCase(player, prof, caseId)
	markDirty(player)
	CaseResult:FireClient(player, result)
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- ===== SHOP HANDLERS =====
-- Reset the player's per-rotation purchases when a new window starts, and hand back the live rotation.
local function ensureShopState(prof)
	local shop = currentShop()
	if prof.shop.window ~= shop.window then
		prof.shop.window = shop.window
		prof.shop.bought = {}
	end
	return shop
end

local function shopSnapshot(prof, enter)
	local shop = ensureShopState(prof)
	local slots = {}
	for i, s in shop.slots do
		local boughtCount = prof.shop.bought[tostring(i)] or 0
		slots[i] = {
			caseId = s.caseId,
			name = CASES[s.caseId].name,
			price = s.price,
			basePrice = s.basePrice, -- only on the deal slot
			dealPct = s.dealPct,     -- only on the deal slot
			stock = s.stock,
			left = math.max(0, s.stock - boughtCount),
			robuxProductId = s.robuxProductId,
		}
	end
	return {
		enter = enter or nil,
		window = shop.window,
		endsIn = SHOP.RestockSeconds - (os.time() % SHOP.RestockSeconds),
		coins = prof.lobbyMoney,
		slots = slots,
	}
end

local function pushShop(player, enter)
	local prof = profileCache[player.UserId]
	if prof then
		ShopSync:FireClient(player, shopSnapshot(prof, enter))
	end
end

-- The SHOP corner button: client fires ShopSync (no payload) to ask for the storefront from anywhere.
ShopSync.OnServerEvent:Connect(function(player)
	if allow(player, "Shop") then
		pushShop(player, true) -- enter=true -> the client opens the panel
	end
end)

ShopBuy.OnServerEvent:Connect(function(player, req)
	if typeof(req) ~= "table" then
		return
	end
	local wantOpen = req.open == true
	if not allow(player, "Shop") then
		if wantOpen then
			CaseResult:FireClient(player, { failed = true }) -- unstick the reel lock, but no resync spam
		end
		return
	end
	local prof = profileCache[player.UserId]
	if not prof then
		return
	end
	local function fail()
		if wantOpen then
			CaseResult:FireClient(player, { failed = true }) -- unstick the client's reel lock
		end
		pushShop(player) -- resync whatever made the buy invalid (sold out / not enough Coins)
	end
	if prof.noPersist then
		return fail()
	end
	-- BUY ALL: sweep every slot's remaining stock cheapest-first until the coins run out.
	if req.all == true then
		local shop = ensureShopState(prof)
		local order = {}
		for i in shop.slots do
			table.insert(order, i)
		end
		table.sort(order, function(a, b)
			return shop.slots[a].price < shop.slots[b].price
		end)
		local total = 0
		for _, i in order do
			local slot = shop.slots[i]
			local key = tostring(i)
			local bought = prof.shop.bought[key] or 0
			local left = slot.stock - bought
			if left > 0 and slot.price > 0 then
				local n = math.min(left, math.floor(prof.lobbyMoney / slot.price))
				if n > 0 then
					prof.lobbyMoney -= slot.price * n
					prof.shop.bought[key] = bought + n
					prof.cases[slot.caseId] = (prof.cases[slot.caseId] or 0) + n
					total += n
				end
			end
		end
		if total < 1 then
			return fail()
		end
		markDirty(player)
		pushShop(player)
		pushInv(player)
		StatsRemote:FireClient(player, prof)
		return
	end

	local idx = tonumber(req.slot)
	if not idx or idx % 1 ~= 0 or idx < 1 or idx > SHOP.Slots then
		return fail()
	end
	local shop = ensureShopState(prof)
	local slot = shop.slots[idx]
	local key = tostring(idx)
	local boughtCount = prof.shop.bought[key] or 0
	local left = slot.stock - boughtCount
	if left < 1 then
		return fail()
	end
	if prof.lobbyMoney < slot.price then
		return fail()
	end
	-- Quantity: 1 (default), a small whole number, or "max" — clamped to remaining stock AND what the
	-- player can afford, so BUY 5 / BUY MAX gracefully buy "as many as possible". Opening forces 1.
	local wantQty
	if req.qty == "max" then
		wantQty = left
	else
		wantQty = tonumber(req.qty) or 1
		if wantQty % 1 ~= 0 or wantQty < 1 or wantQty > 100 then
			return fail() -- sanity-check CLIENT numbers only; "max" derives from server stock
		end
	end
	if wantOpen then
		wantQty = 1
	end
	local n = math.min(wantQty, left, math.floor(prof.lobbyMoney / slot.price))
	if n < 1 then
		return fail()
	end
	prof.lobbyMoney -= slot.price * n
	prof.shop.bought[key] = boughtCount + n
	prof.cases[slot.caseId] = (prof.cases[slot.caseId] or 0) + n
	local result = nil
	if wantOpen then
		result = doOpenCase(player, prof, slot.caseId)
	end
	markDirty(player)
	if result then
		CaseResult:FireClient(player, result)
	end
	pushShop(player)
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- ===== PARTY PADS =====
-- parties[zonePart] = { state="config"|"open", host, map, difficulty, size, members={}, deadline, billboard }
local parties = {}
local playerParty = {}  -- userId -> party
local inZonePart = {}   -- userId -> zone Part they're standing in
local lastMode = {}     -- userId -> last ZoneEnter signature sent (avoids respamming the client)

local zoneParts = {}
local shopZoneParts = {} -- Parts named "ShopZone..." — walk on one to browse the shop
local lastZoneScan = -math.huge
local function refreshZones()
	local list, shopList = {}, {}
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") then
			local n = d.Name:lower()
			if n:match("^loadingzone") then
				table.insert(list, d)
			elseif n:match("^shopzone") then
				table.insert(shopList, d)
			end
		end
	end
	zoneParts = list
	shopZoneParts = shopList
end

local function inPart(pos, part)
	local rel = part.CFrame:PointToObjectSpace(pos)
	local s = part.Size * 0.5
	return math.abs(rel.X) <= s.X and math.abs(rel.Z) <= s.Z and rel.Y >= -s.Y - 1 and rel.Y <= s.Y + V_MARGIN
end

local function cap(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

local function updateBillboard(zone, party)
	local bb = zone:FindFirstChild("PartyBillboard")
	if not party then
		if bb then
			bb:Destroy()
		end
		return
	end
	local label
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "PartyBillboard"
		bb.Size = UDim2.fromOffset(240, 60)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		bb.AlwaysOnTop = true
		bb.Parent = zone
		label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = BB_PANEL
		label.BackgroundTransparency = 0.12
		label.FontFace = BB_BODY
		label.TextSize = 15
		label.TextColor3 = BB_TEXT
		label.Parent = bb
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = label
	else
		label = bb:FindFirstChild("Label")
	end
	if not label then
		return
	end
	if party.state == "config" then
		label.Text = "Setting up..."
	else
		local secs = math.max(0, math.ceil(party.deadline - os.clock()))
		label.Text = ("%s · %s\n%d/%d · %ds"):format(cap(party.map), cap(party.difficulty), #party.members, party.size, secs)
	end
end

local function sendMode(player, sig, payload)
	if lastMode[player.UserId] == sig then
		return
	end
	lastMode[player.UserId] = sig
	ZoneEnter:FireClient(player, payload)
end

local function removeFromParty(player)
	local party = playerParty[player.UserId]
	if not party then
		return
	end
	playerParty[player.UserId] = nil
	for i = #party.members, 1, -1 do
		if party.members[i] == player then
			table.remove(party.members, i)
		end
	end
	-- A host abandoning setup — or the last member leaving — dissolves the party.
	if (party.state == "config" and party.host == player) or #party.members == 0 then
		parties[party.zone] = nil
		updateBillboard(party.zone, nil)
	else
		updateBillboard(party.zone, party)
	end
end

local function dissolveAndLaunch(party)
	parties[party.zone] = nil
	updateBillboard(party.zone, nil)
	local list = {}
	for _, pl in party.members do
		if pl.Parent then
			table.insert(list, pl)
			playerParty[pl.UserId] = nil
			ZoneLeave:FireClient(pl)
		end
	end
	if #list == 0 then
		return
	end
	task.spawn(function()
		-- Save everyone's inventory BEFORE they leave, so the game server loads their latest data.
		for _, pl in list do
			persist(pl)
		end
		local ok, code = pcall(function()
			return TeleportService:ReserveServer(GAME_PLACE_ID)
		end)
		local options = Instance.new("TeleportOptions")
		if ok and code then
			options.ReservedServerAccessCode = code
		end
		options:SetTeleportData({ startRun = true, map = party.map, difficulty = party.difficulty, partySize = #list })
		for attempt = 1, TELEPORT_RETRIES do
			local alive = {}
			for _, pl in list do
				if pl.Parent then
					table.insert(alive, pl)
				end
			end
			if #alive == 0 then
				return
			end
			local tok = pcall(function()
				TeleportService:TeleportAsync(GAME_PLACE_ID, alive, options)
			end)
			if tok then
				return
			end
			warn(("[LobbyServer] party teleport failed (attempt %d)"):format(attempt))
			task.wait(attempt)
		end
	end)
end

-- What this player should see for the pad they're standing on (runs every tick; only sends on change).
local function evaluateZone(player, zone)
	local prof = profileCache[player.UserId]
	local party = parties[zone]

	if party and playerParty[player.UserId] == party then
		if party.state == "config" and party.host == player then
			sendMode(player, "config", { mode = "config", unlocks = prof and unlockPayload(prof) or nil })
		else
			sendMode(player, "party", {
				mode = "party",
				map = party.map, difficulty = party.difficulty, size = party.size,
				isHost = party.host == player,
			})
		end
		return
	end

	if not prof then
		sendMode(player, "loading", { mode = "blocked", reason = "Loading your profile..." })
		return
	end

	if not party then
		-- Empty pad: this player becomes the HOST and starts configuring.
		party = { zone = zone, state = "config", host = player, members = { player } }
		parties[zone] = party
		playerParty[player.UserId] = party
		updateBillboard(zone, party)
		sendMode(player, "config", { mode = "config", unlocks = unlockPayload(prof) })
	elseif party.state == "config" then
		sendMode(player, "blockedSetup", { mode = "blocked", reason = "This pad is being set up — wait for the host to press PLAY." })
	else -- open
		if #party.members >= party.size then
			sendMode(player, "blockedFull", { mode = "blocked", reason = "This party is full." })
		elseif not diffUnlocked(prof.completed, party.map, party.difficulty) then
			sendMode(player, "blockedLock", {
				mode = "blocked",
				reason = ("You haven't unlocked %s · %s yet."):format(cap(party.map), cap(party.difficulty)),
			})
		else
			table.insert(party.members, player)
			playerParty[player.UserId] = party
			updateBillboard(zone, party)
			sendMode(player, "party", {
				mode = "party",
				map = party.map, difficulty = party.difficulty, size = party.size,
				isHost = false,
			})
		end
	end
end

FinalizeParty.OnServerEvent:Connect(function(player, sel)
	if not allow(player, "Party") or typeof(sel) ~= "table" then
		return
	end
	local party = playerParty[player.UserId]
	if not party or party.state ~= "config" or party.host ~= player then
		return
	end
	local prof = profileCache[player.UserId]
	local map, difficulty, size = tostring(sel.map), tostring(sel.difficulty), tonumber(sel.size)
	if not indexOf(WORLDS, map) or not indexOf(DIFFS, difficulty) then
		return
	end
	if not prof or not diffUnlocked(prof.completed, map, difficulty) then
		return
	end
	party.map = map
	party.difficulty = difficulty
	party.size = math.clamp(math.floor(size or 1), 1, 4)
	party.state = "open"
	party.deadline = os.clock() + PARTY_WAIT
	lastMode[player.UserId] = nil -- re-send: host's UI flips from config to party view
	updateBillboard(party.zone, party)
end)

LeaveParty.OnServerEvent:Connect(function(player)
	if not allow(player, "Party") then
		return
	end
	local party = playerParty[player.UserId]
	removeFromParty(player)
	lastMode[player.UserId] = nil
	ZoneLeave:FireClient(player)
	-- Step them off the pad so they don't instantly re-enter.
	if party then
		local zone = party.zone
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and zone.Parent then
			local out = zone.CFrame.LookVector
			root.CFrame = CFrame.new(zone.Position + out * (zone.Size.Z * 0.5 + 6) + Vector3.new(0, 4, 0))
		end
	end
end)

-- ===== SHOP ZONE + BILLBOARD =====
local inShopZone = {} -- userId -> shop zone Part they're standing in
local lastShopWindow = shopWindow()

local function updateShopBillboard(part)
	local bb = part:FindFirstChild("ShopBillboard")
	local label
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "ShopBillboard"
		bb.Size = UDim2.fromOffset(240, 60)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		bb.AlwaysOnTop = true
		bb.Parent = part
		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.new(1, 0, 0, 32)
		title.BackgroundColor3 = BB_PANEL
		title.BackgroundTransparency = 0.12
		title.FontFace = BB_TITLE
		title.TextSize = 20
		title.TextColor3 = BB_GOLD
		title.Text = "SHOP"
		title.Parent = bb
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = title
		label = Instance.new("TextLabel")
		label.Name = "Timer"
		label.Position = UDim2.new(0, 0, 0, 34)
		label.Size = UDim2.new(1, 0, 0, 26)
		label.BackgroundColor3 = BB_PANEL
		label.BackgroundTransparency = 0.12
		label.FontFace = BB_BODY
		label.TextSize = 14
		label.TextColor3 = BB_TEXT
		label.Parent = bb
		local c2 = Instance.new("UICorner")
		c2.CornerRadius = UDim.new(0, 8)
		c2.Parent = label
	else
		label = bb:FindFirstChild("Timer")
	end
	if label then
		local remaining = SHOP.RestockSeconds - (os.time() % SHOP.RestockSeconds)
		label.Text = ("New stock in %d:%02d"):format(math.floor(remaining / 60), remaining % 60)
	end
end

-- ===== TICK =====
local function tick()
	if os.clock() - lastZoneScan > 3 then
		lastZoneScan = os.clock()
		refreshZones()
	end

	-- Restock rollover: reroll the stock and live-swap it for everyone browsing.
	local window = shopWindow()
	if window ~= lastShopWindow then
		lastShopWindow = window
		shopCache = nil
		for _, player in Players:GetPlayers() do
			if inShopZone[player.UserId] then
				pushShop(player)
			end
		end
	end
	for _, part in shopZoneParts do
		if part.Parent then
			updateShopBillboard(part)
		end
	end

	-- Zone presence.
	for _, player in Players:GetPlayers() do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local currentZone = nil
		if hrp then
			for _, part in zoneParts do
				if part.Parent and inPart(hrp.Position, part) then
					currentZone = part
					break
				end
			end
		end
		local prevZone = inZonePart[player.UserId]
		if currentZone ~= prevZone then
			inZonePart[player.UserId] = currentZone
			lastMode[player.UserId] = nil
			if prevZone then
				removeFromParty(player)
				ZoneLeave:FireClient(player)
			end
		end
		if currentZone then
			evaluateZone(player, currentZone)
		end

		-- Shop zone presence (independent of the party pads).
		local currentShopZone = nil
		if hrp then
			for _, part in shopZoneParts do
				if part.Parent and inPart(hrp.Position, part) then
					currentShopZone = part
					break
				end
			end
		end
		local prevShopZone = inShopZone[player.UserId]
		if currentShopZone ~= prevShopZone then
			inShopZone[player.UserId] = currentShopZone
			if currentShopZone then
				pushShop(player, true) -- enter -> open the storefront
			else
				ShopClose:FireClient(player)
			end
		end
	end

	-- Open parties: prune leavers, live status, launch on full or timeout.
	local now = os.clock()
	for zone, party in parties do
		if not zone.Parent then
			parties[zone] = nil
		elseif party.state == "open" then
			for i = #party.members, 1, -1 do
				if not party.members[i].Parent then
					local pl = party.members[i]
					playerParty[pl.UserId] = nil
					table.remove(party.members, i)
				end
			end
			if #party.members == 0 then
				parties[zone] = nil
				updateBillboard(zone, nil)
			else
				-- Full party (incl. solo): shorten the countdown to FULL_GRACE — never launch instantly,
				-- so there's always a window to press LEAVE. If someone drops back out, the grace stays
				-- (they chose to fill it once; the timer keeps things moving).
				if #party.members >= party.size and (party.deadline - now) > FULL_GRACE then
					party.deadline = now + FULL_GRACE
				end
				local secs = math.max(0, math.ceil(party.deadline - now))
				for _, pl in party.members do
					PartyStatus:FireClient(pl, {
						map = party.map, difficulty = party.difficulty, size = party.size,
						count = #party.members, seconds = secs,
					})
				end
				updateBillboard(zone, party)
				if now >= party.deadline then
					dissolveAndLaunch(party)
				end
			end
		end
	end
end

-- ===== LIFECYCLE =====
local function onJoin(player)
	player.CharacterAdded:Connect(function(character)
		setCollisionGroup(character)
		task.defer(refreshCarry, player)
	end)
	if player.Character then
		setCollisionGroup(player.Character)
	end
	task.spawn(function()
		local profile = readProfile(player)
		profileCache[player.UserId] = profile
		StatsRemote:FireClient(player, profile)
		pushInv(player)
		refreshCarry(player)
	end)
end

Players.PlayerAdded:Connect(onJoin)
for _, pl in Players:GetPlayers() do
	onJoin(pl)
end
Players.PlayerRemoving:Connect(function(pl)
	removeFromParty(pl)
	persist(pl) -- immediate write on leave (flushes anything the batch loop hasn't gotten to)
	profileCache[pl.UserId] = nil
	dirty[pl.UserId] = nil
	buckets[pl.UserId] = nil
	inZonePart[pl.UserId] = nil
	inShopZone[pl.UserId] = nil
	lastMode[pl.UserId] = nil
end)

-- Batched persistence: dirty profiles get written every PERSIST_FLUSH_SECONDS instead of per action.
task.spawn(function()
	while true do
		task.wait(PERSIST_FLUSH_SECONDS)
		for _, pl in Players:GetPlayers() do
			if dirty[pl.UserId] then
				task.spawn(persist, pl)
			end
		end
	end
end)

game:BindToClose(function()
	for _, pl in Players:GetPlayers() do
		persist(pl)
	end
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= TICK then
		acc = 0
		tick()
	end
end)

print(("[LobbyServer] started (party pads + 2-slot loadout + shop%s)"):format(RunService:IsStudio() and " — Studio: teleports won't fire until published" or ""))

-- Buy a gun outright with Coins (crates only pay skins now).
BuyGun.OnServerEvent:Connect(function(player, req)
	if not allow(player, "Buy") or typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local weaponId = tostring(req.weaponId or "")
	local w = WEAPONS[weaponId]
	if not w or table.find(prof.ownedWeapons, weaponId) then
		return
	end
	if accountLevel(prof.xp) < (w.unlock or 0) then
		return -- account level too low: this gun isn't unlocked yet (client shows "UNLOCKS AT LV N")
	end
	local price = tonumber(w.price) or 0
	if price <= 0 or prof.lobbyMoney < price then
		return
	end
	prof.lobbyMoney -= price
	table.insert(prof.ownedWeapons, weaponId)
	prof.gunLevels[weaponId] = 1 -- legacy field kept in sync
	-- Auto-equip into the gun's own slot if it's currently empty.
	local sl = slotFor(weaponId)
	if not prof.loadout[sl] then
		prof.loadout[sl] = weaponId
		refreshCarry(player)
	end
	markDirty(player)
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- Equip / clear a skin on a gun you own.
EquipSkin.OnServerEvent:Connect(function(player, req)
	if not allow(player, "Skin") or typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local weaponId = tostring(req.weaponId or "")
	if not WEAPONS[weaponId] or not table.find(prof.ownedWeapons, weaponId) then
		return
	end
	if req.skinId == nil or req.skinId == false then
		prof.skins.equipped[weaponId] = nil
	else
		local skinId = tostring(req.skinId)
		local fullId = weaponId .. "_" .. skinId
		if not SKINS[fullId] or not prof.skins.owned[fullId] then
			return
		end
		prof.skins.equipped[weaponId] = skinId
	end
	markDirty(player)
	refreshCarry(player)
	pushInv(player)
end)

-- Volume sliders -> the shared profile's settings.vol (read by BOTH places at join).
SetSoundSettings.OnServerEvent:Connect(function(player, vol)
	if not allow(player, "Settings") then
		return
	end
	if typeof(vol) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local m, mu, s = tonumber(vol.master), tonumber(vol.music), tonumber(vol.sfx)
	if not m or not mu or not s or m ~= m or mu ~= mu or s ~= s then
		return
	end
	prof.settings = (typeof(prof.settings) == "table") and prof.settings or {}
	prof.settings.vol = {
		master = math.clamp(m, 0, 1),
		music = math.clamp(mu, 0, 1),
		sfx = math.clamp(s, 0, 1),
	}
	markDirty(player)
end)

-- Camera-shake on/off -> the shared profile's settings.shake (the game place reads it to gate screen shake).
SetShake.OnServerEvent:Connect(function(player, on)
	if not allow(player, "Settings") then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	prof.settings = (typeof(prof.settings) == "table") and prof.settings or {}
	prof.settings.shake = (on == true)
	markDirty(player)
end)
