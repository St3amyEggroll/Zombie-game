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
local ALL_WORLDS_OPEN  = true -- OPEN EVERY MAP for now (skips the beat-the-previous-world gate; flip to false to re-lock)
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
	-- Pad walls: a busy pad (being set up, or its party is full — solo included) is fenced off with a
	-- forcefield that blocks OUTSIDERS. Party members ride in the "PartyMember" group, which passes
	-- through the wall (so the host can still step off to cancel) but otherwise acts like PLAYER_GROUP.
	PhysicsService:RegisterCollisionGroup("PadWall")
	PhysicsService:RegisterCollisionGroup("PartyMember")
	PhysicsService:CollisionGroupSetCollidable("PadWall", "PartyMember", false)
	PhysicsService:CollisionGroupSetCollidable("PartyMember", PLAYER_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable("PartyMember", "PartyMember", false)
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
-- LADDER ORDER (matches the game place's WeaponConfig.unlock — keep in sync): pistol -> revolver -> ...
local WEAPON_UNLOCK = {
	pistol = 0, revolver = 2, shotgun = 4, tommygun = 6, ak47 = 8, crossbow = 10,
	honeybadger = 12, m4 = 14, p90 = 16, flamethrower = 18, freezeray = 20, minigun = 22,
	sniper = 24, plasma = 26, rocket = 28, raygun = 30,
}
for id, w in WEAPONS do
	w.unlock = WEAPON_UNLOCK[id] or 0 -- rides in the catalog sent to the client (drives the "next unlock" UI)
end

-- Knockback (studs/sec shove per hit) mirrors the game's WeaponConfig — drives the KNOCKBACK stat bar.
local WEAPON_KNOCKBACK = {
	pistol = 26, revolver = 34, shotgun = 48, ak47 = 24, crossbow = 10, freezeray = 6, minigun = 16,
	raygun = 40, m4 = 22, tommygun = 18, sniper = 40, flamethrower = 4, rocket = 60, plasma = 20,
	honeybadger = 20, p90 = 16,
}
for id, w in WEAPONS do
	w.knockback = WEAPON_KNOCKBACK[id] or 0
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
	-- CHANGED: the original four get TINTS too, so every skin renders as a real recolored gun
	-- (shop cards, swatches, carry, in-hand) with no dedicated model needed. A model still wins if built.
	worn  = { name = "Worn",  rarity = "common",    tint = Color3.fromRGB(122, 112, 96) },
	toxic = { name = "Toxic", rarity = "rare",      tint = Color3.fromRGB(88, 196, 60) },
	gold  = { name = "Gold",  rarity = "legendary", tint = Color3.fromRGB(222, 178, 58) },
	void  = { name = "Void",  rarity = "divine",    tint = Color3.fromRGB(88, 48, 132) },
	-- NEW: TINTED skins — no model needed: the base gun is cloned and recolored with `tint` everywhere
	-- (carry, UI, in-game hand). `image` is the owner's art, shown on swatches + reel tiles.
	-- KEEP rarities in sync with the game place's SkinConfig.SkinNames BY HAND.
	red   = { name = "Red",   rarity = "rare",      tint = Color3.fromRGB(198, 30, 30),   image = "rbxassetid://70603022597075" },
	pink  = { name = "Pink",  rarity = "legendary", tint = Color3.fromRGB(255, 105, 190), image = "rbxassetid://97862388516710" },
	black = { name = "Black", rarity = "divine",    tint = Color3.fromRGB(28, 28, 32),    image = "rbxassetid://106670146411294" },
}
local SKINS = {}        -- [fullId "revolver_gold"] = { id, gun, skin, name, rarity }
local SKINS_BY_RARITY = {} -- rarity -> sorted { fullId }
for gunId, w in WEAPONS do
	for skinId, s in SKIN_NAMES do
		local fullId = gunId .. "_" .. skinId
		SKINS[fullId] = { id = fullId, gun = gunId, skin = skinId, name = s.name .. " " .. w.name, rarity = s.rarity, tint = s.tint, image = s.image }
		SKINS_BY_RARITY[s.rarity] = SKINS_BY_RARITY[s.rarity] or {}
		table.insert(SKINS_BY_RARITY[s.rarity], fullId)
	end
end
for _, list in SKINS_BY_RARITY do
	table.sort(list)
end
local SKIN_DUP_COINS = { common = 25, uncommon = 60, rare = 150, epic = 400, legendary = 1000, mythic = 2500, divine = 6000 }

-- 7 rarity-tiered cases (wave rewards + starter grants + the shop).
-- PHOTOS: add image = "rbxassetid://..." to any CASES entry (and to WEAPONS/POTIONS entries) and the
-- inventory/shop UI shows the picture on cards + detail panes automatically.
-- CHANGED: crates pay SKINS ONLY (guns removed from the pools by owner request — guns come from the
-- XP ladder + BuyGun). A pull rolls a skin RARITY from these weights, then a uniform skin of that
-- rarity. Duplicates convert to coins.
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
-- CHANGED (owner request): the featured EXCLUSIVE PACK pays GUNS now, not skins. Its own virtual
-- case id ("gunpack") keeps the regular rarity crates skins-only. A pull rolls a gun RARITY from
-- gunWeights, then grants a gun you DON'T own yet (prefers the rolled rarity); when you own them
-- all, the pull pays big dupe coins instead.
CASES.gunpack = {
	name = "Exclusive Gun Pack",
	gunWeights = { uncommon = 30, rare = 34, epic = 24, legendary = 12 },
}
local GUNS_BY_RARITY = {} -- gun rarity -> sorted { weaponId }
for id, w in WEAPONS do
	GUNS_BY_RARITY[w.rarity] = GUNS_BY_RARITY[w.rarity] or {}
	table.insert(GUNS_BY_RARITY[w.rarity], id)
end
for _, l in GUNS_BY_RARITY do
	table.sort(l)
end
local GUN_DUP_COINS = { common = 150, uncommon = 300, rare = 600, epic = 1200, legendary = 2500 }

-- ===== CLASSES (C1 passive kits) ===== picked in the class SHOWCASE (camera-on-your-character screen).
-- The GAME place applies the passives (its ClassConfig mirrors these numbers BY HAND — change both).
local CLASS_IDS = { soldier = true, juggernaut = true, runner = true, scavenger = true }

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
	-- NEW: THE EXCLUSIVE PACK — the featured crate the EXCLUSIVE SHOP panel opens (×1/×3/×10).
	-- One seeded rarity per rotation (always an exciting tier). ROBUX ONLY: create three Developer
	-- Products in Creator Hub (Monetization → Developer Products) — one per open size — and paste
	-- their ids here. 0 = that button answers "coming soon" in the shop.
	PackWeights = { rare = 14, epic = 42, legendary = 30, mythic = 10, divine = 4 },
	PackProducts = { [1] = 0, [3] = 0, [10] = 0 }, -- open count -> Developer Product id

	-- NEW: PASSES & COINS tab. COIN BUNDLES (Robux -> Coins): create 4 Developer Products, paste ids.
	CoinBundles = {
		{ id = 0, coins = 1000 },
		{ id = 0, coins = 5000, bonus = "+5%" },
		{ id = 0, coins = 15000, bonus = "+15%" },
		{ id = 0, coins = 50000, bonus = "+30%" },
	},
	-- STARTER PACK: one Developer Product, one purchase EVER per player (repeat receipts pay the coins
	-- again rather than eat the Robux). Contents below.
	StarterProductId = 0,
	StarterCases = { rare = 3 },
	StarterCoins = 2000,
	-- PITY: a LEGENDARY+ skin is guaranteed within this many crate opens (counts every crate).
	PityEvery = 10,
}

