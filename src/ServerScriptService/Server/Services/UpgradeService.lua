--!nonstrict
-- UpgradeService.lua — in-run gun upgrades. Each gun has 5 levels (UpgradeConfig) bought with in-run cash
-- via the client's UPGRADE button (upgrades the gun you're HOLDING). Levels live in ps.upgrades and reset
-- every run — nothing here is ever saved. CombatService reads the effective stats at fire time.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local UpgradeConfig = require(Config.UpgradeConfig)
local Remotes = require(Modules.Remotes)

local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)
local PointsService = require(script.Parent.PointsService)

local UpgradeService = {}

-- Sync the player's upgrade levels to their client (drives the UPGRADE button + hotbar labels + cadence).
local function push(player: Player)
	local ps = MatchService.GetPlayerState(player)
	Remotes.Get("UpgradeState"):FireClient(player, (ps and ps.upgrades) or {})
end
UpgradeService.Push = push

local function onBuy(player: Player)
	if not SecurityService.Allow(player, "Buy") then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch or ps.isDowned then
		return
	end
	local weaponId = ps.equippedWeapon
	if not WeaponConfig[weaponId] then
		return
	end
	local level = (ps.upgrades and ps.upgrades[weaponId]) or 0
	local price = UpgradeConfig.NextPrice(weaponId, level)
	if not price then
		return -- already maxed
	end
	if not PointsService.TrySpend(player, price) then
		return -- can't afford (client grays the button, but always re-validate)
	end
	ps.upgrades[weaponId] = level + 1
	push(player)
end

function UpgradeService.Start()
	Remotes.Get("BuyUpgrade").OnServerEvent:Connect(onBuy)

	-- Fresh sync whenever a character spawns into a run (state was reset just before the spawn).
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(push, player)
		end)
		if player.Character then
			task.defer(push, player)
		end
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)

	print("[UpgradeService] started (5 in-run upgrade levels per gun)")
end

return UpgradeService
