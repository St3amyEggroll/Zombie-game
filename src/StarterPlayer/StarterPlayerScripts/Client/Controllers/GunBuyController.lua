--!nonstrict
-- GunBuyController.lua — the single "NEXT GUN" button (bottom-center). Shows the next gun on your ladder
-- and its price; click (or press B) to buy — the server replaces your current gun with it. Grayed out when
-- you can't afford it; hidden when you're holding the last gun on your ladder.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local GunBuyController = {}

-- ===== TUNABLES =====
local BUY_KEY = Enum.KeyCode.B

-- ===== STYLE (shared design system) =====
local COL_PANEL    = Color3.fromRGB(22, 24, 30)
local COL_TEXT     = Color3.fromRGB(238, 240, 245)
local COL_TEXT_DIM = Color3.fromRGB(150, 156, 168)
local COL_ACCENT   = Color3.fromRGB(87, 196, 116)
local COL_GOLD     = Color3.fromRGB(235, 190, 85)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local button, nameLabel, priceLabel
local nextGun = nil -- { name, price } or nil
local cash = 0

local function refresh()
	if not button then
		return
	end
	if not nextGun then
		button.Visible = false
		return
	end
	button.Visible = true
	local affordable = cash >= nextGun.price
	nameLabel.Text = "NEXT GUN  ·  " .. nextGun.name
	nameLabel.TextColor3 = affordable and COL_TEXT or COL_TEXT_DIM
	priceLabel.Text = "$" .. Util.FormatNumber(nextGun.price)
	priceLabel.TextColor3 = affordable and COL_ACCENT or COL_TEXT_DIM
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "GunBuyHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = playerGui

	button = Instance.new("TextButton")
	button.Name = "NextGunButton"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -16)
	button.Size = UDim2.fromOffset(230, 56)
	button.BackgroundColor3 = COL_PANEL
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Visible = false
	button.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = button
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Transparency = 0.92
	s.Parent = button

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "GunName"
	nameLabel.Position = UDim2.fromOffset(0, 8)
	nameLabel.Size = UDim2.new(1, 0, 0, 18)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.TextColor3 = COL_TEXT
	nameLabel.Parent = button

	priceLabel = Instance.new("TextLabel")
	priceLabel.Name = "GunPrice"
	priceLabel.Position = UDim2.fromOffset(0, 28)
	priceLabel.Size = UDim2.new(1, 0, 0, 18)
	priceLabel.BackgroundTransparency = 1
	priceLabel.Font = Enum.Font.GothamBold
	priceLabel.TextSize = 15
	priceLabel.TextColor3 = COL_GOLD
	priceLabel.Parent = button

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -10, 0, 6)
	hint.Size = UDim2.fromOffset(16, 14)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextSize = 11
	hint.TextColor3 = COL_TEXT_DIM
	hint.Text = "B"
	hint.Parent = button

	button.Activated:Connect(function()
		Remotes.Get("BuyNextGun"):FireServer()
	end)
end

function GunBuyController.Start()
	build()

	Remotes.Get("GunLadder").OnClientEvent:Connect(function(info)
		nextGun = (typeof(info) == "table" and info.name and info.price) and info or nil
		refresh()
	end)
	Remotes.Get("PointsChanged").OnClientEvent:Connect(function(points)
		cash = tonumber(points) or 0
		refresh()
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == BUY_KEY and nextGun then
			Remotes.Get("BuyNextGun"):FireServer()
		end
	end)

	print("[GunBuyController] started (NEXT GUN button)")
end

return GunBuyController
