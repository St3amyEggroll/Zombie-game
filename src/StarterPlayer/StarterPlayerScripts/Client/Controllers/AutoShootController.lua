--!nonstrict
-- AutoShootController.lua — toggle for auto-fire. When ON (default OFF), your gun automatically shoots any
-- zombie the auto-aim is locked onto (no need to hold the mouse); when OFF you fire manually.
-- Two stacked sticker buttons (per the approved plan): toxic "AUTOFIRE: ON" / greyed "AUTOFIRE: OFF",
-- with the T keybind riding as a gold corner chip. Press T or click to toggle.
-- Other code reads AutoShootController.IsOn().

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("UITheme"))

local AutoShootController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.T
local BTN_W, BTN_H = 178, 46

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local on = false -- default OFF (press T or click the sticker to enable)
local onBtn, offBtn

function AutoShootController.IsOn(): boolean
	return on
end

local function refresh()
	if onBtn then
		onBtn.Visible = on
		offBtn.Visible = not on
	end
end

local function setOn(v: boolean)
	on = v
	refresh()
end

-- The gold T chip riding the button's top-right corner (matches the plan's keybind chips).
local function keyChip(parent)
	local chip = Instance.new("TextLabel")
	chip.Name = "KeyChip"
	chip.AnchorPoint = Vector2.new(1, 0)
	chip.Position = UDim2.new(1, 8, 0, -8)
	chip.Size = UDim2.fromOffset(24, 20)
	chip.BackgroundColor3 = UITheme.GOLD
	chip.BorderSizePixel = 0
	chip.FontFace = UITheme.TitleFace
	chip.TextSize = 12
	chip.TextColor3 = UITheme.BLACK
	chip.Text = "T"
	chip.ZIndex = 6
	chip.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = chip
	UITheme.Edge(chip, UITheme.BLACK, 2.5)
	return chip
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoShootHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.Chrome
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- Two full sticker buttons occupying the same spot; `on` decides which one shows.
	local function stateButton(textStr, variant)
		local b = UITheme.Button(gui, textStr, variant)
		b.Name = "AutoShoot_" .. textStr:gsub("[^%w]", "")
		b.AnchorPoint = Vector2.new(1, 1)
		b.Position = UDim2.new(1, -72, 1, -20) -- clear of the settings gear in the corner
		b.Size = UDim2.fromOffset(BTN_W, BTN_H)
		b.TextSize = 15
		keyChip(b)
		b.Activated:Connect(function()
			setOn(not on)
		end)
		return b
	end
	onBtn = stateButton("AUTOFIRE: ON", "primary")
	offBtn = stateButton("AUTOFIRE: OFF", "ghost")
	-- The OFF state reads clearly "asleep": dim the face + label a step further than plain ghost.
	do
		local face = offBtn:FindFirstChild("Face")
		local label = face and face:FindFirstChild("Label")
		if label then
			label.TextColor3 = UITheme.DIM
		end
	end
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
	print("[AutoShootController] started (auto-shoot default OFF, sticker toggle)")
end

return AutoShootController
