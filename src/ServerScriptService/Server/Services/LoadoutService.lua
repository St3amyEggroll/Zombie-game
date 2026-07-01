--!nonstrict
-- LoadoutService.lua — puts the player's equipped weapons into Roblox's NATIVE hotbar (the 1/2/3 slots at
-- the bottom of the screen) as Tools, so switching weapons uses the built-in Backpack UI. The weapons a
-- player gets are whatever they equipped in the LOBBY inventory (MatchService reads their tierLoadout into
-- ps.ownedWeapons). Selecting a hotbar slot equips that Tool, which we forward to CombatService so the
-- server-authoritative combat + the in-hand model follow along.
--
-- The Tools are handle-less (RequiresHandle=false): the visible gun is still welded by WeaponModelService.
-- The Tool is just the hotbar entry + equip trigger.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local WeaponConfig = require(SharedConfig:WaitForChild("WeaponConfig"))

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)

local LoadoutService = {}

-- ===== TUNABLES =====
local TOOL_TAG_ATTR = "ZLWeaponTool" -- marks Tools we own (so we clear only ours)
local WEAPON_ID_ATTR = "WeaponId"    -- weaponId stored on each Tool

-- Remove the weapon Tools we previously gave (from both the Backpack and the equipped character).
local function clearTools(player: Player)
	local containers = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(containers, backpack)
	end
	if player.Character then
		table.insert(containers, player.Character)
	end
	for _, container in containers do
		for _, tool in container:GetChildren() do
			if tool:IsA("Tool") and tool:GetAttribute(TOOL_TAG_ATTR) then
				tool:Destroy()
			end
		end
	end
end

local function makeTool(weaponId: string): Tool
	local weapon = WeaponConfig[weaponId]
	local tool = Instance.new("Tool")
	tool.Name = weapon and weapon.name or weaponId
	tool.ToolTip = weapon and weapon.name or weaponId
	tool.RequiresHandle = false       -- the visible gun is welded by WeaponModelService; no handle needed
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true  -- we fire via the custom auto-shoot loop, not Tool.Activated
	tool:SetAttribute(TOOL_TAG_ATTR, true)
	tool:SetAttribute(WEAPON_ID_ATTR, weaponId)
	-- When the player selects this slot in the hotbar, tell the server to equip that weapon.
	tool.Equipped:Connect(function()
		local pl = Players:GetPlayerFromCharacter(tool.Parent)
		if pl then
			CombatService.SetEquipped(pl, weaponId)
		end
	end)
	return tool
end

-- Build the player's hotbar from their owned weapons and auto-equip their current weapon.
local function giveTools(player: Player)
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		clearTools(player) -- in the lobby/menu: no combat tools
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if not backpack then
		return
	end
	clearTools(player)

	local equippedTool
	for _, weaponId in ps.ownedWeapons do
		if WeaponConfig[weaponId] then
			local tool = makeTool(weaponId)
			tool.Parent = backpack
			if weaponId == ps.equippedWeapon then
				equippedTool = tool
			end
		end
	end

	-- Start them holding their equipped weapon (first hotbar slot by default).
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and equippedTool then
		humanoid:EquipTool(equippedTool)
	end
end
LoadoutService.GiveTools = giveTools

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		-- Defer so MatchService has set inMatch + ownedWeapons for this spawn before we read them.
		task.defer(giveTools, player)
	end)
	if player.Character then
		task.defer(giveTools, player)
	end
end

function LoadoutService.Start()
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	print("[LoadoutService] started (equipped loadout -> native hotbar)")
end

return LoadoutService
