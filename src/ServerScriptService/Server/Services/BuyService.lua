--!nonstrict
-- BuyService.lua — wall-buys, ammo refills, and doors. Each buyable is a tagged map part; this attaches
-- a ProximityPrompt and validates EVERYTHING server-side on trigger: rate-limit, real proximity, and
-- affordability recomputed from config + the server's points. (Pack-a-Punch + Mystery Box land in Phase 5.)
--
-- MAP CONTRACT (tag parts, set Attributes — CLAUDE.md §10):
--   WallBuy : a part. Attributes: WeaponId (string), Cost (number).   Owned already -> refills ammo.
--   Door    : a part/model. Attribute: Cost (number).                 Buying removes the barrier.
--   AmmoBuy : a part. Attribute: Cost (number, optional).             Refills the equipped weapon.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local Util = require(Modules.Util)

local PointsService = require(script.Parent.PointsService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)
local SecurityService = require(script.Parent.SecurityService)

local BuyService = {}

-- ===== TUNABLES =====
local MAX_BUY_DIST = 12   -- studs; prompt activation distance AND the server-side re-check radius

-- ===== HELPERS =====
local function promptAnchor(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

local function makePrompt(inst: Instance, objectText: string, actionText: string): ProximityPrompt?
	local anchor = promptAnchor(inst)
	if not anchor then
		warn(("[BuyService] %s has no part to attach a prompt to"):format(inst:GetFullName()))
		return nil
	end
	local existing = anchor:FindFirstChildOfClass("ProximityPrompt")
	if existing then
		existing:Destroy()
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = objectText
	prompt.ActionText = actionText
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = MAX_BUY_DIST
	prompt.Parent = anchor
	return prompt
end

-- Server-side proximity re-check (the prompt's distance is client-enforced; never trust it alone).
local function inRange(player: Player, inst: Instance): boolean
	local anchor = promptAnchor(inst)
	local hrp = Util.GetRootPart(player)
	if not anchor or not hrp then
		return false
	end
	return (anchor.Position - hrp.Position).Magnitude <= MAX_BUY_DIST + 4
end

-- Common gate for every prompt trigger.
local function allowed(player: Player, inst: Instance): boolean
	if not SecurityService.Allow(player, "Buy") then
		return false
	end
	if not SecurityService.IsAlive(player) then
		return false
	end
	return inRange(player, inst)
end

-- ===== BUYABLES =====
local function setupWallBuy(inst: Instance)
	local weaponId = inst:GetAttribute("WeaponId")
	local cost = inst:GetAttribute("Cost")
	local weapon = (typeof(weaponId) == "string") and WeaponConfig[weaponId] or nil
	if not weapon or typeof(cost) ~= "number" then
		warn(("[BuyService] WallBuy needs valid WeaponId + Cost attributes: %s"):format(inst:GetFullName()))
		return
	end
	local prompt = makePrompt(inst, weapon.name, ("Buy  $%d"):format(cost))
	if not prompt then
		return
	end
	prompt.Triggered:Connect(function(player)
		if not allowed(player, inst) then
			return
		end
		local ps = MatchService.GetPlayerState(player)
		if not ps then
			return
		end
		if Util.Contains(ps.ownedWeapons, weaponId) then
			-- Already owned -> sell ammo at the weapon's ammoCost.
			if PointsService.TrySpend(player, weapon.ammoCost) then
				CombatService.RefillAmmo(player, weaponId)
			end
		else
			if PointsService.TrySpend(player, cost) then
				CombatService.GrantWeapon(player, weaponId)
			end
		end
	end)
end

local function setupDoor(inst: Instance)
	local cost = inst:GetAttribute("Cost")
	if typeof(cost) ~= "number" then
		cost = 0
	end
	local prompt = makePrompt(inst, "Door", ("Open  $%d"):format(cost))
	if not prompt then
		return
	end
	prompt.Triggered:Connect(function(player)
		if not allowed(player, inst) then
			return
		end
		if PointsService.TrySpend(player, cost) then
			inst:Destroy() -- remove the barrier (takes the prompt with it)
		end
	end)
end

local function setupAmmoBuy(inst: Instance)
	local cost = inst:GetAttribute("Cost")
	local label = (typeof(cost) == "number") and ("Ammo  $%d"):format(cost) or "Ammo"
	local prompt = makePrompt(inst, "Ammo", label)
	if not prompt then
		return
	end
	prompt.Triggered:Connect(function(player)
		if not allowed(player, inst) then
			return
		end
		local ps = MatchService.GetPlayerState(player)
		if not ps then
			return
		end
		local weaponId = ps.equippedWeapon
		local weapon = WeaponConfig[weaponId]
		if not weapon then
			return
		end
		local price = (typeof(cost) == "number") and cost or weapon.ammoCost
		if PointsService.TrySpend(player, price) then
			CombatService.RefillAmmo(player, weaponId)
		end
	end)
end

local SETUPS: { [string]: (Instance) -> () } = {
	WallBuy = setupWallBuy,
	Door = setupDoor,
	AmmoBuy = setupAmmoBuy,
}

-- ===== LIFECYCLE =====
function BuyService.Start()
	for tag, setup in SETUPS do
		for _, inst in CollectionService:GetTagged(tag) do
			task.spawn(setup, inst)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
			task.spawn(setup, inst)
		end)
	end
	print("[BuyService] started")
end

return BuyService
