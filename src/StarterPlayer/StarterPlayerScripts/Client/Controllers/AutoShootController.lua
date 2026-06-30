--!nonstrict
-- AutoShootController.lua — toggle for auto-fire. When ON (default), your gun automatically shoots any
-- zombie the auto-aim is locked onto (no need to hold the mouse); when OFF you fire manually. Shows a
-- green "AUTO: ON" / red "AUTO: OFF" button that sits right above the wave number (the RoundLabel).
-- Press T or click the button to toggle. Other code reads AutoShootController.IsOn().

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AutoShootController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.T
local ON_COLOR   = Color3.fromRGB(55, 180, 75)
local OFF_COLOR  = Color3.fromRGB(200, 55, 55)
local GAP        = 6  -- px above the wave number
local BTN_H      = 32 -- button height (px)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local on = true -- default ON
local button
local roundLabelCache

function AutoShootController.IsOn(): boolean
	return on
end

local function refresh()
	if button then
		button.Text = on and "AUTO: ON" or "AUTO: OFF"
		button.BackgroundColor3 = on and ON_COLOR or OFF_COLOR
	end
end

local function setOn(v: boolean)
	on = v
	refresh()
end

-- The wave-number label (cached; re-found if it's destroyed/restyled).
local function findRoundLabel()
	if roundLabelCache and roundLabelCache.Parent then
		return roundLabelCache
	end
	for _, d in playerGui:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Name == "RoundLabel" then
			roundLabelCache = d
			return d
		end
	end
	roundLabelCache = nil
	return nil
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
	button.AnchorPoint = Vector2.new(0, 0)
	button.Size = UDim2.fromOffset(150, BTN_H)
	button.Position = UDim2.new(1, -270, 1, -130) -- default; follow() repositions it above the wave number
	button.Font = Enum.Font.GothamBold
	button.TextScaled = true
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.AutoButtonColor = true
	button.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = button
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 5)
	pad.PaddingBottom = UDim.new(0, 5)
	pad.Parent = button

	button.Activated:Connect(function()
		setOn(not on)
	end)
	refresh()
end

-- Keep the button sitting right above the wave number, matching its width.
local function follow()
	if not button then
		return
	end
	local rl = findRoundLabel()
	if rl and rl.AbsoluteSize.X > 0 then
		button.Size = UDim2.fromOffset(math.max(120, rl.AbsoluteSize.X), BTN_H)
		button.Position = UDim2.fromOffset(rl.AbsolutePosition.X, rl.AbsolutePosition.Y - BTN_H - GAP)
	end
end

function AutoShootController.Start()
	build()
	RunService.RenderStepped:Connect(follow)
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
