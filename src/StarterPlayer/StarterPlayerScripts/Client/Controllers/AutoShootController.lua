--!nonstrict
-- AutoShootController.lua — toggle for auto-fire. When ON (default), your gun automatically shoots any
-- zombie the auto-aim is locked onto (no need to hold the mouse); when OFF you fire manually.
-- A small pill sits bottom-right: press T or click it to toggle. Other code reads AutoShootController.IsOn().

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local AutoShootController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.T

-- ===== STYLE (shared design system) =====
local COL_PANEL    = Color3.fromRGB(22, 24, 30)
local COL_TEXT     = Color3.fromRGB(238, 240, 245)
local COL_TEXT_DIM = Color3.fromRGB(150, 156, 168)
local COL_ACCENT   = Color3.fromRGB(87, 196, 116)
local COL_OFF      = Color3.fromRGB(110, 115, 128)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local on = true -- default ON
local button, dot, label

function AutoShootController.IsOn(): boolean
	return on
end

local function refresh()
	if not button then
		return
	end
	dot.BackgroundColor3 = on and COL_ACCENT or COL_OFF
	label.Text = on and "AUTO FIRE  ·  ON" or "AUTO FIRE  ·  OFF"
	label.TextColor3 = on and COL_TEXT or COL_TEXT_DIM
end

local function setOn(v: boolean)
	on = v
	refresh()
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoShootHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = playerGui

	button = Instance.new("TextButton")
	button.Name = "AutoShootButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -16, 1, -16)
	button.Size = UDim2.fromOffset(170, 38)
	button.BackgroundColor3 = COL_PANEL
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = button
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Transparency = 0.92
	s.Parent = button

	dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.new(0, 14, 0.5, 0)
	dot.Size = UDim2.fromOffset(9, 9)
	dot.BorderSizePixel = 0
	dot.Parent = button
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = dot

	label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Position = UDim2.fromOffset(32, 0)
	label.Size = UDim2.new(1, -40, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = button

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 0.5)
	hint.Position = UDim2.new(1, -12, 0.5, 0)
	hint.Size = UDim2.fromOffset(20, 16)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextSize = 11
	hint.TextColor3 = COL_TEXT_DIM
	hint.Text = "T"
	hint.Parent = button

	button.Activated:Connect(function()
		setOn(not on)
	end)
	refresh()
end

function AutoShootController.Start()
	build()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			setOn(not on)
		end
	end)
	print("[AutoShootController] started (auto-shoot default ON)")
end

return AutoShootController
