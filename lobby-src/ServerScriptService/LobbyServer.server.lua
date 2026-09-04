-- LobbyServer (LOBBY PLACE ONLY) — walkable hub with PARTY PADS + the inventory.
--
-- PARTY FLOW (one party per LoadingZone pad):
--   1. Player A steps on an empty pad -> becomes the HOST and gets the setup menu (Map / Size).
--      While A is setting up, the pad is LOCKED — anyone else stepping on is told to wait.
--   2. A presses PLAY -> settings are FINALIZED. A's menu collapses to just party info + a LEAVE button,
--      and a billboard above the pad shows the settings + player count + countdown.
--   3. Others step on the pad to JOIN — but only if they've UNLOCKED that map (otherwise they
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
local WORLDS             = { "forest", "islands" } -- ONE difficulty per world now (the old Easy..Endless
-- ladder is GONE); a world unlocks at an ACCOUNT LEVEL (below), and every run is endless + extraction.
local WORLD_UNLOCK_LEVEL = { forest = 0, islands = 8 } -- must mirror GameConfig.WorldUnlockLevel
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
	-- CHANGED: true — the wall now keeps party members IN (trapped until they press LEAVE), not just
	-- outsiders out. Members still don't collide with other players (rule below).
	PhysicsService:CollisionGroupSetCollidable("PadWall", "PartyMember", true)
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
-- CHANGED (owner call — skins DELETED): crates pay GUNS now. Guns ALSO auto-unlock free at account
-- level (readProfile's XP-ONLY UNLOCKS) — a crate is the way to pull one EARLY. Dupes pay coins.
-- CHANGED: mirrored the game's DPS-ladder retune (damage climbs with unlock level; Ray Gun is the
-- capstone again) + HONEST ranges (combat clamps to 60 — only shotgun 40 / flamethrower 38 differ).
local WEAPONS = {
	pistol    = { name = "M1911",        tier = 1, rarity = "common",    damage = 30,  fireRate = 5,   range = 60, price = 0, slot = "secondary" },
	revolver  = { name = "Revolver",     tier = 2, rarity = "uncommon",  damage = 90,  fireRate = 1.8, range = 60, price = 1500, slot = "secondary",
		ability = "PIERCE — rounds punch through up to 3 zombies in a line" },
	shotgun   = { name = "Pump Shotgun", tier = 2, rarity = "uncommon",  damage = 24,  fireRate = 1.2, range = 40, pellets = 6, price = 2500, slot = "primary" },
	ak47      = { name = "AK-47",        tier = 3, rarity = "rare",      damage = 26,  fireRate = 9,   range = 60, price = 6000, slot = "primary" },
	crossbow  = { name = "Crossbow",     tier = 3, rarity = "rare",      damage = 240, fireRate = 1.0, range = 60, price = 8000, slot = "primary",
		ability = "PIN — bolts nail zombies in place for 2s" },
	minigun   = { name = "Minigun",      tier = 4, rarity = "epic",      damage = 22,  fireRate = 18,  range = 60, price = 15000, slot = "primary" },
	freezeray = { name = "Freeze Ray",   tier = 4, rarity = "epic",      damage = 16,  fireRate = 10,  range = 60, price = 20000, slot = "primary",
		ability = "CRYO — freezes zombies SOLID in ice for 4s; frozen zombies SHATTER on death" },
	raygun    = { name = "Ray Gun",      tier = 5, rarity = "legendary", damage = 130, fireRate = 4,   range = 60, price = 40000, slot = "primary" },
	m4        = { name = "M4 Carbine",         tier = 3, rarity = "rare",      damage = 26,  fireRate = 11,  range = 60, price = 7000,  slot = "primary" },
	tommygun  = { name = "Tommy Gun",          tier = 2, rarity = "uncommon",  damage = 18,  fireRate = 12,  range = 60, price = 3500,  slot = "primary" },
	sniper    = { name = "Bolt-Action Sniper", tier = 4, rarity = "epic",      damage = 480, fireRate = 0.9, range = 60, price = 12000, slot = "primary",
		ability = "PIERCE — one shot punches through a whole line" },
	flamethrower = { name = "Flamethrower",    tier = 4, rarity = "epic",      damage = 9,   fireRate = 12,  range = 38, pellets = 3, price = 18000, slot = "primary",
		ability = "INFERNO — sprays a short cone of fire" },
	rocket    = { name = "Rocket Launcher",    tier = 5, rarity = "legendary", damage = 20,  fireRate = 0.7, range = 60, price = 35000, slot = "primary",
		ability = "EXPLOSIVE — the blast damages everything nearby" },
	plasma    = { name = "Plasma Rifle",       tier = 5, rarity = "legendary", damage = 78,  fireRate = 6,   range = 60, price = 30000, slot = "primary",
		ability = "PLASMA — bolts splash on impact" },
	honeybadger = { name = "Honey Badger",     tier = 3, rarity = "rare",      damage = 26,  fireRate = 10,  range = 60, price = 6500,  slot = "primary" },
	p90       = { name = "P90",                tier = 3, rarity = "rare",      damage = 24,  fireRate = 13,  range = 60, price = 5000,  slot = "primary" },
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

-- ===== GUN CATEGORY ===== which inventory bucket a gun lives in, shown as the LEVEL / CRATE / EVENT
-- sub-tabs on the WEAPONS screen. "level" = the coin ladder (level-gated); "crate" = pulled from crates;
-- "event" = limited-time. Add an id here to move it out of Level; anything unlisted defaults to "level".
local WEAPON_SOURCE = {
	-- examples (uncomment / edit to taste):
	-- raygun = "crate", plasma = "crate",
	-- rocket = "event",
}
for id, w in WEAPONS do
	w.source = WEAPON_SOURCE[id] or "level"
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

-- (SKINS DELETED — owner call. Crates pay GUNS; old profiles' skins data is ignored and dropped
-- from the save on next persist. The game place's skin rendering was stripped in the same pass.)

-- 7 rarity-tiered GUN crates (wave rewards + starter grants + the shop).
-- PHOTOS: add image = "rbxassetid://..." to any CASES entry (and to WEAPONS entries) and the
-- inventory/shop UI shows the picture on cards + detail panes automatically.
-- A pull rolls a GUN RARITY from gunWeights, then a uniform gun of that rarity: unowned = THE GUN IS
-- YOURS (early — level would have granted it free eventually); owned = coins (GUN_DUP_COINS).
-- (common is left out of the pools: the pistol is everyone's free starter — it'd always be a dupe.)
local CASES = {
	common    = { gunWeights = { uncommon = 55, rare = 30, epic = 12, legendary = 3 } },
	uncommon  = { gunWeights = { uncommon = 45, rare = 34, epic = 16, legendary = 5 } },
	rare      = { gunWeights = { uncommon = 32, rare = 38, epic = 22, legendary = 8 } },
	epic      = { gunWeights = { uncommon = 20, rare = 38, epic = 30, legendary = 12 } },
	legendary = { gunWeights = { uncommon = 10, rare = 32, epic = 38, legendary = 20 } },
	mythic    = { gunWeights = { uncommon = 5,  rare = 25, epic = 42, legendary = 28 } },
	divine    = { gunWeights = { uncommon = 2,  rare = 16, epic = 44, legendary = 38 } },
}
for rarity, c in CASES do
	c.name = RARITY[rarity].name .. " Gun Crate"
end
-- The featured EXCLUSIVE PACK (Robux): same gun-crate roll, but it PREFERS a gun you DON'T own yet
-- (a paid pack must never feel like a dupe); own them all and it pays big dupe coins instead.
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
-- CHANGED: dupe refunds cut way down — crates were a coin PRINTER (expected dupe value beat the
-- crate price). Refunds must stay well below crate cost so opening is a gamble, not an ATM.
local GUN_DUP_COINS = { common = 40, uncommon = 60, rare = 120, epic = 250, legendary = 500 }

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
	-- CHANGED: coin price per case rarity — raised so a crate always costs MORE than its expected
	-- dupe refund (all-dupe EV on a common crate is ~114 coins vs the old 100-coin price).
	Prices = { common = 400, uncommon = 650, rare = 1000, epic = 1600, legendary = 2500, mythic = 4000, divine = 6500 },
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
	PackProducts = { [1] = 0, [3] = 0, [10] = 0 }, -- (legacy gacha ids; unused now the pack is a bundle)
	-- CHANGED (owner request): the EXCLUSIVE PACK is a FIXED bundle, not a gacha. One Robux purchase
	-- grants ALL of `guns` (each: unowned = you get it; already-owned = paid out as coins) plus `coins`.
	-- Create ONE Developer Product in Creator Hub and paste its id as productId (0 = "coming soon").
	ExclusivePack = {
		productId = 0,
		guns = { "freezeray", "plasma" },
		coins = 25000,
	},

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
	-- PITY: a LEGENDARY gun is guaranteed within this many RARITY-crate opens. (gunpack opens are
	-- excluded on purpose — the featured pack rolls its own fixed table and neither feeds nor resets
	-- the meter.)
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
		{ kind = "coins", amount = 1500, weight = 8, label = "1500 COINS" }, -- (was the RANDOM SKIN slice)
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

-- Display catalog the client renders from. Every crate's reel pool is the GUN list now.
local CATALOG = {
	rarities = RARITY,
	rarityOrder = RARITY_ORDER,
	weapons = WEAPONS,
	cases = (function()
		local t = {}
		local gunIds = {}
		for id in WEAPONS do
			table.insert(gunIds, id)
		end
		table.sort(gunIds)
		for caseId, c in CASES do
			local gw = c.gunWeights
			local total = 0
			for _, weight in gw do
				total += weight
			end
			local odds, loot = {}, {} -- "WHAT'S INSIDE": gun-rarity rows with live percentages
			for _, rid in RARITY_ORDER do
				if gw[rid] then
					table.insert(odds, { rarity = rid, pct = (gw[rid] / total) * 100 })
					table.insert(loot, { kind = "guns", rarity = rid, pct = (gw[rid] / total) * 100 })
				end
			end
			t[caseId] = {
				name = c.name,
				rarity = (caseId == "gunpack") and "legendary" or caseId,
				poolIds = table.clone(gunIds),
				odds = odds,
				loot = loot,
				image = c.image,
			}
		end
		return t
	end)(),
}

-- Roll a crate: gun RARITY from the crate's weights, then a uniform gun of that rarity.
local function rollCase(caseId)
	local case = CASES[caseId]
	local total = 0
	for _, weight in case.gunWeights do
		total += weight
	end
	local r = rng:NextNumber(0, total)
	local acc, chosen = 0, nil
	for _, rid in RARITY_ORDER do
		if case.gunWeights[rid] then
			acc += case.gunWeights[rid]
			if r <= acc then
				chosen = rid
				break
			end
		end
	end
	local list = GUNS_BY_RARITY[chosen or "rare"] or GUNS_BY_RARITY.rare
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
local FinalizeParty = mk("FinalizeParty") -- C->S: {map, size} host locks in the settings
local LeaveParty    = mk("LeaveParty")    -- C->S: leave the party (moves you off the pad)
local PartyStatus   = mk("PartyStatus")   -- S->C: {map, size, count, seconds} live party state
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
local PackGranted   = mk("PackGranted")   -- S->C: {guns={{id,unlocked}}, coins, dupeCoins} exclusive-bundle receipt
                                          -- S->C: {sent,to,count} buyer confirm | {from,name,count} recipient toast
local WheelSpin     = mk("WheelSpin")     -- C->S: (no args) claim the FREE daily spin
                                          -- S->C: {seg, reward, streak} result | {failed, msg}
local ShopTicker    = mk("ShopTicker")    -- S->C broadcast: {name, item, rarity} someone pulled legendary+
-- Guns
local BuyGun    = mk("BuyGun")    -- C->S: {weaponId} buy a gun outright with Coins
-- Sound
local SetSoundSettings = mk("SetSoundSettings") -- C->S: ({master, music, sfx} 0..1) persist volume sliders

-- ===== LAUNCH PASS (policy / analytics / badges / run recap) =====
-- ONE table for all of it so this file stays under Luau's 200-local ceiling. Functions that need
-- later locals (pushShop, markDirty) are attached further down in the LAUNCH (late) block.
local LAUNCH = {
	-- BADGES: create them in Creator Hub -> your experience -> Badges and paste the ids (0 = skipped).
	-- The game place's wave/event badges live in GameConfig.BadgeIds.
	Badges = { raygun = 0, firstcrate = 0 },
	-- ONBOARDING funnel steps. MUST match the game place's TelemetryService.Onboard numbers (it logs
	-- 4/5/6/8/9 for the in-run steps).
	Onboard = { LobbyJoined = 1, TutorialDone = 2, RunLaunched = 3, FirstCrate = 7 },
	OnboardNames = { [1] = "lobby_joined", [2] = "tutorial_done", [3] = "run_launched", [7] = "first_crate" },
	Analytics = true,      -- false = drop every analytics event (nothing else changes)
	Policy = game:GetService("PolicyService"),
	AnalyticsSvc = game:GetService("AnalyticsService"),
	BadgeSvc = game:GetService("BadgeService"),
	restricted = {},       -- userId -> true when Roblox policy bars PAID RANDOM ITEMS for this player
	badgeDone = {},        -- userId -> { key = true } (one API round-trip per badge per session)
	budget = {},           -- analytics: per-player events this minute
	serverBudget = { n = 0, at = 0 },
	recap = {},            -- userId -> last run's recap payload (re-sent when the client asks)
}
LAUNCH.RunRecap = mk("RunRecap") -- S->C: {id, wave, kills, money, newBest, best} · C->S: (please re-send)

-- Custom-field keys: Roblox wants the enum's .Name ("customField01".."03"); literals as a fallback.
LAUNCH.fieldKeys = { "customField01", "customField02", "customField03" }
pcall(function()
	LAUNCH.fieldKeys[1] = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
	LAUNCH.fieldKeys[2] = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
	LAUNCH.fieldKeys[3] = Enum.AnalyticsCustomFieldKeys.CustomField03.Name
end)
function LAUNCH.fields(a, b, c)
	if a == nil and b == nil and c == nil then
		return nil
	end
	local t = {}
	if a ~= nil then t[LAUNCH.fieldKeys[1]] = tostring(a) end
	if b ~= nil then t[LAUNCH.fieldKeys[2]] = tostring(b) end
	if c ~= nil then t[LAUNCH.fieldKeys[3]] = tostring(c) end
	return t
end

-- Analytics budget: 30 events / player / minute, 110 / server / minute (Roblox throttles ~120).
-- A dropped analytics event must never cost gameplay, so overflow is silent.
function LAUNCH.allowEvent(player)
	local now = os.clock()
	if now - LAUNCH.serverBudget.at >= 60 then
		LAUNCH.serverBudget.n, LAUNCH.serverBudget.at = 0, now
	end
	local pb = LAUNCH.budget[player.UserId]
	if not pb then
		pb = { n = 0, at = now }
		LAUNCH.budget[player.UserId] = pb
	elseif now - pb.at >= 60 then
		pb.n, pb.at = 0, now
	end
	if LAUNCH.serverBudget.n >= 110 or pb.n >= 30 then
		return false
	end
	LAUNCH.serverBudget.n += 1
	pb.n += 1
	return true
end
function LAUNCH.send(player, what, fn)
	if not LAUNCH.Analytics or typeof(player) ~= "Instance" or not player.Parent or not LAUNCH.allowEvent(player) then
		return
	end
	task.spawn(function()
		local ok, err = pcall(fn)
		if not ok then
			warn(("[LobbyServer] analytics %s failed: %s"):format(what, tostring(err)))
		end
	end)
end
-- Onboarding funnel step (see LAUNCH.Onboard). Roblox counts each step once per player.
function LAUNCH.onboarding(player, step, f1)
	local name = LAUNCH.OnboardNames[step] or ("step_" .. tostring(step))
	LAUNCH.send(player, "onboarding " .. name, function()
		LAUNCH.AnalyticsSvc:LogOnboardingFunnelStepEvent(player, step, name, LAUNCH.fields(f1))
	end)
end
-- Coins in/out. flow = "Source" | "Sink"; txType = "IAP" | "TimedReward" | "Shop" | "Gameplay" | "Onboarding".
function LAUNCH.economy(player, flow, amount, balance, txType, sku, f1)
	amount = math.floor(tonumber(amount) or 0)
	if amount < 1 then
		return
	end
	balance = math.max(0, math.floor(tonumber(balance) or 0))
	LAUNCH.send(player, "economy " .. flow .. "/" .. tostring(sku), function()
		local flowEnum = (flow == "Sink") and Enum.AnalyticsEconomyFlowType.Sink or Enum.AnalyticsEconomyFlowType.Source
		local txEnum = Enum.AnalyticsEconomyTransactionType[txType] or Enum.AnalyticsEconomyTransactionType.Gameplay
		LAUNCH.AnalyticsSvc:LogEconomyEvent(player, flowEnum, "Coins", amount, balance, txEnum.Name, sku, LAUNCH.fields(f1))
	end)
end
function LAUNCH.custom(player, name, value, f1, f2, f3)
	LAUNCH.send(player, "custom " .. name, function()
		LAUNCH.AnalyticsSvc:LogCustomEvent(player, name, value, LAUNCH.fields(f1, f2, f3))
	end)
end

-- Award badge `key` (LAUNCH.Badges) — idempotent per session, pcall'd, off-thread.
function LAUNCH.badge(player, key)
	local id = tonumber(LAUNCH.Badges[key]) or 0
	if id <= 0 or typeof(player) ~= "Instance" then
		return
	end
	local uid = player.UserId
	local mine = LAUNCH.badgeDone[uid]
	if not mine then
		mine = {}
		LAUNCH.badgeDone[uid] = mine
	end
	if mine[key] then
		return
	end
	mine[key] = true
	task.spawn(function()
		local okHas, owned = pcall(LAUNCH.BadgeSvc.UserHasBadgeAsync, LAUNCH.BadgeSvc, uid, id)
		if okHas and owned == true then
			return
		end
		local ok, err = pcall(LAUNCH.BadgeSvc.AwardBadge, LAUNCH.BadgeSvc, uid, id)
		if not ok then
			mine[key] = nil
			warn(("[LobbyServer] badge %s for %s failed: %s"):format(key, player.Name, tostring(err)))
		end
	end)
end

-- PAID RANDOM ITEMS (Roblox policy): a player PolicyService flags must not be offered random-reward
-- purchases — here that's the paid wheel re-spin, the legacy Robux crate packs, the Starter Pack's
-- crates and the VIP daily crate. nil (not fetched yet) reads as restricted: fail closed.
function LAUNCH.isRestricted(player)
	local r = LAUNCH.restricted[player.UserId]
	if r == nil then
		return true
	end
	return r
end
-- Block (up to `secs`) until the policy fetch for this player has landed — receipts and the VIP prime
-- can run before it does.
function LAUNCH.waitPolicy(player, secs)
	local deadline = os.clock() + (secs or 6)
	while LAUNCH.restricted[player.UserId] == nil and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return LAUNCH.isRestricted(player)
end
-- What a crate is worth in Coins when policy forbids handing the crate itself over (its shop price).
function LAUNCH.caseCoinValue(caseId)
	return (typeof(SHOP.Prices) == "table" and tonumber(SHOP.Prices[caseId])) or 1000
end
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
		settings = sanitizeSettings(data.settings),
		titlesOwned = (typeof(data.titlesOwned) == "table") and data.titlesOwned or {}, -- GAME-owned (read-only here)
		titleEquipped = tostring(data.titleEquipped or ""), -- OURS: picked on the classes showcase
		-- NEW: server-stamped last-run summary (GAME-owned) + the id we last fed into quests (OURS).
		-- Quests consume THIS instead of TeleportData — teleport payloads are client-spoofable.
		pendingRunSummary = (typeof(data.pendingRunSummary) == "table") and data.pendingRunSummary or nil,
		lastRunSummaryId = tostring(data.lastRunSummaryId or ""),
		class = CLASS_IDS[tostring(data.class)] and tostring(data.class) or "", -- equipped class (showcase)
		pity = math.max(0, math.floor(tonumber(data.pity) or 0)), -- crate opens since the last legendary+ pull
		starter = data.starter == true, -- STARTER PACK is one purchase ever
		tutDone = data.tutDone == true, -- first-join pointer tour already shown (once per account)
		onboard = (typeof(data.onboard) == "table") and data.onboard or {}, -- launch pass: once-per-account funnel flags (crate)
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
				old.skins = nil -- SKINS DELETED: scrub the dead blob from the save
				old.titleEquipped = prof.titleEquipped -- (titlesOwned is GAME-owned: never written here)
				old.lastRunSummaryId = prof.lastRunSummaryId -- quest-feed dedup (pendingRunSummary is GAME-owned)
				old.settings = prof.settings
				old.redeemed = prof.redeemed
				old.receipts = prof.receipts
				old.pity = prof.pity
				old.starter = prof.starter
				old.wheel = prof.wheel
				old.vipDay = prof.vipDay
				old.quests = prof.quests
				old.class = prof.class
				old.tutDone = prof.tutDone
				old.onboard = prof.onboard -- launch pass: onboarding-funnel flags
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
	local template = carryTemplates[weaponId]
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

-- Worlds gate by ACCOUNT LEVEL now (no more "beat Nightmare" chains). One difficulty per world.
local function worldUnlocked(prof, world)
	if ALL_WORLDS_OPEN then
		return true
	end
	if not indexOf(WORLDS, world) then
		return false
	end
	local need = WORLD_UNLOCK_LEVEL[world] or 0
	return accountLevel((typeof(prof) == "table" and tonumber(prof.xp)) or 0) >= need
end

local function unlockPayload(profile)
	local worlds = {}
	for _, w in WORLDS do
		worlds[w] = { unlocked = worldUnlocked(profile, w), level = WORLD_UNLOCK_LEVEL[w] or 0 }
	end
	return { worldOrder = WORLDS, worlds = worlds }
end

-- ===== RATE LIMITING (token buckets — the lobby's SecurityService-lite) =====
-- Every C->S remote passes through allow() so a spamming client burns its bucket, not the DataStore.
-- CHANGED: Case 2 -> 6. OPEN ALL fast-forwards a crate per CaseResult round-trip (~5+/s on a good
-- connection) and the old 2/s bucket reliably aborted big batches mid-chain. Opening is server-
-- authoritative and cheap — the limiter only needs to stop a hammering loop, not honest speed.
local RATE = { Inv = 2, Equip = 4, Case = 6, Party = 3, Shop = 4, Settings = 3, Buy = 3 } -- refill/second (burst = 2s worth)
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

-- Grant a rolled gun: first pull OWNS it (early — level would have granted it free eventually) and
-- auto-fills an empty loadout slot; a duplicate converts straight to Coins by gun rarity.
local function grantRolledGun(player, prof, caseId, wonGun)
	if not table.find(prof.ownedWeapons, wonGun) then
		table.insert(prof.ownedWeapons, wonGun)
		prof.gunLevels[wonGun] = prof.gunLevels[wonGun] or 1
		local sl = slotFor(wonGun)
		if not prof.loadout[sl] then
			prof.loadout[sl] = wonGun
			refreshCarry(player)
		end
		local wr = WEAPONS[wonGun].rarity
		if wonGun == "raygun" then
			LAUNCH.badge(player, "raygun") -- the wonder weapon, pulled early
		end
		if wr == "legendary" then
			-- the live pull TICKER: brag about big pulls to the whole server. CHANGED: legendary ONLY —
			-- epics are up to ~44% of crate weights, and a ticker that fires constantly brags about nothing.
			ShopTicker:FireAllClients({ name = player.DisplayName or player.Name, item = WEAPONS[wonGun].name, rarity = wr })
		end
		return { caseId = caseId, wonId = wonGun, coins = 0, unlocked = true }
	end
	local c = GUN_DUP_COINS[WEAPONS[wonGun].rarity] or 500
	prof.lobbyMoney += c
	return { caseId = caseId, wonId = wonGun, coins = c, unlocked = false, maxed = true }
end

-- Consume one case (caller has already verified the player HAS one) and roll a GUN. Shared with
-- BUY & OPEN. PITY: at PityEvery-1 opens without a legendary, the open is FORCED to legendary.
local function doOpenCase(player, prof, caseId)
	prof.cases[caseId] = (prof.cases[caseId] or 0) - 1
	if prof.cases[caseId] <= 0 then
		prof.cases[caseId] = nil
	end
	-- THE GUN PACK (the featured Robux pack): PREFERS a gun you don't own (a paid pack must never
	-- feel like a dupe) — prefers the rolled rarity, falls back to any unowned gun, then dupe coins.
	-- Skips the pity counter entirely.
	if caseId == "gunpack" then
		local chosen = "rare"
		do
			local gw = CASES.gunpack.gunWeights
			local total = 0
			for _, weight in gw do
				total += weight
			end
			local r = rng:NextNumber(0, total)
			local acc = 0
			for _, rid in RARITY_ORDER do
				if gw[rid] then
					acc += gw[rid]
					if r <= acc then
						chosen = rid
						break
					end
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
		local wonGun
		if #pool > 0 then
			wonGun = pool[rng:NextInteger(1, #pool)]
		else
			local list = GUNS_BY_RARITY[chosen] or GUNS_BY_RARITY.rare
			wonGun = list[rng:NextInteger(1, #list)]
		end
		return grantRolledGun(player, prof, caseId, wonGun)
	end
	-- Regular crates: pity-forced legendary, else the crate's weighted roll.
	local wonGun
	if (prof.pity or 0) >= SHOP.PityEvery - 1 then
		local list = GUNS_BY_RARITY.legendary
		wonGun = list[rng:NextInteger(1, #list)]
	else
		wonGun = rollCase(caseId)
	end
	if WEAPONS[wonGun].rarity == "legendary" then
		prof.pity = 0
	else
		prof.pity = (prof.pity or 0) + 1
	end
	return grantRolledGun(player, prof, caseId, wonGun)
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
	LAUNCH.onCrate(player, prof, caseId, result)
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
		-- The featured EXCLUSIVE PACK — a FIXED Robux BUNDLE (guns + coins), one purchase, no gacha.
		pack = {
			kind = "bundle",
			name = "EXCLUSIVE GUN PACK",
			productId = SHOP.ExclusivePack.productId,
			robux = productPrice(SHOP.ExclusivePack.productId),
			coins = SHOP.ExclusivePack.coins,
			guns = (function()
				local g = {}
				for _, gid in SHOP.ExclusivePack.guns do
					if WEAPONS[gid] then
						table.insert(g, {
							id = gid, name = WEAPONS[gid].name, rarity = WEAPONS[gid].rarity,
							owned = table.find(prof.ownedWeapons, gid) ~= nil,
						})
					end
				end
				return g
			end)(),
		},
		-- PITY meter: opens left until the guaranteed legendary+.
		pityLeft = math.max(1, SHOP.PityEvery - (prof.pity or 0)),
		-- PAID RANDOM ITEMS policy (launch pass): true = hide the paid re-spin + starter-pack prompts.
		-- nil (policy not fetched yet) reads as restricted; fetchPolicy re-pushes the shop when it lands.
		restricted = prof.restricted ~= false,
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
	if LAUNCH.isRestricted(player) then
		return fail() -- PAID RANDOM ITEMS restricted for this player (Coins are Robux-purchasable)
	end
	-- BUY ALL: sweep every slot's remaining stock cheapest-first until the coins run out.
	if req.all == true then
		local shop = ensureShopState(prof)
		local coinsBefore = prof.lobbyMoney
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
		LAUNCH.economy(player, "Sink", coinsBefore - prof.lobbyMoney, prof.lobbyMoney, "Shop", "crate_all")
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
	LAUNCH.economy(player, "Sink", slot.price * n, prof.lobbyMoney, "Shop", "crate_" .. tostring(slot.caseId))
	local result = nil
	if wantOpen then
		result = doOpenCase(player, prof, slot.caseId)
		bumpQuest(player, "crates", 1)
		LAUNCH.onCrate(player, prof, slot.caseId, result)
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
		LAUNCH.economy(player, "Source", def.coins, prof.lobbyMoney, "Onboarding", "code_" .. clean)
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

-- ===== LAUNCH PASS (late: needs pushShop / markDirty / pushInv above) =====
-- Fetch the player's policy once per session (3 tries, then restricted), mirror it onto the profile
-- (shopSnapshot reads prof.restricted) + a player attribute, and refresh an open shop panel.
function LAUNCH.fetchPolicy(player)
	local restricted = true
	for attempt = 1, 3 do
		local ok, info = pcall(LAUNCH.Policy.GetPolicyInfoForPlayerAsync, LAUNCH.Policy, player)
		if ok and typeof(info) == "table" then
			restricted = info.ArePaidRandomItemsRestricted == true
			break
		end
		if not player.Parent then
			return
		end
		task.wait(attempt)
	end
	if not player.Parent then
		return
	end
	LAUNCH.restricted[player.UserId] = restricted
	local prof = profileCache[player.UserId]
	if prof then
		prof.restricted = restricted
	end
	player:SetAttribute("PaidRandomRestricted", restricted or nil)
	pushShop(player) -- an already-open panel picks up the real flag (it defaulted to restricted)
end

-- Every crate open funnels through here: first-crate badge + onboarding step (once per account),
-- the "crate_open" analytics event, and dupe coins as an economy Source.
function LAUNCH.onCrate(player, prof, caseId, result)
	prof.onboard = (typeof(prof.onboard) == "table") and prof.onboard or {}
	if not prof.onboard.crate then
		prof.onboard.crate = true
		markDirty(player)
		LAUNCH.onboarding(player, LAUNCH.Onboard.FirstCrate, caseId)
	end
	LAUNCH.badge(player, "firstcrate")
	local won = result and result.wonId
	local rarity = won and WEAPONS[won] and WEAPONS[won].rarity or "?"
	LAUNCH.custom(player, "crate_open", 1, caseId, rarity, (result and result.unlocked) and "new" or "dupe")
	if result and (tonumber(result.coins) or 0) > 0 then
		LAUNCH.economy(player, "Source", result.coins, prof.lobbyMoney, "Gameplay", "dupe_" .. tostring(rarity))
	end
end

-- The client asks for the recap once its UI is up (the join-time push can beat the client script).
LAUNCH.RunRecap.OnServerEvent:Connect(function(player)
	local r = LAUNCH.recap[player.UserId]
	if r then
		LAUNCH.RunRecap:FireClient(player, r)
	end
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
	else -- crate
		prof.cases[seg.case] = (prof.cases[seg.case] or 0) + 1
		rewardText = "+1 " .. CASES[seg.case].name:upper()
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
		-- CHANGED: reply instead of a silent drop — a rate-limited SPIN FREE tap left the client
		-- staring at a wheel that never moved.
		return WheelSpin:FireClient(player, { failed = true, msg = "SLOW DOWN — TRY AGAIN" })
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
	do
		local seg = WHEEL.Segments[idx]
		if seg and seg.kind == "coins" then
			LAUNCH.economy(player, "Source", seg.amount, prof.lobbyMoney, "TimedReward", "wheel_free")
		end
	end
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
	local isExclusive = SHOP.ExclusivePack.productId ~= 0 and pid == SHOP.ExclusivePack.productId
	if not (packCount or bundle or isStarter or isWheel or isExclusive) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	prof.receipts = prof.receipts or {}
	if table.find(prof.receipts, receiptInfo.PurchaseId) then
		-- CHANGED: a retry of an already-recorded receipt must still CONFIRM durability. The first
		-- attempt may have granted in memory but failed its write — answering PurchaseGranted off the
		-- in-memory id alone could burn the Robux on a crash. Re-persist, then grant.
		if persist(player) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	table.insert(prof.receipts, receiptInfo.PurchaseId)
	if #prof.receipts > 200 then -- CHANGED: 50 was too small; an evicted id lets a slow retry double-grant
		table.remove(prof.receipts, 1)
	end

	-- PAID RANDOM ITEMS policy (launch pass): the prompts are hidden for restricted players, but a
	-- receipt can still land (retry from an older session, a modified client). Never eat the Robux —
	-- convert the random reward into its Coin value: crate packs -> coins, paid re-spin -> 1,000 coins,
	-- the Starter Pack's crates -> their shop price (handled in the starter branch).
	local restricted = LAUNCH.waitPolicy(player, 6)
	if restricted and packCount then
		bundle = { coins = LAUNCH.caseCoinValue("rare") * packCount, fallback = "pack" }
		packCount = nil
	elseif restricted and isWheel then
		bundle = { coins = 1000, fallback = "wheel" }
		isWheel = false
	end
	if bundle and bundle.fallback == "wheel" then
		WheelSpin:FireClient(player, { failed = true, msg = ("RE-SPINS AREN'T AVAILABLE IN YOUR REGION — PAID %d COINS INSTEAD"):format(bundle.coins) })
	elseif bundle and bundle.fallback == "pack" then
		ShopGift:FireClient(player, { from = "SHOP", name = ("%d Coins (crates aren't available in your region)"):format(bundle.coins), count = 1 })
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
	elseif isExclusive then
		-- FIXED BUNDLE: grant each gun (unowned = you get it; owned = paid out as coins) + the coin lump.
		local granted, dupeCoins = {}, 0
		for _, gid in SHOP.ExclusivePack.guns do
			if WEAPONS[gid] then
				local owned = table.find(prof.ownedWeapons, gid) ~= nil
				if owned then
					local c = GUN_DUP_COINS[WEAPONS[gid].rarity] or 500
					dupeCoins += c
					prof.lobbyMoney += c
				else
					table.insert(prof.ownedWeapons, gid)
					prof.gunLevels[gid] = prof.gunLevels[gid] or 1
					local sl = slotFor(gid)
					if not prof.loadout[sl] then
						prof.loadout[sl] = gid
						refreshCarry(player)
					end
				end
				table.insert(granted, { id = gid, unlocked = not owned })
			end
		end
		prof.lobbyMoney += SHOP.ExclusivePack.coins
		LAUNCH.economy(player, "Source", SHOP.ExclusivePack.coins + dupeCoins, prof.lobbyMoney, "IAP", "exclusive_pack")
		saved = persist(player)
		PackGranted:FireClient(player, { guns = granted, coins = SHOP.ExclusivePack.coins, dupeCoins = dupeCoins })
		print(("[LobbyServer] %s bought the exclusive bundle (+%d coins, %d dupe coins)"):format(player.Name, SHOP.ExclusivePack.coins, dupeCoins))
	elseif bundle then
		prof.lobbyMoney += bundle.coins
		LAUNCH.economy(player, "Source", bundle.coins, prof.lobbyMoney, "IAP", bundle.fallback and ("fallback_" .. bundle.fallback) or ("bundle_" .. tostring(bundle.coins)))
		saved = persist(player)
		print(("[LobbyServer] %s bought a coin bundle: +%d"):format(player.Name, bundle.coins))
	elseif isStarter then
		if prof.starter then
			-- Somehow bought twice (should be hidden client-side): pay the coins again, never eat Robux.
			prof.lobbyMoney += SHOP.StarterCoins
		else
			prof.starter = true
			for cid, n in SHOP.StarterCases do
				if restricted then
					prof.lobbyMoney += LAUNCH.caseCoinValue(cid) * n -- policy: the crates' Coin value instead
				else
					prof.cases[cid] = (prof.cases[cid] or 0) + n
				end
			end
			prof.lobbyMoney += SHOP.StarterCoins
		end
		LAUNCH.economy(player, "Source", SHOP.StarterCoins, prof.lobbyMoney, "IAP", "starter")
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
			do
				local seg = WHEEL.Segments[idx]
				if seg and seg.kind == "coins" then
					LAUNCH.economy(player, "Source", seg.amount, prof.lobbyMoney, "IAP", "wheel_paid")
				end
			end
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
-- parties[zonePart] = { state="config"|"open", host, map, size, members={}, deadline, billboard }
local parties = {}
local playerParty = {}  -- userId -> party
local inZonePart = {}   -- userId -> zone Part they're standing in
local profileRetryAt = {} -- userId -> os.clock() before which we won't re-kick a stuck profile load
local lastMode = {}     -- userId -> last ZoneEnter signature sent (avoids respamming the client)

local zoneParts = {}
local shopZoneParts = {} -- Parts named "ShopZone..." — walk on one to browse the shop
local lastZoneScan = -math.huge
-- PERSISTENT sign over every LoadingZone pad so players know what it is BEFORE stepping on. Owner can
-- override the wording per-pad with a "Label" and/or "Sub" string Attribute on the zone Part; otherwise
-- it reads "START A RUN" / "STEP ON TO PLAY". Built once, never rebuilt.
local function ensureZoneTitle(zone)
	if zone:FindFirstChild("ZoneTitle") then
		return
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "ZoneTitle"
	-- CHANGED: WORLD-scaled (studs, not pixels) so distant pads' signs shrink with perspective —
	-- fixed-pixel signs all rendered full-size on top of each other from across the lobby (the
	-- "STEP ON TO PLAYSTEP ON TO PLAY" pileup on phones). Nearer cutoff for the same reason.
	bb.Size = UDim2.new(10, 0, 2.4, 0)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 90
	bb.Parent = zone
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.fromScale(0.5, 0.66)
	title.Size = UDim2.fromScale(1, 0.62)
	title.BackgroundTransparency = 1
	title.FontFace = BB_TITLE
	title.TextScaled = true -- studs-based billboard: text follows the sign's world size
	title.TextColor3 = BB_GOLD
	title.Text = tostring(zone:GetAttribute("Label") or "0/4")
	title.Parent = bb
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromRGB(6, 7, 5)
	ts.Thickness = 3.5
	ts.Parent = title
	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.fromScale(0.5, 0.66)
	sub.Size = UDim2.fromScale(1, 0.3)
	sub.BackgroundTransparency = 1
	sub.FontFace = BB_BODY
	sub.TextScaled = true
	sub.TextColor3 = BB_TEXT
	sub.Text = tostring(zone:GetAttribute("Sub") or "STEP ON TO PLAY")
	sub.Parent = bb
	local ss = Instance.new("UIStroke")
	ss.Color = Color3.fromRGB(6, 7, 5)
	ss.Thickness = 2.5
	ss.Parent = sub
end

local function refreshZones()
	local list, shopList = {}, {}
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") then
			local n = d.Name:lower()
			if n:match("^loadingzone") then
				table.insert(list, d)
				ensureZoneTitle(d) -- persistent "0/4" sign so players know it's an empty run pad
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
		p.Material = Enum.Material.SmoothPlastic -- CHANGED: was ForceField
		p.Color = Color3.fromRGB(255, 70, 70)
		p.Transparency = 1 -- CHANGED: fully invisible (an unseen fence, not a red barrier)
		p.CastShadow = false
		p.Size = def[2]
		p.CFrame = zone.CFrame * def[1]
		p.CollisionGroup = "PadWall"
		p.Parent = wall
	end
	wall.Parent = zone
end

local function updateBillboard(zone, party)
	updatePadWall(zone, party)
	local idle = zone:FindFirstChild("ZoneTitle")
	if idle then
		idle.Enabled = (party == nil) -- the live party counter takes over the idle "0/4" sign
	end
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
		bb.Size = UDim2.fromOffset(360, 104) -- CHANGED: roomier for the bigger, panel-free text
		bb.StudsOffsetWorldSpace = Vector3.new(0, 11, 0) -- CHANGED: raised (was 7) — sits above the ZoneTitle
		bb.AlwaysOnTop = true
		bb.Parent = zone
		label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1 -- CHANGED: pure floating text, no panel behind it
		label.FontFace = BB_BODY
		label.TextSize = 26 -- CHANGED: bigger (was 15)
		label.TextColor3 = BB_TEXT
		label.Parent = bb
		local st = Instance.new("UIStroke") -- legibility now that the panel is gone
		st.Color = Color3.fromRGB(6, 7, 5)
		st.Thickness = 3
		st.Parent = label
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
		label.Text = ("%s\n%d/%d · %ds"):format(cap(party.map), #party.members, party.size, secs)
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
		for _, pl in safe do
			local pr = profileCache[pl.UserId]
			if pr and (tonumber(pr.bestWave) or 0) <= 0 then
				LAUNCH.onboarding(pl, LAUNCH.Onboard.RunLaunched, party.map) -- first-ever PLAY
			end
			LAUNCH.custom(pl, "run_launched", #safe, party.map)
		end
		local ok, code = pcall(function()
			return TeleportService:ReserveServer(GAME_PLACE_ID)
		end)
		local options = Instance.new("TeleportOptions")
		if ok and code then
			options.ReservedServerAccessCode = code
		end
		options:SetTeleportData({ startRun = true, map = party.map, partySize = #safe })
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
				map = party.map, size = party.size,
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
		elseif not worldUnlocked(prof, party.map) then
			sendMode(player, "blockedLock", {
				mode = "blocked",
				reason = ("You haven't unlocked %s yet — reach account level %d."):format(cap(party.map), WORLD_UNLOCK_LEVEL[party.map] or 0),
			})
		else
			table.insert(party.members, player)
			playerParty[player.UserId] = party
			setPartyPassThrough(player, true)
			updateBillboard(zone, party) -- joining the last open slot raises the wall behind them
			sendMode(player, "party", {
				mode = "party",
				map = party.map, size = party.size,
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
	local map, size = tostring(sel.map), tonumber(sel.size)
	if not indexOf(WORLDS, map) then
		return
	end
	if not prof or not worldUnlocked(prof, map) then
		return
	end
	party.map = map
	party.size = math.clamp(math.floor(size or 1), 1, 4)
	party.state = "open"
	party.deadline = os.clock() + PARTY_WAIT
	lastMode[player.UserId] = nil -- re-send: host's UI flips from config to party view
	-- SQUAD: the leader locked in a run — make room and summon every member onto this pad. The normal
	-- zone tick adds them to the party (their own world unlock still applies).
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
						map = party.map, size = party.size,
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

-- ===== TITLES ===== (mirror of the game place's TitleConfig BY HAND — change both). Trophies are
-- EARNED in the game (profile.titlesOwned, game-owned); they're EQUIPPED here (profile.titleEquipped,
-- ours) on the classes showcase, and worn on the overhead tag's TOP line. VIP = rainbow.
local TITLES = {
	vip          = { name = "VIP",                 style = "rainbow", color = Color3.fromRGB(230, 180, 76),  source = "gamepass" },
	survivor     = { name = "SURVIVOR",            style = "static",  color = Color3.fromRGB(235, 235, 235), source = "achievement" },
	veteran      = { name = "VETERAN",             style = "static",  color = Color3.fromRGB(95, 205, 95),   source = "achievement" },
	nightmare    = { name = "NIGHTMARE",           style = "flicker", color = Color3.fromRGB(175, 95, 235),  source = "achievement" },
	unkillable   = { name = "UNKILLABLE",          style = "pulse",   color = Color3.fromRGB(255, 215, 70),  source = "achievement" },
	bloodmoon    = { name = "BLOOD MOON",          style = "static",  color = Color3.fromRGB(255, 70, 50),   source = "achievement" },
	vaultcracker = { name = "VAULT CRACKER",       style = "pulse",   color = Color3.fromRGB(240, 196, 82),  source = "achievement" },
	apocalypse   = { name = "APOCALYPSE SURVIVOR", style = "pulse",   color = Color3.fromRGB(255, 120, 40),  source = "achievement" },
	god          = { name = "GOD",                 style = "pulse",   color = Color3.fromRGB(120, 255, 235), source = "achievement" },
	elite        = { name = "ELITE",               style = "static",  color = Color3.fromRGB(80, 145, 255),  source = "level", level = 20 },
	legend       = { name = "LEGEND",              style = "rainbow", color = Color3.fromRGB(255, 80, 120),  source = "level", level = 40 },
}

-- The title this player actually gets to wear: their pick if it validates, else VIP for pass
-- holders, else nothing. (Validation repeats server-side on equip — this is the render check.)
local function wearableTitle(prof)
	local id = tostring(prof.titleEquipped or "")
	local def = TITLES[id]
	local ok = false
	if def then
		if def.source == "achievement" then
			ok = typeof(prof.titlesOwned) == "table" and prof.titlesOwned[id] == true
		elseif def.source == "level" then
			ok = accountLevel(prof.xp) >= (def.level or 999)
		else
			ok = prof.vip == true
		end
	end
	if not ok then
		return prof.vip and TITLES.vip or nil
	end
	return def
end

local function refreshPlayerTag(player)
	local prof = profileCache[player.UserId]
	if not prof then
		return
	end
	-- CHANGED (owner): the brag stat is BEST WAVE, not wins — mirrors the game place's tag.
	local bestWave = tonumber(prof.bestWave) or 0
	local lvl = accountLevel(prof.xp)
	local ls = player:FindFirstChild("leaderstats")
	local waveStat = ls and ls:FindFirstChild("Best Wave")
	if waveStat then
		waveStat.Value = bestWave
	end
	local char = player.Character
	local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
	if not head then
		return
	end
	local bb = head:FindFirstChild("PlayerTag")
	if bb and not bb:FindFirstChild("Title") then
		bb:Destroy() -- an old two-line tag from before the TITLE row: rebuild fresh
		bb = nil
	end
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "PlayerTag"
		-- STUDS-based size: the tag scales with the character (zoom in = bigger, out = smaller).
		bb.Size = UDim2.new(6, 0, 2.1, 0) -- three rows now: TITLE / WINS / LVL
		bb.StudsOffset = Vector3.new(0, 2.5, 0)
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
		line("Title", 0, 0.34, Color3.fromRGB(230, 180, 76))
		line("Wins", 0.34, 0.33, Color3.fromRGB(230, 180, 76))
		line("Level", 0.67, 0.33, Color3.fromRGB(255, 255, 255))
	end
	local tdef = wearableTitle(prof)
	bb.Title.Text = tdef and tdef.name or ""
	bb.Title.TextColor3 = tdef and tdef.color or Color3.new(1, 1, 1)
	player:SetAttribute("TitleStyle", tdef and tdef.style or nil) -- clients animate rainbow/pulse/flicker
	bb.Wins.Text = ("BEST WAVE %d"):format(bestWave)
	bb.Level.Text = ("LVL %d"):format(lvl)
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
			if LAUNCH.waitPolicy(player, 6) then
				-- PAID RANDOM ITEMS restricted: a pass-granted crate is a paid random item — pay its value.
				local c = LAUNCH.caseCoinValue("rare")
				prof.lobbyMoney += c
				markDirty(player)
				StatsRemote:FireClient(player, prof)
				ShopGift:FireClient(player, { from = "VIP DAILY", name = c .. " Coins", count = 1 })
			else
				prof.cases.rare = (prof.cases.rare or 0) + 1
				markDirty(player)
				pushInv(player)
				ShopGift:FireClient(player, { from = "VIP DAILY", name = "Rare Gun Crate", count = 1 })
			end
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
	-- BEST WAVE on the Roblox leaderboard (filled in once the profile loads).
	local lstats = Instance.new("Folder")
	lstats.Name = "leaderstats"
	lstats.Parent = player
	local waveStat = Instance.new("IntValue")
	waveStat.Name = "Best Wave"
	waveStat.Parent = lstats
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
		task.spawn(LAUNCH.fetchPolicy, player) -- paid-random-items policy (fails closed until it lands)
		StatsRemote:FireClient(player, profile)
		pushInv(player)
		refreshCarry(player)
		refreshPlayerTag(player)
		primeVip(player)
		-- DAILY QUESTS: consume the game server's PROFILE-stamped run summary (bankRun writes it and
		-- blocking-saves before the teleport). CHANGED: TeleportData is no longer trusted — a client
		-- can initiate its own teleport here with a fabricated summary; the DataStore copy it can't
		-- touch. The summary id de-dupes (a resurrected stale write can't double-feed quests).
		local sum = profile.pendingRunSummary
		if typeof(sum) == "table" and typeof(sum.id) == "string" and sum.id ~= profile.lastRunSummaryId then
			profile.lastRunSummaryId = sum.id
			bumpQuest(player, "kills", math.floor(tonumber(sum.kills) or 0))
			bumpQuest(player, "money", math.floor(tonumber(sum.money) or 0))
			bumpQuest(player, "wave", math.floor(tonumber(sum.wave) or 0))
			bumpQuest(player, "runs", 1)
			if sum.win == true then
				bumpQuest(player, "wins", 1)
			end
			markDirty(player)
			-- RUN RECAP (launch pass): the lobby never showed the run you just finished. LobbyExtras
			-- renders this card (+ the "new personal best" like-nudge). Stored so the client can re-ask.
			local wave = math.floor(tonumber(sum.wave) or 0)
			local newBest
			if sum.newBest ~= nil then
				newBest = sum.newBest == true
			else
				newBest = wave > 0 and wave == math.floor(tonumber(profile.bestWave) or 0) -- older game build
			end
			LAUNCH.recap[player.UserId] = {
				id = sum.id, wave = wave, kills = math.floor(tonumber(sum.kills) or 0),
				money = math.floor(tonumber(sum.money) or 0), newBest = newBest,
				best = math.floor(tonumber(profile.bestWave) or 0),
			}
			LAUNCH.RunRecap:FireClient(player, LAUNCH.recap[player.UserId])
		end
		pushQuests(player)
		-- ONBOARDING funnel: a brand-new account (never ran) joined the lobby. Veterans skip the step.
		if (tonumber(profile.bestWave) or 0) <= 0 then
			LAUNCH.onboarding(player, LAUNCH.Onboard.LobbyJoined)
		end
		if table.find(profile.ownedWeapons, "raygun") then
			LAUNCH.badge(player, "raygun") -- level-unlocked (or pulled on another server) — badge it here
		end
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
	LAUNCH.restricted[pl.UserId] = nil
	LAUNCH.badgeDone[pl.UserId] = nil
	LAUNCH.budget[pl.UserId] = nil
	LAUNCH.recap[pl.UserId] = nil
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

-- Buy a gun outright with Coins.
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
	LAUNCH.economy(player, "Sink", price, prof.lobbyMoney, "Shop", "gun_" .. weaponId)
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
	LAUNCH.economy(player, "Source", d.coins or 0, prof.lobbyMoney, "TimedReward", "quest_" .. tostring(d.id))
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
			name = QUESTS.BonusCase:sub(1, 1):upper() .. QUESTS.BonusCase:sub(2) .. " Gun Crate",
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

-- First-join pointer tour finished (or skipped): remember it so it never auto-runs again. Idempotent.
-- Equip / clear a TITLE (the classes showcase's TITLES section). "" = wear nothing (VIP holders
-- fall back to the rainbow VIP tag). Validated against how each title is sourced.
local TitleEquip = mk("TitleEquip")
TitleEquip.OnServerEvent:Connect(function(player, id)
	if not allow(player, "Equip") then
		return
	end
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist then
		return
	end
	id = tostring(id or "")
	if id ~= "" then
		local def = TITLES[id]
		if not def then
			return
		end
		local ok
		if def.source == "achievement" then
			ok = typeof(prof.titlesOwned) == "table" and prof.titlesOwned[id] == true
		elseif def.source == "level" then
			ok = accountLevel(prof.xp) >= (def.level or 999)
		else
			ok = prof.vip == true
		end
		if not ok then
			return
		end
	end
	prof.titleEquipped = id
	markDirty(player)
	refreshPlayerTag(player)
	StatsRemote:FireClient(player, prof) -- echo so the picker's EQUIPPED badge confirms
end)

local TutorialDone = mk("TutorialDone")
TutorialDone.OnServerEvent:Connect(function(player)
	local prof = profileCache[player.UserId]
	if not prof or prof.noPersist or prof.tutDone then
		return
	end
	prof.tutDone = true
	markDirty(player)
	LAUNCH.onboarding(player, LAUNCH.Onboard.TutorialDone)
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
