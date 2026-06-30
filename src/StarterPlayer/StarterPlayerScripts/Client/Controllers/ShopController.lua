--!nonstrict
-- ShopController.lua — the Zombie Rush shop menu. **You style the UI; this drives it.** Press B (or tap
-- the on-screen Shop button) to open. Lists buyable weapons + an upgrade for your current weapon, and
-- sends buy/upgrade intent to the server (which validates cash + legality).
--
-- This builds a plain functional menu so it works out of the box — restyle/replace the "ShopMenu"
-- ScreenGui freely. Element names it reads from / writes to are documented inline.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local ShopConfig = require(Config.ShopConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local InputController = require(script.Parent.InputController)

local ShopController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.B

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ===== STATE (mirrors what the server tells us) =====
local owned: { [string]: boolean } = { pistol = true }
local upgrades: { [string]: number } = {}
local cash = 0

local gui, panel, cashLabel, listFrame, upgradeBtn
local open = false

-- ===== UI BUILD (replace/restyle freely) =====
local function buildUI()
	gui = Instance.new("ScreenGui")
	gui.Name = "ShopMenu"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 460)
	panel.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -20, 0, 40)
	title.Position = UDim2.fromOffset(10, 8)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "SHOP"
	title.Parent = panel

	cashLabel = Instance.new("TextLabel")
	cashLabel.Name = "CashLabel"
	cashLabel.Size = UDim2.new(1, -20, 0, 28)
	cashLabel.Position = UDim2.fromOffset(10, 48)
	cashLabel.BackgroundTransparency = 1
	cashLabel.Font = Enum.Font.GothamMedium
	cashLabel.TextScaled = true
	cashLabel.TextColor3 = Color3.fromRGB(120, 230, 140)
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.Text = "$0"
	cashLabel.Parent = panel

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "WeaponList"
	listFrame.Size = UDim2.new(1, -20, 1, -150)
	listFrame.Position = UDim2.fromOffset(10, 84)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 6
	listFrame.CanvasSize = UDim2.new()
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = listFrame

	upgradeBtn = Instance.new("TextButton")
	upgradeBtn.Name = "UpgradeButton"
	upgradeBtn.Size = UDim2.new(1, -20, 0, 44)
	upgradeBtn.Position = UDim2.new(0, 10, 1, -54)
	upgradeBtn.BackgroundColor3 = Color3.fromRGB(60, 90, 160)
	upgradeBtn.Font = Enum.Font.GothamBold
	upgradeBtn.TextScaled = true
	upgradeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	upgradeBtn.Text = "Upgrade"
	upgradeBtn.Parent = panel
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 8)
	uc.Parent = upgradeBtn
	upgradeBtn.Activated:Connect(function()
		Remotes.Get("UpgradeWeapon"):FireServer(InputController.GetEquipped())
	end)

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Size = UDim2.fromOffset(32, 32)
	closeBtn.Position = UDim2.new(1, -8, 0, 8)
	closeBtn.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Text = "X"
	closeBtn.Parent = panel
	closeBtn.Activated:Connect(function()
		ShopController.SetOpen(false)
	end)
end

-- ===== RENDER =====
local function makeWeaponRow(weaponId: string, price: number, layoutOrder: number)
	local weapon = WeaponConfig[weaponId]
	local btn = Instance.new("TextButton")
	btn.Name = "Row_" .. weaponId
	btn.Size = UDim2.new(1, -6, 0, 40)
	btn.LayoutOrder = layoutOrder
	btn.Font = Enum.Font.GothamMedium
	btn.TextScaled = true
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	local ownsIt = owned[weaponId]
	if ownsIt then
		btn.BackgroundColor3 = Color3.fromRGB(40, 60, 45)
		btn.Text = ("%s   OWNED"):format(weapon and weapon.name or weaponId)
		btn.AutoButtonColor = false
	else
		local affordable = cash >= price
		btn.BackgroundColor3 = affordable and Color3.fromRGB(45, 55, 70) or Color3.fromRGB(55, 40, 40)
		btn.Text = ("%s   $%s"):format(weapon and weapon.name or weaponId, Util.FormatNumber(price))
		btn.Activated:Connect(function()
			Remotes.Get("BuyWeapon"):FireServer(weaponId)
		end)
	end
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = btn
	btn.Parent = listFrame
end

local function render()
	if not gui then
		return
	end
	cashLabel.Text = "$" .. Util.FormatNumber(cash)

	-- Rebuild weapon rows.
	for _, child in listFrame:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for i, weaponId in ShopConfig.Order do
		local price = ShopConfig.Weapons[weaponId]
		if price then
			makeWeaponRow(weaponId, price, i)
		end
	end

	-- Upgrade button reflects the equipped weapon.
	local equipped = InputController.GetEquipped()
	local weapon = WeaponConfig[equipped]
	local level = upgrades[equipped] or 0
	if level >= ShopConfig.MaxUpgradeLevel then
		upgradeBtn.Text = ("%s  MAX (Lv %d)"):format(weapon and weapon.name or equipped, level)
		upgradeBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 75)
	else
		local upCost = ShopConfig.UpgradeCost(level)
		upgradeBtn.Text = ("Upgrade %s  Lv %d->%d   $%s")
			:format(weapon and weapon.name or equipped, level, level + 1, Util.FormatNumber(upCost))
		upgradeBtn.BackgroundColor3 = (cash >= upCost) and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(70, 55, 55)
	end
end

-- ===== OPEN / CLOSE =====
function ShopController.IsOpen(): boolean
	return open
end

function ShopController.SetOpen(value: boolean)
	open = value
	if gui then
		gui.Enabled = open
	end
	if open then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		render()
	end
end

-- Always-visible button to open the shop (so it's discoverable without knowing the B key).
local function buildOpenButton()
	local g = Instance.new("ScreenGui")
	g.Name = "ShopButton"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.Parent = playerGui

	local btn = Instance.new("TextButton")
	btn.Name = "OpenShop"
	btn.AnchorPoint = Vector2.new(0.5, 1)
	btn.Position = UDim2.new(0.5, 0, 1, -12)
	btn.Size = UDim2.fromOffset(180, 40)
	btn.BackgroundColor3 = Color3.fromRGB(45, 120, 70)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Text = "SHOP (B)"
	btn.Parent = g
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = btn
	btn.Activated:Connect(function()
		ShopController.SetOpen(not open)
	end)
end

-- ===== LIFECYCLE =====
function ShopController.Start()
	buildUI()
	buildOpenButton()

	Remotes.Get("ShopChanged").OnClientEvent:Connect(function(ownedList, ups, money)
		owned = {}
		if type(ownedList) == "table" then
			for _, id in ownedList do
				owned[id] = true
			end
		end
		upgrades = (type(ups) == "table") and ups or {}
		if type(money) == "number" then
			cash = money
		end
		if open then
			render()
		end
	end)

	Remotes.Get("PointsChanged").OnClientEvent:Connect(function(money)
		cash = money
		if open then
			render()
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			ShopController.SetOpen(not open)
		end
	end)

	print("[ShopController] started (press B for the shop)")
end

return ShopController