-- ===== DAILY WHEEL (the shop's DAILY tab) ===== one FREE spin per day + Robux re-spins. Segment
-- weight = its slice of the odds; a claim streak fattens the JACKPOT slice a little per day.
local WHEEL = {
	RespinProductId = 0, -- Developer Product for a paid re-spin (0 = button says coming soon)
	MaxPaidSpins = 3,    -- paid re-spins per day
	StreakBonus = 1,     -- +weight on the jackpot slice per consecutive claim day...
	StreakBonusCap = 5,  -- ...capped here
	Segments = {
		{ kind = "coins", amount = 150, weight = 20, label = "150 COINS" },
		{ kind = "case", case = "common", weight = 17, label = "COMMON CRATE" },
		{ kind = "coins", amount = 400, weight = 14, label = "400 COINS" },
		{ kind = "case", case = "rare", weight = 14, label = "RARE CRATE" },
		{ kind = "coins", amount = 800, weight = 12, label = "800 COINS" },
		{ kind = "case", case = "epic", weight = 10, label = "EPIC CRATE" },
		{ kind = "skin", weight = 8, label = "RANDOM SKIN" },
		{ kind = "case", case = "divine", weight = 3, label = "DIVINE CRATE", jackpot = true },
	},
}
local function todayStamp()
	return math.floor(os.time() / 86400)
end

-- Robux price of a pack product (from Roblox, cached — shown on the shop's green pills).
local MarketplaceService = game:GetService("MarketplaceService")
local productPriceCache = {}
local function productPrice(pid)
	if not pid or pid == 0 then
		return nil
	end
	if productPriceCache[pid] ~= nil then
		return productPriceCache[pid] or nil
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(pid, Enum.InfoType.Product)
	end)
	local price = ok and info and tonumber(info.PriceInRobux) or nil
	productPriceCache[pid] = price or false -- cache misses too (no request spam per snapshot)
	return price
end

-- ===== REDEEM CODES (the EXCLUSIVE SHOP's "Enter Code" bar) =====
-- Add a code = add a row (keys UPPERCASE, no spaces). Each pays coins and/or crates, ONCE per player
-- (redeemed codes live in the profile). Retire a code by deleting its row.
local CODES = {
	WELCOME = { coins = 500 },
	ROTTEN  = { case = "rare", caseCount = 1 },
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
	-- NEW: the featured EXCLUSIVE PACK for this window — same seeded roll, so every server agrees.
	local packTotal = 0
	for _, w in SHOP.PackWeights do
		packTotal += w
	end
	local packRoll = r:NextNumber(0, packTotal)
	local packAcc, packRarity = 0, "epic"
	for _, rid in RARITY_ORDER do
		local w = SHOP.PackWeights[rid]
		if w then
			packAcc += w
			if packRoll <= packAcc then
				packRarity = rid
				break
			end
		end
	end
	shopCache = { window = window, slots = slots, pack = packRarity }
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
			if c.skinWeights then
				local total = 0
				for _, weight in c.skinWeights do
					total += weight
				end
				local odds = {}
				-- Item-level "WHAT'S INSIDE" list the featured pane renders — skin-rarity rows only
				-- (CHANGED: guns removed from crates).
				local loot = {}
				for _, sr in RARITY_ORDER do
					if c.skinWeights[sr] then
						table.insert(odds, { rarity = sr, pct = (c.skinWeights[sr] / total) * 100 })
						table.insert(loot, { kind = "skins", rarity = sr, pct = (c.skinWeights[sr] / total) * 100 })
					end
				end
				t[rarity] = { name = c.name, rarity = rarity, poolIds = table.clone(allSkinIds), odds = odds, loot = loot, image = c.image }
			end
		end
		-- The GUN pack's display entry: gun-rarity loot rows + every gun as the reel pool.
		do
			local gunIds = {}
			for id in WEAPONS do
				table.insert(gunIds, id)
			end
			table.sort(gunIds)
			local gw = CASES.gunpack.gunWeights
			local total = 0
			for _, weight in gw do
				total += weight
			end
			local odds, loot = {}, {}
			for _, rid in RARITY_ORDER do
				if gw[rid] then
					table.insert(odds, { rarity = rid, pct = (gw[rid] / total) * 100 })
					table.insert(loot, { kind = "guns", rarity = rid, pct = (gw[rid] / total) * 100 })
				end
			end
			t.gunpack = { name = CASES.gunpack.name, rarity = "legendary", poolIds = gunIds, odds = odds, loot = loot }
		end
		return t
	end)(),
}

local function rollCase(caseId)
	local case = CASES[caseId]
	-- SKINS ONLY (guns no longer drop from crates): roll a rarity, then a uniform skin of that rarity.
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
local ShopSync      = mk("ShopSync")      -- S->C: {enter?, window, endsIn, coins, slots, pack} storefront snapshot
local ShopClose     = mk("ShopClose")     -- S->C: you left the shop zone; close the panel
local ShopBuy       = mk("ShopBuy")       -- C->S: {slot=1..6, open=bool} buy a case | {pack=true, count=1|3|10} open the featured pack
local ShopRedeem    = mk("ShopRedeem")    -- C->S: (code string) redeem · S->C: {ok, msg} the verdict
local ShopGift      = mk("ShopGift")      -- C->S: (userId|nil) arm/clear gifting for your NEXT pack buy
                                          -- S->C: {sent,to,count} buyer confirm | {from,name,count} recipient toast
local WheelSpin     = mk("WheelSpin")     -- C->S: (no args) claim the FREE daily spin
                                          -- S->C: {seg, reward, streak} result | {failed, msg}
local ShopTicker    = mk("ShopTicker")    -- S->C broadcast: {name, item, rarity} someone pulled legendary+
-- Guns & skins
local BuyGun    = mk("BuyGun")    -- C->S: {weaponId} buy a gun outright with Coins
local EquipSkin = mk("EquipSkin") -- C->S: {weaponId, skinId?} equip a skin (nil/false = back to base look)
-- Sound
local SetSoundSettings = mk("SetSoundSettings") -- C->S: ({master, music, sfx} 0..1) persist volume sliders
local SetShake      = mk("SetShake")      -- C->S: (bool) persist the camera-shake on/off preference (shared with the game place)

-- ===== PROFILE =====
local store = DataStoreService:GetDataStore(STORE_NAME)
-- Global best-wave board (the game place writes it via SetAsync on a new personal best).
local bestWaveBoard = DataStoreService:GetOrderedDataStore("ZR_BestWave_v1")
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
	-- XP-ONLY UNLOCKS: every gun whose level the player has reached is owned automatically.
	do
		local lvl = accountLevel(tonumber(data.xp) or 0)
		for id, w in WEAPONS do
			if (w.unlock or 0) <= lvl and not table.find(owned, id) then
				table.insert(owned, id)
			end
		end
	end
	return {
		lobbyMoney = data.lobbyMoney or 0,
		bestWave = data.bestWave or 0,
		wins = tonumber(data.wins) or 0, -- runs won (game-owned; drives the overhead tag + leaderboard)
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
		class = CLASS_IDS[tostring(data.class)] and tostring(data.class) or "", -- equipped class (showcase)
		pity = math.max(0, math.floor(tonumber(data.pity) or 0)), -- crate opens since the last legendary+ pull
		starter = data.starter == true, -- STARTER PACK is one purchase ever
		vipDay = math.floor(tonumber(data.vipDay) or 0), -- last day the VIP daily crate was granted
		wheel = (function() -- daily wheel: last claim day, claim streak, paid re-spins today
			local w = (typeof(data.wheel) == "table") and data.wheel or {}
			return {
				day = math.floor(tonumber(w.day) or 0),
				streak = math.max(0, math.floor(tonumber(w.streak) or 0)),
				paid = math.max(0, math.floor(tonumber(w.paid) or 0)),
			}
		end)(),
		quests = (function() -- daily quests: today's 3 ids + progress + claims + the all-3 bonus flag
			local q = (typeof(data.quests) == "table") and data.quests or {}
			local ids, prog, claimed = {}, {}, {}
			if typeof(q.ids) == "table" then
				for i, id in ipairs(q.ids) do
					ids[i] = tostring(id)
					prog[i] = math.max(0, math.floor(tonumber(typeof(q.prog) == "table" and q.prog[i]) or 0))
					claimed[i] = typeof(q.claimed) == "table" and q.claimed[i] == true
				end
			end
			return {
				day = math.floor(tonumber(q.day) or 0),
				ids = ids,
				prog = prog,
				claimed = claimed,
				bonus = q.bonus == true,
			}
		end)(),
		receipts = (function() -- recent Robux PurchaseIds already granted (double-grant guard)
			local out = {}
			if typeof(data.receipts) == "table" then
				for _, id in data.receipts do
					if typeof(id) == "string" then
						table.insert(out, id)
					end
				end
			end
			return out
		end)(),
		redeemed = (function() -- codes this player already claimed: { CODE = true }
			local out = {}
			if typeof(data.redeemed) == "table" then
				for k, v in data.redeemed do
					if typeof(k) == "string" and v == true then
						out[k] = true
					end
				end
			end
			return out
		end)(),
		noPersist = loadFailed, -- fallback profile: NEVER write it back
	}
end

-- Merge the lobby-owned fields back into the shared profile WITHOUT clobbering game-owned fields.
-- IMMEDIATE write — call this only at must-not-lose moments (leave, teleport, shutdown). Everything
-- else goes through markDirty(); a background loop batches those writes so a case-opening spree doesn't
-- hammer the same DataStore key (Roblox throttles same-key writes to ~1 per 6s).
local dirty = {} -- userId -> true (profile changed since the last write)
local PERSIST_FLUSH_SECONDS = 30

-- CHANGED: retries with backoff (like the game place's saveAsync) and RETURNS success so money/teleport
-- paths can react to a failed write instead of assuming durability.
local function persist(player)
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		dirty[player.UserId] = nil
		return true -- nothing to write is "success" (fallback profiles are intentionally not saved)
	end
	local ok = false
	for attempt = 1, 4 do
		ok = pcall(function()
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
				old.redeemed = prof.redeemed
				old.receipts = prof.receipts
				old.pity = prof.pity
				old.starter = prof.starter
				old.wheel = prof.wheel
				old.vipDay = prof.vipDay
				old.quests = prof.quests
				old.class = prof.class
				return old
			end)
		end)
		if ok then
			break
		end
		warn(("[LobbyServer] persist failed for %s (attempt %d) — retrying"):format(player.Name, attempt))
		task.wait(attempt) -- 1s, 2s, 3s backoff
	end
	if ok then
		dirty[player.UserId] = nil
	end -- on failure the dirty flag stays; the flush loop keeps retrying
	return ok
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

-- ===== DAILY QUESTS ===== 3 rotating dailies per player per day (deterministic: userId + day seeds the
-- pick, so relogging can't re-roll them). Progress feeds from run summaries (the game place teleports
-- back with a SERVER-set summary — GetJoinData, not the client) and from lobby crate opens. Rewards are
-- COINS only (XP is game-owned; the lobby never writes it). Clear all 3 → a bonus crate.
local QUESTS = {
	PerDay = 3,
	BonusCase = "rare", -- clearing the whole board pays one of these
	Pool = {
		-- stat: kills/money/runs/wins/crates accumulate; wave keeps the best single run (max = true)
		{ id = "kills150", name = "KILL 150 ZOMBIES", stat = "kills", goal = 150, coins = 500 },
		{ id = "kills400", name = "KILL 400 ZOMBIES", stat = "kills", goal = 400, coins = 1200 },
		{ id = "wave8", name = "REACH WAVE 8", stat = "wave", goal = 8, coins = 400, max = true },
		{ id = "wave12", name = "REACH WAVE 12", stat = "wave", goal = 12, coins = 900, max = true },
		{ id = "earn1500", name = "EARN 1,500 COINS", stat = "money", goal = 1500, coins = 600 },
		{ id = "runs2", name = "PLAY 2 RUNS", stat = "runs", goal = 2, coins = 400 },
		{ id = "win1", name = "WIN A RUN", stat = "wins", goal = 1, coins = 1000 },
		{ id = "crates2", name = "OPEN 2 CRATES", stat = "crates", goal = 2, coins = 350 },
	},
}
local QuestSync = mk("QuestSync") -- S->C: { resetIn, list = {name, goal, prog, coins, claimed}, bonus... }
local QuestClaim = mk("QuestClaim") -- C->S: {i} claim quest i's coins

local function questDef(id)
	for _, d in QUESTS.Pool do
		if d.id == id then
			return d
		end
	end
	return nil
end

-- Today's 3 defs for this player, re-rolling at day change (or if the pool changed under saved ids).
local function ensureQuests(player, prof)
	local q = prof.quests
	local today = todayStamp()
	local stale = q.day ~= today or #q.ids ~= QUESTS.PerDay
	if not stale then
		for _, id in q.ids do
			if not questDef(id) then
				stale = true -- pool edit orphaned a saved id
			end
		end
	end
	if stale then
		q.day = today
		q.ids, q.prog, q.claimed, q.bonus = {}, {}, {}, false
		local rng = Random.new(player.UserId * 100003 + today)
		local pool = table.clone(QUESTS.Pool)
		local used = {} -- one quest per STAT: two "REACH WAVE" rows read as the same quest twice
		for i = 1, QUESTS.PerDay do
			local k
			for _ = 1, 24 do
				k = rng:NextInteger(1, #pool)
				if not used[pool[k].stat] then
					break
				end
			end
			used[pool[k].stat] = true
			q.ids[i] = pool[k].id
			q.prog[i] = 0
			q.claimed[i] = false
			table.remove(pool, k)
		end
	end
	local defs = {}
	for i, id in q.ids do
		defs[i] = questDef(id)
	end
	return defs
end

local function questSnapshot(player, prof)
	local defs = ensureQuests(player, prof)
	local q = prof.quests
	local list = {}
	for i, d in defs do
		list[i] = {
			name = d.name,
			stat = d.stat, -- the client draws a matching icon chip per quest
			goal = d.goal,
			prog = math.min(q.prog[i] or 0, d.goal),
			coins = d.coins or 0,
			claimed = q.claimed[i] == true,
		}
	end
	return {
		resetIn = 86400 - os.time() % 86400,
		list = list,
		bonusCase = QUESTS.BonusCase,
		bonusDone = q.bonus == true,
	}
end

local function pushQuests(player)
	local prof = profileCache[player.UserId]
	if prof then
		QuestSync:FireClient(player, questSnapshot(player, prof))
	end
end

-- Feed an amount into every active quest tracking `stat` (accumulate, or best-value when def.max).
local function bumpQuest(player, stat, amount)
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist or amount <= 0 then
		return
	end
	local defs = ensureQuests(player, prof)
	local q = prof.quests
	local changed = false
	for i, d in defs do
		if d.stat == stat and not q.claimed[i] and (q.prog[i] or 0) < d.goal then
			local new = d.max and math.max(q.prog[i] or 0, amount) or (q.prog[i] or 0) + amount
			if new ~= q.prog[i] then
				q.prog[i] = new
				changed = true
			end
		end
	end
	if changed then
		markDirty(player)
		pushQuests(player)
	end
end

-- ===== ON-BODY GUNS (hub cosmetic) =====
-- Loadout guns ride on your character: SLOT 1 across the BACK, SLOT 2 on the HIP (a lone small gun sits
-- on the hip). Models: tag gun Models "WeaponModel" or put them in an "Assets" folder — named after the
-- weapon id or display name, same contract as the game place. Missing model = skipped quietly.
local CARRY_SMALL = { pistol = true, revolver = true } -- "small" guns prefer the hip when alone
-- REDONE: mounting by the Handle with one universal CFrame put guns through heads and sideways off
-- hips, because every model is BUILT in a different orientation. Carried guns are now normalized by
-- their BOUNDING BOX: the longest box axis is the barrel line, the thinnest is the flat side — the gun
-- is laid FLAT against the body with the barrel along the slot's direction, and oversized guns shrink.
local CARRY_ANGLE = 40 -- degrees off vertical for the diagonal back sling
local CARRY_FLIP = { -- a gun slung barrel-DOWN that bugs you? add `weaponid = true` to flip it
}

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

-- Lay a carried gun FLAT against the body, barrel along the slot's line, regardless of how its model
-- was built. slot = "back" (diagonal sling) | "hip" (holstered low on the right side).
local function orientCarry(model, torso, weaponId, slot)
	local function boxAxes()
		local bboxCF, size = model:GetBoundingBox()
		local axes = {
			{ v = bboxCF.RightVector, d = size.X },
			{ v = bboxCF.UpVector, d = size.Y },
			{ v = bboxCF.LookVector, d = size.Z },
		}
		table.sort(axes, function(a, b)
			return a.d > b.d
		end)
		return bboxCF, axes
	end
	local bboxCF, axes = boxAxes() -- (no downscaling — guns keep their real size, per the owner)
	local tc = torso.CFrame
	local longT, thinT, mountPos
	if slot == "back" then
		local a = math.rad(CARRY_ANGLE)
		longT = (tc.UpVector * math.cos(a) + tc.RightVector * math.sin(a)).Unit
		thinT = -tc.LookVector -- flat side faces out behind the back
		mountPos = tc * Vector3.new(0, 0.2, 0.5 + axes[3].d / 2 + 0.05)
	else
		longT = (tc.LookVector - tc.UpVector * 0.12).Unit -- barrel forward, nose dipped a touch
		thinT = tc.RightVector -- flat side faces out from the hip
		mountPos = tc * Vector3.new(0.85 + axes[3].d / 2, -0.85, 0.2)
	end
	if CARRY_FLIP[weaponId] then
		longT = -longT
	end
	local curr = CFrame.fromMatrix(bboxCF.Position, axes[1].v, axes[3].v)
	local target = CFrame.fromMatrix(mountPos, longT, thinT)
	model:PivotTo(target * curr:Inverse() * model:GetPivot())
end

local function attachCarry(char, torso, weaponId, slot, name, prof)
	-- Equipped skin's model first, base gun as fallback (tinted when the skin is a tint skin).
	local template, tint
	local skinId = prof and prof.skins and prof.skins.equipped and prof.skins.equipped[weaponId]
	if skinId then
		template = carryTemplates[weaponId .. "_" .. skinId]
		if not template then
			local sn = SKIN_NAMES[skinId]
			tint = sn and sn.tint or nil -- no dedicated model: recolor the base gun clone
		end
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
	-- Pose the WHOLE model FIRST (bounding-box normalized), and only THEN create the welds.
	-- WeldConstraints capture their offsets when they activate — welding while the parts still sit at
	-- the template's position froze those faraway offsets in.
	orientCarry(model, torso, weaponId, slot)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Anchored = false
			if tint then
				d.Color = tint:Lerp(d.Color, 0.15) -- tint skin: mostly flat color, a hint of shading
			end
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
		attachCarry(char, torso, g1, CARRY_SMALL[g1] and "hip" or "back", "CarriedWeapon1", prof)
	else
		if g1 then
			attachCarry(char, torso, g1, "back", "CarriedWeapon1", prof)
		end
		if g2 then
			attachCarry(char, torso, g2, "hip", "CarriedWeapon2", prof)
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
	if ALL_WORLDS_OPEN then
		return true
	end
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
		-- Resend stats too: the join-time pushes can fire BEFORE the (large) client script has
		-- connected its handlers — this request is the client saying "I'm ready now".
		local prof = profileCache[player.UserId]
		if prof then
			StatsRemote:FireClient(player, prof)
		end
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
	-- THE GUN PACK (the featured Robux pack): rolls a GUN — always one you don't own when possible
	-- (prefers the rolled rarity), auto-equips into an empty slot; own them all and it pays big dupe
	-- coins. Skips the skin pity counter entirely.
	if caseId == "gunpack" then
		local gw = CASES.gunpack.gunWeights
		local total = 0
		for _, weight in gw do
			total += weight
		end
		local r = rng:NextNumber(0, total)
		local acc, chosen = 0, "rare"
		for _, rid in RARITY_ORDER do
			if gw[rid] then
				acc += gw[rid]
				if r <= acc then
					chosen = rid
					break
				end
			end
		end
		local function unownedOf(rid)
			local l = {}
			for _, id in GUNS_BY_RARITY[rid] or {} do
				if not table.find(prof.ownedWeapons, id) then
					table.insert(l, id)
				end
			end
			return l
		end
		local pool = unownedOf(chosen)
		if #pool == 0 then -- rolled rarity all owned: any unowned gun still beats a dupe
			for _, rid in RARITY_ORDER do
				local l = unownedOf(rid)
				if #l > 0 then
					pool, chosen = l, rid
					break
				end
			end
		end
		if #pool > 0 then
			local wonGun = pool[rng:NextInteger(1, #pool)]
			table.insert(prof.ownedWeapons, wonGun)
			prof.gunLevels[wonGun] = prof.gunLevels[wonGun] or 1
			local sl = slotFor(wonGun)
			if not prof.loadout[sl] then
				prof.loadout[sl] = wonGun
				refreshCarry(player)
			end
			local wr = WEAPONS[wonGun].rarity
			if wr == "epic" or wr == "legendary" then
				ShopTicker:FireAllClients({ name = player.DisplayName or player.Name, item = WEAPONS[wonGun].name, rarity = wr })
			end
			return { caseId = caseId, wonId = wonGun, coins = 0, unlocked = true }
		end
		local list = GUNS_BY_RARITY[chosen] or GUNS_BY_RARITY.rare
		local wonGun = list[rng:NextInteger(1, #list)]
		local c = GUN_DUP_COINS[WEAPONS[wonGun].rarity] or 500
		prof.lobbyMoney += c
		return { caseId = caseId, wonId = wonGun, coins = c, unlocked = false, maxed = true }
	end
	-- SKINS ONLY (guns removed from crates): the pull is always a skin; duplicates convert to coins.
	-- PITY: at PityEvery-1 opens without a legendary+, this open is FORCED to legendary/divine
	-- (weighted by this crate's own top-tier weights).
	local wonId
	if (prof.pity or 0) >= SHOP.PityEvery - 1 then
		local case = CASES[caseId]
		local lw = case.skinWeights.legendary or 1
		local dw = case.skinWeights.divine or 0
		local rarity = (rng:NextNumber(0, lw + dw) <= lw) and "legendary" or "divine"
		local list = SKINS_BY_RARITY[rarity] or SKINS_BY_RARITY.legendary
		wonId = list[rng:NextInteger(1, #list)]
	else
		wonId = rollCase(caseId)
	end
	local skin = SKINS[wonId]
	if skin.rarity == "legendary" or skin.rarity == "divine" then
		prof.pity = 0
		-- the live pull TICKER: brag about legendary+ pulls to the whole server
		ShopTicker:FireAllClients({ name = player.DisplayName or player.Name, item = skin.name, rarity = skin.rarity })
	else
		prof.pity = (prof.pity or 0) + 1
	end
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
	bumpQuest(player, "crates", 1) -- daily quests count every crate you open
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
		-- The featured EXCLUSIVE PACK — ROBUX ONLY (Developer Product ids + live Robux prices).
		-- CHANGED: the pack is the GUN pack now (guns, not skins).
		pack = {
			caseId = "gunpack",
			name = CASES.gunpack.name,
			product1 = SHOP.PackProducts[1],
			product3 = SHOP.PackProducts[3],
			product10 = SHOP.PackProducts[10],
			robux1 = productPrice(SHOP.PackProducts[1]),
			robux3 = productPrice(SHOP.PackProducts[3]),
			robux10 = productPrice(SHOP.PackProducts[10]),
		},
		-- PITY meter: opens left until the guaranteed legendary+.
		pityLeft = math.max(1, SHOP.PityEvery - (prof.pity or 0)),
		-- PASSES & COINS tab: bundles + the one-time starter pack.
		bundles = (function()
			local t = {}
			for i, b in ipairs(SHOP.CoinBundles) do
				t[i] = { coins = b.coins, bonus = b.bonus, productId = b.id, robux = productPrice(b.id) }
			end
			return t
		end)(),
		starter = {
			productId = SHOP.StarterProductId,
			robux = productPrice(SHOP.StarterProductId),
			bought = prof.starter == true,
			coins = SHOP.StarterCoins,
		},
		-- DAILY WHEEL tab state + segment display data.
		wheel = (function()
			local today = todayStamp()
			local claimedToday = prof.wheel.day == today
			local segs = {}
			for i, s in ipairs(WHEEL.Segments) do
				segs[i] = { label = s.label, weight = s.weight, kind = s.kind, jackpot = s.jackpot or nil,
					case = s.case, amount = s.amount } -- case/amount drive the chips' drawn icons
			end
			return {
				freeUsed = claimedToday,
				paidLeft = claimedToday and math.max(0, WHEEL.MaxPaidSpins - (prof.wheel.paid or 0)) or WHEEL.MaxPaidSpins,
				streak = prof.wheel.streak or 0,
				respinProduct = WHEEL.RespinProductId,
				respinRobux = productPrice(WHEEL.RespinProductId),
				segments = segs,
			}
		end)(),
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
		bumpQuest(player, "crates", 1)
	end
	markDirty(player)
	if result then
		CaseResult:FireClient(player, result)
	end
	pushShop(player)
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- NEW: promo codes — validate, pay out, remember (one redeem per code per player, saved in the profile).
ShopRedeem.OnServerEvent:Connect(function(player, code)
	local function reply(ok, msg)
		ShopRedeem:FireClient(player, { ok = ok, msg = msg })
	end
	if not allow(player, "Shop") then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return reply(false, "TRY AGAIN LATER")
	end
	if typeof(code) ~= "string" or #code < 1 or #code > 32 then
		return reply(false, "INVALID CODE")
	end
	local clean = code:upper():gsub("%s", "")
	local def = CODES[clean]
	if not def then
		return reply(false, "INVALID CODE")
	end
	if prof.redeemed[clean] then
		return reply(false, "ALREADY REDEEMED")
	end
	prof.redeemed[clean] = true
	local parts = {}
	if typeof(def.coins) == "number" and def.coins > 0 then
		prof.lobbyMoney += def.coins
		table.insert(parts, "🪙 " .. def.coins)
	end
	if def.case and CASES[def.case] then
		local n = tonumber(def.caseCount) or 1
		prof.cases[def.case] = (prof.cases[def.case] or 0) + n
		table.insert(parts, (n > 1 and (n .. "× ") or "") .. CASES[def.case].name)
	end
	markDirty(player)
	pushInv(player)
	pushShop(player)
	StatsRemote:FireClient(player, prof)
	reply(true, "REDEEMED!  +" .. table.concat(parts, "  +"))
end)

-- ===== DAILY WHEEL ===== roll a segment (streak fattens the jackpot slice), grant it, tell the client
-- which slice to land on. Free spin claims the day + advances the streak; paid re-spins ride receipts.
local function doWheelSpin(player, prof)
	local bonus = math.min(WHEEL.StreakBonusCap, (prof.wheel.streak or 0) * WHEEL.StreakBonus)
	local total = 0
	for _, s in WHEEL.Segments do
		total += s.weight + (s.jackpot and bonus or 0)
	end
	local roll = rng:NextNumber(0, total)
	local acc, idx = 0, 1
	for i, s in ipairs(WHEEL.Segments) do
		acc += s.weight + (s.jackpot and bonus or 0)
		if roll <= acc then
			idx = i
			break
		end
	end
	local seg = WHEEL.Segments[idx]
	local rewardText
	if seg.kind == "coins" then
		prof.lobbyMoney += seg.amount
		rewardText = "+" .. seg.amount .. " COINS"
	elseif seg.kind == "case" then
		prof.cases[seg.case] = (prof.cases[seg.case] or 0) + 1
		rewardText = "+1 " .. CASES[seg.case].name:upper()
	else -- random skin (uniform over everything; duplicates convert to coins)
		local ids = {}
		for id in SKINS do
			table.insert(ids, id)
		end
		table.sort(ids)
		local wonId = ids[rng:NextInteger(1, #ids)]
		if prof.skins.owned[wonId] then
			local c = SKIN_DUP_COINS[SKINS[wonId].rarity] or 25
			prof.lobbyMoney += c
			rewardText = ("DUPE %s → +%d COINS"):format(SKINS[wonId].name:upper(), c)
		else
			prof.skins.owned[wonId] = true
			rewardText = "SKIN UNLOCKED: " .. SKINS[wonId].name:upper()
		end
	end
	markDirty(player)
	return idx, rewardText
end

-- Claim the day on any first spin of the day (free OR paid): consecutive days build the streak.
local function wheelClaimDay(prof)
	local today = todayStamp()
	if prof.wheel.day ~= today then
		prof.wheel.streak = (prof.wheel.day == today - 1) and (prof.wheel.streak or 0) + 1 or 1
		prof.wheel.day = today
		prof.wheel.paid = 0
	end
end

WheelSpin.OnServerEvent:Connect(function(player)
	if not allow(player, "Shop") then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return WheelSpin:FireClient(player, { failed = true, msg = "TRY AGAIN LATER" })
	end
	if prof.wheel.day == todayStamp() then
		return WheelSpin:FireClient(player, { failed = true, msg = "FREE SPIN USED — COME BACK TOMORROW" })
	end
	wheelClaimDay(prof)
	local idx, rewardText = doWheelSpin(player, prof)
	WheelSpin:FireClient(player, { seg = idx, reward = rewardText, streak = prof.wheel.streak })
	pushShop(player)
	pushInv(player)
	StatsRemote:FireClient(player, prof)
end)

-- NEW: GIFTING — the pink 🎁 buttons. The client ARMS a gift (recipient userId) right before prompting
-- the same pack product; the receipt below sees the armed gift and banks the crates to the RECIPIENT
-- instead (they open them from their inventory whenever). Cancelling the prompt disarms it client-side;
-- the 3-minute expiry catches anything that slips through.
local pendingGift = {} -- buyerUserId -> { to = userId, at = os.clock() }
ShopGift.OnServerEvent:Connect(function(player, toUserId)
	if not allow(player, "Shop") then
		return
	end
	if toUserId == nil or toUserId == false then
		pendingGift[player.UserId] = nil -- purchase prompt cancelled / picker closed
		return
	end
	toUserId = tonumber(toUserId)
	local target = toUserId and Players:GetPlayerByUserId(toUserId)
	if not target or target == player or not profileCache[toUserId] then
		return
	end
	pendingGift[player.UserId] = { to = toUserId, at = os.clock() }
end)

-- ROBUX pack opens (the EXCLUSIVE SHOP is Robux-only). The client prompts the Developer Product;
-- Roblox calls this receipt processor. Self-buy: grant `count` featured crates, open the FIRST
-- (CaseResult spins the reel; result.chain auto-opens the rest). Gift armed: bank all `count` crates
-- to the recipient + toast both sides (recipient gone = falls back to a self-buy). Persist IMMEDIATELY
-- — real money changed hands — and remember PurchaseIds so Roblox's retries can't double-grant.
MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- left mid-purchase; retried on next join
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- profile not safe to write yet
	end
	-- Which of OUR products is it? Unknown ids stay pending (future products) without being recorded.
	local pid = receiptInfo.ProductId
	local packCount, bundle = nil, nil
	for c, id in SHOP.PackProducts do
		if id ~= 0 and id == pid then
			packCount = c
			break
		end
	end
	for _, b in ipairs(SHOP.CoinBundles) do
		if b.id ~= 0 and b.id == pid then
			bundle = b
			break
		end
	end
	local isStarter = SHOP.StarterProductId ~= 0 and pid == SHOP.StarterProductId
	local isWheel = WHEEL.RespinProductId ~= 0 and pid == WHEEL.RespinProductId
	if not (packCount or bundle or isStarter or isWheel) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	prof.receipts = prof.receipts or {}
	if table.find(prof.receipts, receiptInfo.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- retry of an already-granted receipt
	end
	table.insert(prof.receipts, receiptInfo.PurchaseId)
	if #prof.receipts > 200 then -- CHANGED: 50 was too small; an evicted id lets a slow retry double-grant
		table.remove(prof.receipts, 1)
	end

	-- CHANGED (receipt-safety): the reward + the receipt id are applied to the profile, THEN written
	-- atomically. We only tell Roblox PurchaseGranted once the write is CONFIRMED durable — a failed
	-- write returns NotProcessedYet so Roblox retries later (and the flush loop keeps retrying too),
	-- instead of the old "grant immediately, hope the save lands" which lost paid Robux on a blip.
	local saved = true

	if packCount then
		local caseId = "gunpack" -- CHANGED: the featured pack pays GUNS now
		-- GIFT armed? Deliver to the recipient instead (still in the server + profile loaded).
		local gift = pendingGift[player.UserId]
		pendingGift[player.UserId] = nil
		if gift and os.clock() - gift.at < 180 then
			local target = Players:GetPlayerByUserId(gift.to)
			local tprof = target and profileCache[gift.to]
			if target and tprof and not tprof.noPersist then
				tprof.cases[caseId] = (tprof.cases[caseId] or 0) + packCount
				markDirty(target) -- backstop: keep retrying the recipient write via the flush loop
				local recipientSaved = persist(target) -- recipient: the crates (retried inline)
				local buyerSaved = persist(player) -- buyer: the receipt record
				ShopGift:FireClient(player, { sent = true, to = target.DisplayName or target.Name, count = packCount })
				ShopGift:FireClient(target, { from = player.DisplayName or player.Name, name = CASES[caseId].name, count = packCount })
				pushInv(target)
				pushShop(player)
				print(("[LobbyServer] %s gifted %dx %s to %s"):format(player.Name, packCount, caseId, target.Name))
				-- grant only when the BUYER's receipt is durable; recipient crates keep retrying via dirty
				if buyerSaved and recipientSaved then
					return Enum.ProductPurchaseDecision.PurchaseGranted
				end
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			-- recipient left mid-purchase: fall through — the buyer keeps the pack, no Robux lost
		end
		prof.cases[caseId] = (prof.cases[caseId] or 0) + packCount
		local result = doOpenCase(player, prof, caseId)
		result.chain = packCount - 1 -- the client reel auto-opens the rest from inventory
		saved = persist(player)
		CaseResult:FireClient(player, result)
	elseif bundle then
		prof.lobbyMoney += bundle.coins
		saved = persist(player)
		print(("[LobbyServer] %s bought a coin bundle: +%d"):format(player.Name, bundle.coins))
	elseif isStarter then
		if prof.starter then
			-- Somehow bought twice (should be hidden client-side): pay the coins again, never eat Robux.
			prof.lobbyMoney += SHOP.StarterCoins
		else
			prof.starter = true
			for cid, n in SHOP.StarterCases do
				prof.cases[cid] = (prof.cases[cid] or 0) + n
			end
			prof.lobbyMoney += SHOP.StarterCoins
		end
		saved = persist(player)
	elseif isWheel then
		-- CHANGED: enforce the paid-spin cap server-side (was buyable past MaxPaidSpins). On a fresh day
		-- the day-claim resets paid to 0 first, so day-one paid spins still work.
		wheelClaimDay(prof)
		if (prof.wheel.paid or 0) >= WHEEL.MaxPaidSpins then
			prof.lobbyMoney += 1000 -- over the daily cap: never eat Robux — pay a coin fallback instead
			saved = persist(player)
			WheelSpin:FireClient(player, { failed = true, msg = "DAILY RE-SPINS MAXED — REFUNDED 1,000 COINS" })
		else
			prof.wheel.paid = (prof.wheel.paid or 0) + 1
			local idx, rewardText = doWheelSpin(player, prof)
			saved = persist(player)
			WheelSpin:FireClient(player, { seg = idx, reward = rewardText, streak = prof.wheel.streak, paid = true })
		end
	end
	pushShop(player)
	pushInv(player)
	StatsRemote:FireClient(player, prof)
	if not saved then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- not durable yet — let Roblox retry
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ===== SQUADS (the top-center avatar party) ===== invite buddies from the chips row; the squad rides
-- ABOVE the pads: when the leader locks a run in on a pad (FinalizeParty), every member is summoned
-- onto that pad automatically and the normal pad flow takes them into the run together.
local SQUAD_MAX = 4
local squads = {} -- leaderUserId -> { leader = userId, members = { userId, ... } (leader included) }
local squadOf = {} -- userId -> leaderUserId
local squadInvites = {} -- targetUserId -> { from = userId, at = os.clock() } (one pending, 60s)
local SquadSync = mk("SquadSync") -- S->C: {members={{id,name,leader?}}} | {invite={id,name}} | {msg}
local SquadInvite = mk("SquadInvite") -- C->S: (targetUserId)
local SquadRespond = mk("SquadRespond") -- C->S: (true = accept, false = decline)
local SquadLeave = mk("SquadLeave") -- C->S: ()

local function squadPush(leaderId)
	local s = squads[leaderId]
	if not s then
		return
	end
	local payload = { members = {} }
	for _, uid in s.members do
		local pl = Players:GetPlayerByUserId(uid)
		table.insert(payload.members, {
			id = uid,
			name = pl and (pl.DisplayName or pl.Name) or "?",
			leader = (uid == s.leader) or nil,
		})
	end
	for _, uid in s.members do
		local pl = Players:GetPlayerByUserId(uid)
		if pl then
			SquadSync:FireClient(pl, payload)
		end
	end
end

local function squadRemove(player)
	squadInvites[player.UserId] = nil
	local lid = squadOf[player.UserId]
	if not lid then
		return
	end
	local s = squads[lid]
	squadOf[player.UserId] = nil
	if not s then
		return
	end
	for i = #s.members, 1, -1 do
		if s.members[i] == player.UserId then
			table.remove(s.members, i)
		end
	end
	if player.Parent then
		SquadSync:FireClient(player, { members = {} })
	end
	if #s.members <= 1 then -- a squad of one dissolves
		for _, uid in s.members do
			squadOf[uid] = nil
			local pl = Players:GetPlayerByUserId(uid)
			if pl then
				SquadSync:FireClient(pl, { members = {} })
			end
		end
		squads[lid] = nil
		return
	end
	if lid == player.UserId then -- the leader left: promote the first remaining member
		local newLead = s.members[1]
		s.leader = newLead
		squads[newLead] = s
		squads[lid] = nil
		for _, uid in s.members do
			squadOf[uid] = newLead
		end
	end
	squadPush(s.leader)
end

SquadInvite.OnServerEvent:Connect(function(player, targetId)
	if not allow(player, "Party") then
		return
	end
	targetId = math.floor(tonumber(targetId) or 0)
	local target = Players:GetPlayerByUserId(targetId)
	if not target or target == player then
		return
	end
	local lid = squadOf[player.UserId]
	local s = lid and squads[lid]
	if s and s.leader ~= player.UserId then
		SquadSync:FireClient(player, { msg = "ONLY THE LEADER CAN INVITE" })
		return
	end
	if s and #s.members >= SQUAD_MAX then
		SquadSync:FireClient(player, { msg = "SQUAD FULL (4 MAX)" })
		return
	end
	if squadOf[targetId] then
		SquadSync:FireClient(player, { msg = (target.DisplayName or target.Name):upper() .. " IS ALREADY IN A SQUAD" })
		return
	end
	local inv = squadInvites[targetId]
	if inv and os.clock() - inv.at < 60 then
		SquadSync:FireClient(player, { msg = "THEY ALREADY HAVE AN INVITE PENDING" })
		return
	end
	squadInvites[targetId] = { from = player.UserId, at = os.clock() }
	SquadSync:FireClient(target, { invite = { id = player.UserId, name = player.DisplayName or player.Name } })
	SquadSync:FireClient(player, { msg = "INVITE SENT TO " .. (target.DisplayName or target.Name):upper() })
end)

SquadRespond.OnServerEvent:Connect(function(player, accept)
	if not allow(player, "Party") then
		return
	end
	local inv = squadInvites[player.UserId]
	squadInvites[player.UserId] = nil
	if not inv or os.clock() - inv.at > 60 then
		return
	end
	local from = Players:GetPlayerByUserId(inv.from)
	if accept ~= true then
		if from then
			SquadSync:FireClient(from, { msg = (player.DisplayName or player.Name):upper() .. " DECLINED" })
		end
		return
	end
	if not from or squadOf[player.UserId] then
		return
	end
	local s = squads[squadOf[inv.from] or inv.from]
	if not s then -- inviter had no squad yet: this accept founds it
		s = { leader = inv.from, members = { inv.from } }
		squads[inv.from] = s
		squadOf[inv.from] = inv.from
	end
	if #s.members >= SQUAD_MAX then
		SquadSync:FireClient(player, { msg = "THAT SQUAD FILLED UP" })
		return
	end
	table.insert(s.members, player.UserId)
	squadOf[player.UserId] = s.leader
	squadPush(s.leader)
end)

SquadLeave.OnServerEvent:Connect(function(player)
	if not allow(player, "Party") then
		return
	end
	squadRemove(player)
end)

-- ===== PARTY PADS =====
-- parties[zonePart] = { state="config"|"open", host, map, difficulty, size, members={}, deadline, billboard }
local parties = {}
local playerParty = {}  -- userId -> party
local inZonePart = {}   -- userId -> zone Part they're standing in
local profileRetryAt = {} -- userId -> os.clock() before which we won't re-kick a stuck profile load
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

-- Flip a player's character between the normal player group and the wall-passing PartyMember group.
local function setPartyPassThrough(player, isMember)
	local char = player.Character
	if not char then
		return
	end
	local group = isMember and "PartyMember" or PLAYER_GROUP
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
end

-- The pad's forcefield fence: UP while the pad is being set up OR its party is full (a solo party is
-- full instantly, so nobody can join until the host leaves); DOWN when the party is open with room.
local WALL_HEIGHT = 14
local function updatePadWall(zone, party)
	local blocked = party ~= nil and (party.state == "config" or #party.members >= (party.size or 1))
	local wall = zone:FindFirstChild("PadWall")
	if not blocked then
		if wall then
			wall:Destroy()
		end
		return
	end
	if wall then
		return
	end
	wall = Instance.new("Model")
	wall.Name = "PadWall"
	local sx, sz = zone.Size.X, zone.Size.Z
	local y = zone.Size.Y * 0.5 + WALL_HEIGHT * 0.5
	local defs = {
		{ CFrame.new(0, y, -sz * 0.5 - 0.5), Vector3.new(sx + 2, WALL_HEIGHT, 1) },
		{ CFrame.new(0, y, sz * 0.5 + 0.5), Vector3.new(sx + 2, WALL_HEIGHT, 1) },
		{ CFrame.new(-sx * 0.5 - 0.5, y, 0), Vector3.new(1, WALL_HEIGHT, sz + 2) },
		{ CFrame.new(sx * 0.5 + 0.5, y, 0), Vector3.new(1, WALL_HEIGHT, sz + 2) },
	}
	for _, def in defs do
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.ForceField
		p.Color = Color3.fromRGB(255, 70, 70)
		p.Transparency = 0.25
		p.Size = def[2]
		p.CFrame = zone.CFrame * def[1]
		p.CollisionGroup = "PadWall"
		p.Parent = wall
	end
	wall.Parent = zone
end

local function updateBillboard(zone, party)
	updatePadWall(zone, party)
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
	setPartyPassThrough(player, false)
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
			setPartyPassThrough(pl, false)
			ZoneLeave:FireClient(pl)
		end
	end
	if #list == 0 then
		return
	end
	task.spawn(function()
		-- Save everyone BEFORE they leave so the game server loads their latest data. CHANGED: only
		-- teleport players whose save is CONFIRMED durable — the two places full-overwrite shared fields,
		-- so sending a player in on stale data ROLLS BACK their lobby progress. A failed save (rare, after
		-- 4 retries) holds that player in the lobby instead of risking a rollback.
		local safe = {}
		for _, pl in list do
			if persist(pl) then
				table.insert(safe, pl)
			else
				warn(("[LobbyServer] %s save failed pre-teleport — held in lobby (no rollback)"):format(pl.Name))
				if pl.Parent and profileCache[pl.UserId] then
					StatsRemote:FireClient(pl, profileCache[pl.UserId])
				end
			end
		end
		if #safe == 0 then
			return
		end
		local ok, code = pcall(function()
			return TeleportService:ReserveServer(GAME_PLACE_ID)
		end)
		local options = Instance.new("TeleportOptions")
		if ok and code then
			options.ReservedServerAccessCode = code
		end
		options:SetTeleportData({ startRun = true, map = party.map, difficulty = party.difficulty, partySize = #safe })
		for attempt = 1, TELEPORT_RETRIES do
			local alive = {}
			for _, pl in safe do
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
		-- A load that errored out would strand this player here forever — re-kick it (throttled).
		local nowT = os.clock()
		if nowT >= (profileRetryAt[player.UserId] or 0) then
			profileRetryAt[player.UserId] = nowT + 8
			warn(("[LobbyPads] %s has no profile yet — retrying the load"):format(player.Name))
			task.spawn(function()
				if not profileCache[player.UserId] and player.Parent then
					local profile = readProfile(player)
					if not profileCache[player.UserId] then
						profileCache[player.UserId] = profile
						StatsRemote:FireClient(player, profile)
						pushInv(player)
						refreshCarry(player)
						-- (no refreshPlayerTag here: it's declared later in the file, so this closure
						-- can't see it — the next respawn refreshes the tag anyway)
					end
				end
			end)
		end
		return
	end

	if not party then
		-- Empty pad: this player becomes the HOST and starts configuring.
		party = { zone = zone, state = "config", host = player, members = { player } }
		parties[zone] = party
		playerParty[player.UserId] = party
		setPartyPassThrough(player, true) -- BEFORE the wall goes up, so the host can step out to cancel
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
			setPartyPassThrough(player, true)
			updateBillboard(zone, party) -- joining the last open slot raises the wall behind them
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
	-- SQUAD: the leader locked in a run — make room and summon every member onto this pad. The normal
	-- zone tick adds them to the party (their own difficulty locks still apply).
	local s = squads[squadOf[player.UserId] or 0]
	if s and s.leader == player.UserId then
		party.size = math.clamp(math.max(party.size, #s.members), 1, 4)
		for _, uid in s.members do
			if uid ~= player.UserId then
				local pl = Players:GetPlayerByUserId(uid)
				local root = pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
				if root then
					root.CFrame = CFrame.new(party.zone.Position + Vector3.new(0, party.zone.Size.Y * 0.5 + 3.5, 0))
				end
			end
		end
	end
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

-- Nav PLAY button: step the player onto the best pad and let the normal pad flow take over.
-- Prefers the nearest EMPTY pad (they become the host + get the setup menu); if every pad is
-- busy, the nearest OPEN party with room (they join it). No pads placed = quietly does nothing.
mk("GoPlay").OnServerEvent:Connect(function(player)
	if not allow(player, "Party") then
		return
	end
	local pp = playerParty[player.UserId]
	if pp and parties[pp.zone] ~= pp then
		playerParty[player.UserId] = nil -- stale link to a dissolved party: clear it, PLAY works again
		setPartyPassThrough(player, false)
		pp = nil
	end
	if pp then
		return -- genuinely on a pad / in a party
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	refreshZones()
	local best, bestD
	for _, zone in zoneParts do
		if zone.Parent then
			local party = parties[zone]
			local usable = (party == nil) or (party.state == "open" and #party.members < party.size)
			if usable then
				local d = (zone.Position - root.Position).Magnitude
				if party == nil then
					d -= 100000 -- empty pads ALWAYS beat joinable parties (PLAY = set up your own run)
				end
				if not best or d < bestD then
					best, bestD = zone, d
				end
			end
		end
	end
	if best then
		root.CFrame = CFrame.new(best.Position + Vector3.new(0, best.Size.Y * 0.5 + 3.5, 0))
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
		title.Text = "EXCLUSIVE SHOP"
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
		-- Ghost-wall sweep: a pad with NO party must never keep a forcefield up (an orphaned wall
		-- physically blocks the party builder and reads as "pads are broken").
		for _, zone in zoneParts do
			if not parties[zone] then
				local ghost = zone:FindFirstChild("PadWall")
				if ghost then
					warn("[LobbyPads] destroyed an orphaned pad wall on " .. zone.Name)
					ghost:Destroy()
				end
			end
		end
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
			local okZ, errZ = pcall(evaluateZone, player, currentZone)
			if not okZ then
				warn("[LobbyPads] evaluateZone failed for " .. player.Name .. ": " .. tostring(errZ))
			end
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

-- ===== OVERHEAD TAG + LEADERBOARD ===== plain floating text over each player: "N WINS" (gold, top)
-- over "LVL n" (white) — no panel behind it — plus the WINS column on the Roblox leaderboard.
local function refreshPlayerTag(player)
	local prof = profileCache[player.UserId]
	if not prof then
		return
	end
	local wins = tonumber(prof.wins) or 0
	local lvl = accountLevel(prof.xp)
	local ls = player:FindFirstChild("leaderstats")
	local winsStat = ls and ls:FindFirstChild("Wins")
	if winsStat then
		winsStat.Value = wins
	end
	local char = player.Character
	local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
	if not head then
		return
	end
	local bb = head:FindFirstChild("PlayerTag")
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "PlayerTag"
		-- STUDS-based size: the tag scales with the character (zoom in = bigger, out = smaller).
		bb.Size = UDim2.new(6, 0, 1.5, 0)
		bb.StudsOffset = Vector3.new(0, 2.1, 0)
		bb.MaxDistance = 90
		bb.Parent = head
		local function line(name, yScale, hScale, color)
			local l = Instance.new("TextLabel")
			l.Name = name; l.Position = UDim2.fromScale(0, yScale); l.Size = UDim2.fromScale(1, hScale)
			l.BackgroundTransparency = 1
			l.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
			l.TextScaled = true; l.TextColor3 = color; l.Text = ""
			l.Parent = bb
			local st = Instance.new("UIStroke")
			st.Color = Color3.new(0, 0, 0); st.Thickness = 2
			st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; st.Parent = l
		end
		line("Wins", 0, 0.55, Color3.fromRGB(230, 180, 76))
		line("Level", 0.55, 0.45, Color3.fromRGB(255, 255, 255))
	end
	bb.Wins.Text = ("%d WINS"):format(wins)
	bb.Level.RichText = true
	bb.Level.Text = ("LVL %d"):format(lvl) .. (prof.vip and '  <font color="#E6B44C">VIP</font>' or "")
end

-- ===== VIP GAMEPASS ===== (id shared with the game's GameConfig.GamepassVIP). Benefits here:
-- the gold VIP tag + ONE free rare crate per day (vipDay in the profile).
local VIP_PASS_ID = 1906069123
local function primeVip(player)
	task.spawn(function()
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_PASS_ID)
		end)
		local prof = profileCache[player.UserId]
		if not ok or not owns or not prof then
			return
		end
		prof.vip = true -- runtime flag (ownership is re-checked every session)
		refreshPlayerTag(player)
		local today = todayStamp()
		if prof.vipDay ~= today and not prof.noPersist then
			prof.vipDay = today
			prof.cases.rare = (prof.cases.rare or 0) + 1
			markDirty(player)
			pushInv(player)
			ShopGift:FireClient(player, { from = "VIP DAILY", name = "Rare Skin Crate", count = 1 })
		end
	end)
end
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if purchased and passId == VIP_PASS_ID then
		primeVip(player) -- bought VIP right here in the lobby: benefits land instantly
	end
end)

-- ===== LIFECYCLE =====
local function onJoin(player)
	-- WINS on the Roblox leaderboard (filled in once the profile loads).
	local lstats = Instance.new("Folder")
	lstats.Name = "leaderstats"
	lstats.Parent = player
	local winsStat = Instance.new("IntValue")
	winsStat.Name = "Wins"
	winsStat.Parent = lstats
	player.CharacterAdded:Connect(function(character)
		setCollisionGroup(character)
		if playerParty[player.UserId] then
			setPartyPassThrough(player, true) -- respawned mid-party: keep passing through the pad wall
		end
		-- Cartoon BLACK OUTLINE, same as the game place.
		if not character:FindFirstChild("Outline") then
			local hl = Instance.new("Highlight")
			hl.Name = "Outline"
			hl.FillTransparency = 1
			hl.OutlineColor = Color3.new(0, 0, 0)
			hl.OutlineTransparency = 0
			hl.DepthMode = Enum.HighlightDepthMode.Occluded
			hl.Adornee = character
			hl.Parent = character
		end
		task.defer(refreshCarry, player)
		task.defer(refreshPlayerTag, player)
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
		refreshPlayerTag(player)
		primeVip(player)
		-- DAILY QUESTS: the game place teleports back with a SERVER-set run summary — feed it in.
		-- (GetJoinData's TeleportData comes from the sending server, not the client — trustable.)
		local okJD, jd = pcall(function()
			return player:GetJoinData()
		end)
		local sum = okJD and typeof(jd) == "table" and typeof(jd.TeleportData) == "table"
			and typeof(jd.TeleportData.summary) == "table" and jd.TeleportData.summary or nil
		if sum then
			bumpQuest(player, "kills", math.floor(tonumber(sum.kills) or 0))
			bumpQuest(player, "money", math.floor(tonumber(sum.money) or 0))
			bumpQuest(player, "wave", math.floor(tonumber(sum.wave) or 0))
			bumpQuest(player, "runs", 1)
			if sum.win == true then
				bumpQuest(player, "wins", 1)
			end
		end
		pushQuests(player)
	end)
end

Players.PlayerAdded:Connect(onJoin)
for _, pl in Players:GetPlayers() do
	onJoin(pl)
end
Players.PlayerRemoving:Connect(function(pl)
	removeFromParty(pl)
	squadRemove(pl) -- squads: drop them + promote a new leader if needed
	persist(pl) -- immediate write on leave (flushes anything the batch loop hasn't gotten to)
	profileCache[pl.UserId] = nil
	dirty[pl.UserId] = nil
	buckets[pl.UserId] = nil
	inZonePart[pl.UserId] = nil
	inShopZone[pl.UserId] = nil
	lastMode[pl.UserId] = nil
	pendingGift[pl.UserId] = nil -- FIX: gift arm-state was never cleared on leave (leak)
	squadInvites[pl.UserId] = nil
end)

-- ===== GLOBAL BEST-WAVE LEADERBOARD ===== the game place writes each new personal best to the
-- ZR_BestWave_v1 OrderedDataStore; here we read the top N + resolve names + tell each player their own
-- rank, and push it to clients (they render it on a board named "Leaderboard" and the run-summary card).
local LeaderboardSync = mk("LeaderboardSync") -- S->C: {top={{rank,name,wave}}, you={wave,rank}} · C->S: request
local LB_TOP = 25
local lbTop = {} -- cached ordered list of { rank, userId, name, wave }
local lbNameCache = {} -- userId -> name (GetNameFromUserIdAsync is throttle-prone; cache forever)

local function lbName(userId)
	if lbNameCache[userId] then
		return lbNameCache[userId]
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	name = (ok and name) or ("Player" .. userId)
	lbNameCache[userId] = name
	return name
end

local function refreshLeaderboard()
	local ok, pages = pcall(function()
		return bestWaveBoard:GetSortedAsync(false, LB_TOP) -- false = descending (highest wave first)
	end)
	if not ok or not pages then
		return
	end
	local page = pages:GetCurrentPage()
	local out = {}
	for i, entry in ipairs(page) do
		local uid = tonumber(entry.key) or 0
		table.insert(out, { rank = i, userId = uid, name = lbName(uid), wave = tonumber(entry.value) or 0 })
	end
	lbTop = out
end

local function pushLeaderboard(player)
	local prof = profileCache[player.UserId]
	local youWave = prof and tonumber(prof.bestWave) or 0
	local youRank -- exact only if they're on the visible top page; else nil ("out of top N")
	for _, e in lbTop do
		if e.userId == player.UserId then
			youRank = e.rank
		end
	end
	LeaderboardSync:FireClient(player, {
		top = (function()
			local t = {}
			for _, e in lbTop do
				table.insert(t, { rank = e.rank, name = e.name, wave = e.wave })
			end
			return t
		end)(),
		you = { wave = youWave, rank = youRank },
	})
end

LeaderboardSync.OnServerEvent:Connect(function(player)
	if not allow(player, "Inv") then
		return
	end
	pushLeaderboard(player)
end)

task.spawn(function()
	while true do
		refreshLeaderboard()
		for _, pl in Players:GetPlayers() do
			pushLeaderboard(pl)
		end
		task.wait(120) -- the board is global + slow-moving; a 2-minute refresh is plenty and DS-friendly
	end
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

-- DAILY QUESTS: claim one finished quest's coins. Clearing all 3 auto-pays the bonus crate.
QuestClaim.OnServerEvent:Connect(function(player, req)
	if not allow(player, "Buy") or typeof(req) ~= "table" then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	local defs = ensureQuests(player, prof)
	local q = prof.quests
	local i = math.floor(tonumber(req.i) or 0)
	local d = defs[i]
	if not d or q.claimed[i] or (q.prog[i] or 0) < d.goal then
		return
	end
	q.claimed[i] = true
	prof.lobbyMoney += d.coins or 0
	local all = true
	for k in defs do
		if not q.claimed[k] then
			all = false
		end
	end
	if all and not q.bonus then
		q.bonus = true
		prof.cases[QUESTS.BonusCase] = (prof.cases[QUESTS.BonusCase] or 0) + 1
		ShopGift:FireClient(player, {
			from = "DAILY QUESTS",
			name = QUESTS.BonusCase:sub(1, 1):upper() .. QUESTS.BonusCase:sub(2) .. " Skin Crate",
			count = 1,
		})
		pushInv(player)
	end
	markDirty(player)
	pushQuests(player)
	StatsRemote:FireClient(player, prof) -- the coins readout ticks up
end)

-- DAILY QUESTS: a fresh client asks for the board (same join-race fix as InvRequest).
QuestSync.OnServerEvent:Connect(function(player)
	if not allow(player, "Inv") then -- FIX: was the only C->S pull with no rate-limit gate
		return
	end
	pushQuests(player)
end)

-- CLASSES: equip a class from the showcase ("" clears it). The game place reads prof.class on load.
local ClassEquip = mk("ClassEquip")
ClassEquip.OnServerEvent:Connect(function(player, id)
	if not allow(player, "Buy") then
		return
	end
	id = tostring(id or "")
	if id ~= "" and not CLASS_IDS[id] then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	prof.class = id
	markDirty(player)
	StatsRemote:FireClient(player, prof) -- the showcase reads s.class for the EQUIPPED badge
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
