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
local UITheme = require(Modules.UITheme)

-- Screen shake for the boss entrance (GUARDED: a broken FX controller must never brick the boss bar).
local okFx, CombatFeedbackController = pcall(require, script.Parent.CombatFeedbackController)
if not okFx or type(CombatFeedbackController) ~= "table" then
	CombatFeedbackController = { ShakeOnce = function() end }
end

local BossController = {}

-- ===== TUNABLES (UITheme — gritty apocalypse) =====
local FILL_COLOR   = UITheme.ORANGE
local BANNER_COLOR = UITheme.ORANGE
local WIN_COLOR    = UITheme.GOLD
local BAR_W, BAR_H = 620, 26

local localPlayer = Players.LocalPlayer
local barHolder, fill, nameLabel, banner

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "BossHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.Boss
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui)

	barHolder = Instance.new("Frame")
	barHolder.Name = "BossBar"
	barHolder.Size = UDim2.fromOffset(BAR_W, BAR_H)
	barHolder.BackgroundColor3 = UITheme.Darker(UITheme.TRACK, 0.3)
	barHolder.BackgroundTransparency = 0.08
	barHolder.BorderSizePixel = 0
	barHolder.Visible = false
	barHolder.LayoutOrder = 50 -- bottom slot of the HUD's top-center lane
	barHolder.Parent = gui
	UITheme.Corner(barHolder, 4)
	UITheme.Edge(barHolder, UITheme.BLACK, 2)

	-- Join the HUD's TopLane (one list-layout container owns the whole top-center stack now — no more
	-- hand-tuned "y=82, below the wave number" offsets dodging another file's elements).
	task.spawn(function()
		local hud = localPlayer:WaitForChild("PlayerGui"):WaitForChild("GameHUD", 10)
		local lane = hud and hud:WaitForChild("TopLane", 10)
		if lane then
			barHolder.Parent = lane
		else -- lane missing (HUD failed?) — fall back to a fixed spot in our own gui
			barHolder.AnchorPoint = Vector2.new(0.5, 0)
			barHolder.Position = UDim2.new(0.5, 0, 0, 96)
		end
	end)

	fill = Instance.new("Frame")
	fill.Name = "BossBarFill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = FILL_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = barHolder
	UITheme.Corner(fill, 4)
	local fg = Instance.new("UIGradient")
	fg.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(140, 140, 140))
	fg.Rotation = 90
	fg.Parent = fill

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "BossName"
	nameLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	nameLabel.Position = UDim2.fromScale(0.5, 0.5)
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.BackgroundTransparency = 1
	nameLabel.FontFace = UITheme.TitleFace
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
	banner.Position = UDim2.fromScale(0.5, 0.34) -- its own band, clear of the killstreak banner at 0.19
	banner.Size = UDim2.fromOffset(560, 44)
	banner.BackgroundTransparency = 1
	banner.FontFace = UITheme.TitleFace
	banner.TextScaled = true
	banner.TextColor3 = BANNER_COLOR
	banner.TextStrokeTransparency = 0.3
	banner.TextTransparency = 1
	banner.Text = ""
	banner.Parent = gui
	local cap = Instance.new("UITextSizeConstraint") -- Hero tier is the ceiling — no more ~80px runaway text
	cap.MaxTextSize = UITheme.Type.Hero
	cap.Parent = banner
	Instance.new("UIScale").Parent = banner
end

local bannerToken = 0
local function flashBanner(text: string, color: Color3)
	banner.Text = text
	banner.TextColor3 = color
	banner.TextTransparency = 0
	banner.TextStrokeTransparency = 0.3
	local s = banner:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	s.Parent = banner
	s.Scale = 1.4
	TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	bannerToken += 1
	local my = bannerToken -- a NEWER banner cancels this fade (back-to-back banners no longer cut short)
	task.delay(2, function()
		if bannerToken == my then
			TweenService:Create(banner, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

local function onSpawned(name: string?, maxHealth: number?)
	local title = (name or "BOSS"):upper()
	nameLabel.Text = title
	fill.Size = UDim2.fromScale(1, 1)
	barHolder.Visible = true
	flashBanner("- " .. title .. " -", BANNER_COLOR)
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
