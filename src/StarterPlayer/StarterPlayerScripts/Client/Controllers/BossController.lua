--!nonstrict
-- BossController.lua — the boss health bar (top of screen) + entrance/defeat banners. The server drives it:
-- BossSpawned(name, maxHealth) shows the bar + entrance, BossHealth(h, max) updates the fill, BossDefeated
-- hides it. Builds its own UI so it works out of the box; restyle later by replacing these named elements:
--   BossBar (Frame), BossBarFill (Frame inside it), BossName (TextLabel), BossBanner (TextLabel).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

-- Screen shake for the boss entrance (GUARDED: a broken FX controller must never brick the boss bar).
local okFx, CombatFeedbackController = pcall(require, script.Parent.CombatFeedbackController)
if not okFx or type(CombatFeedbackController) ~= "table" then
	CombatFeedbackController = { ShakeOnce = function() end }
end

local BossController = {}

-- ===== TUNABLES =====
local FILL_COLOR   = Color3.fromRGB(200, 40, 40)
local BANNER_COLOR = Color3.fromRGB(255, 60, 60)
local WIN_COLOR    = Color3.fromRGB(255, 220, 80)
local BAR_W, BAR_H = 620, 26

local localPlayer = Players.LocalPlayer
local barHolder, fill, nameLabel, banner

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "BossHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 8
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	barHolder = Instance.new("Frame")
	barHolder.Name = "BossBar"
	barHolder.AnchorPoint = Vector2.new(0.5, 0)
	barHolder.Position = UDim2.fromScale(0.5, 0.06)
	barHolder.Size = UDim2.fromOffset(BAR_W, BAR_H)
	barHolder.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	barHolder.BackgroundTransparency = 0.25
	barHolder.BorderSizePixel = 0
	barHolder.Visible = false
	barHolder.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 2
	stroke.Parent = barHolder

	fill = Instance.new("Frame")
	fill.Name = "BossBarFill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = FILL_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = barHolder

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "BossName"
	nameLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	nameLabel.Position = UDim2.fromScale(0.5, 0.5)
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.Text = "BOSS"
	nameLabel.Parent = barHolder
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = nameLabel

	banner = Instance.new("TextLabel")
	banner.Name = "BossBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.3)
	banner.Size = UDim2.fromOffset(760, 84)
	banner.BackgroundTransparency = 1
	banner.Font = Enum.Font.GothamBlack
	banner.TextScaled = true
	banner.TextColor3 = BANNER_COLOR
	banner.TextStrokeTransparency = 0.3
	banner.TextTransparency = 1
	banner.Text = ""
	banner.Parent = gui
	Instance.new("UIScale").Parent = banner
end

local function flashBanner(text: string, color: Color3)
	banner.Text = text
	banner.TextColor3 = color
	banner.TextTransparency = 0
	banner.TextStrokeTransparency = 0.3
	local s = banner:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	s.Parent = banner
	s.Scale = 1.4
	TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(2, function()
		TweenService:Create(banner, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
end

local function onSpawned(name: string?, maxHealth: number?)
	local title = (name or "BOSS"):upper()
	nameLabel.Text = title
	fill.Size = UDim2.fromScale(1, 1)
	barHolder.Visible = true
	flashBanner("⚠  " .. title .. "  ⚠", BANNER_COLOR)
	CombatFeedbackController.ShakeOnce(1.4, 0.5, 16, 0.4) -- the ground shakes when the boss arrives
end

local function onHealth(h: number, maxHealth: number?)
	if not barHolder then
		return
	end
	barHolder.Visible = true
	local frac = (maxHealth and maxHealth > 0) and math.clamp(h / maxHealth, 0, 1) or 0
	TweenService:Create(fill, TweenInfo.new(0.15), { Size = UDim2.fromScale(frac, 1) }):Play()
end

local function onDefeated()
	if barHolder then
		barHolder.Visible = false
	end
	flashBanner("BOSS DEFEATED", WIN_COLOR)
end

function BossController.Start()
	build()
	Remotes.Get("BossSpawned").OnClientEvent:Connect(onSpawned)
	Remotes.Get("BossHealth").OnClientEvent:Connect(onHealth)
	Remotes.Get("BossDefeated").OnClientEvent:Connect(onDefeated)
	print("[BossController] started")
end

return BossController
