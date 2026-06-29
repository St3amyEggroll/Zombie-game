--!nonstrict
-- ShopService.lua — the Zombie Rush shop. Buy weapons and upgrade your current weapon for cash, from a
-- MENU (no in-map prompts). The server validates affordability + legality; PointsService is the cash
-- ledger; CombatService grants the weapon / the upgrade level rides on the match state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local ShopConfig = require(Config.ShopConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local PointsService = require(script.Parent.PointsService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)
local SecurityService = require(script.Parent.SecurityService)

local ShopService = {}

-- Push the player's shop-relevant state (owned weapons, upgrade levels, cash) so the menu can render.
local function fireShop(player: Player, ps)
	Remotes.Get("ShopChanged"):FireClient(player, ps.ownedWeapons, ps.upgrades, ps.points)
end

-- ===== BUY A WEAPON =====
local function onBuyWeapon(player: Player, weaponId: any)
	if not SecurityService.Allow(player, "Buy") then
		return
	end
	if typeof(weaponId) ~= "string" then
		return
	end
	local price = ShopConfig.Weapons[weaponId]
	if not price then
		return -- not a buyable weapon
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return
	end
	if Util.Contains(ps.ownedWeapons, weaponId) then
		return -- already owned
	end
	if PointsService.TrySpend(player, price) then
		CombatService.GrantWeapon(player, weaponId)
		fireShop(player, ps)
	end
end

-- ===== UPGRADE A WEAPON =====
local function onUpgradeWeapon(player: Player, weaponId: any)
	if not SecurityService.Allow(player, "Buy") then
		return
	end
	if typeof(weaponId) ~= "string" or not WeaponConfig[weaponId] then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not Util.Contains(ps.ownedWeapons, weaponId) then
		return
	end
	local level = ps.upgrades[weaponId] or 0
	if level >= ShopConfig.MaxUpgradeLevel then
		return
	end
	local cost = ShopConfig.UpgradeCost(level)
	if PointsService.TrySpend(player, cost) then
		ps.upgrades[weaponId] = level + 1
		fireShop(player, ps)
	end
end

-- ===== LIFECYCLE =====
local function pushInitial(player: Player)
	local ps = MatchService.GetPlayerState(player)
	if ps then
		fireShop(player, ps)
	end
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		task.defer(pushInitial, player)
	end)
	task.defer(pushInitial, player)
end

function ShopService.Start()
	Remotes.Get("BuyWeapon").OnServerEvent:Connect(onBuyWeapon)
	Remotes.Get("UpgradeWeapon").OnServerEvent:Connect(onUpgradeWeapon)

	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	print("[ShopService] started")
end

return ShopService
