--!nonstrict
-- AutoShootController.lua — toggle for auto-fire. When ON (default), your gun automatically shoots any
-- zombie the auto-aim is locked onto (no need to hold the mouse); when OFF you fire manually.
-- A small pill sits bottom-right: press T or click it to toggle. Other code reads AutoShootController.IsOn().

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("UITheme"))

local AutoShootController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.T

-- ===== STYLE (UITheme — gritty apocalypse) =====
local COL_PANEL    = UITheme.PANEL
local COL_TEXT     = UITheme.TEXT
local COL_TEXT_DIM = UITheme.DIM
local COL_ACCENT   = UITheme.TOXIC
local COL_OFF      = UITheme.DIM

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
	gui.DisplayOrder = UITheme.Layer.Chrome
	gui.Parent = playerGui
	UITheme.Attach(gui)

	button = Instance.new("TextButton")
	button.Name = "AutoShootButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -72, 1, -16) -- clear of the settings gear in the corner
	button.Size = UDim2.fromOffset(170, 38)
	button.BackgroundColor3 = COL_PANEL
	button.BackgroundTransparency = 0.06
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = button
	UITheme.Studs(button)
	UITheme.Depth(button)
	UITheme.Edge(button)

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
	label.FontFace = UITheme.BodyBoldFace
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = button

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 0.5)
	hint.Position = UDim2.new(1, -12, 0.5, 0)
	hint.Size = UDim2.fromOffset(20, 16)
	hint.BackgroundTransparency = 1
	hint.FontFace = UITheme.BodyBoldFace
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
