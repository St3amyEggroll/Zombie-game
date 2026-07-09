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

-- ===== TUNABLES (approved boss-fight plan) =====
local FILL_COLOR   = Color3.fromRGB(214, 58, 58)  -- fat RED bar
local BANNER_COLOR = Color3.fromRGB(255, 141, 122) -- the boss red (banner + name plate)
local WIN_COLOR    = UITheme.GOLD
local BAR_W, BAR_H = 460, 20

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

	-- Container in the TopLane: sticker NAME PLATE riding on top, the fat red pill bar under it.
	barHolder = Instance.new("Frame")
	barHolder.Name = "BossBar"
	barHolder.Size = UDim2.fromOffset(BAR_W, BAR_H + 28)
	barHolder.BackgroundTransparency = 1
	barHolder.Visible = false
	barHolder.LayoutOrder = 50 -- bottom slot of the HUD's top-center lane
	barHolder.Parent = gui

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

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "BossName"
	nameLabel.Position = UDim2.new(0, 0, 0, 0)
	nameLabel.Size = UDim2.new(1, 0, 0, 22)
	nameLabel.BackgroundTransparency = 1
	nameLabel.FontFace = UITheme.TitleFace
	nameLabel.TextSize = 19
	nameLabel.TextColor3 = BANNER_COLOR
	nameLabel.Text = "☠ BOSS"
	nameLabel.Parent = barHolder
	local ns = Instance.new("UIStroke")
	ns.Color = UITheme.BLACK
	ns.Thickness = 3 -- sticker outline, like the plan
	ns.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ns.Parent = nameLabel

	local track = Instance.new("Frame")
	track.Name = "BossTrack"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 0, 1, 0)
	track.Size = UDim2.new(1, 0, 0, BAR_H)
	track.BackgroundColor3 = UITheme.Darker(UITheme.TRACK, 0.35)
	track.BorderSizePixel = 0
	track.Parent = barHolder
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(1, 0) -- full pill
	tc.Parent = track
	UITheme.Edge(track, UITheme.BLACK, 3)

	fill = Instance.new("Frame")
	fill.Name = "BossBarFill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = FILL_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fc2 = Instance.new("UICorner")
	fc2.CornerRadius = UDim.new(1, 0)
	fc2.Parent = fill
	local fg = Instance.new("UIGradient")
	fg.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(120, 120, 120))
	fg.Rotation = 90
	fg.Parent = fill

	banner = Instance.new("TextLabel")
	banner.Name = "BossBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.34) -- its own band, clear of the killstreak banner at 0.19
	banner.Size = UDim2.fromOffset(560, 44)
	banner.BackgroundTransparency = 1
	banner.FontFace = UITheme.TitleFace
	banner.TextScaled = true
	banner.TextColor3 = BANNER_COLOR
	banner.TextTransparency = 1
	banner.Text = ""
	banner.Parent = gui
	local bs = Instance.new("UIStroke") -- proper sticker outline (the old TextStroke read thin)
	bs.Name = "BannerStroke"
	bs.Color = UITheme.BLACK
	bs.Thickness = 3.5
	bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	bs.Parent = banner
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
	local bst = banner:FindFirstChild("BannerStroke")
	if bst then
		bst.Transparency = 0
	end
	local s = banner:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	s.Parent = banner
	s.Scale = 1.4
	TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	bannerToken += 1
	local my = bannerToken -- a NEWER banner cancels this fade (back-to-back banners no longer cut short)
	task.delay(2, function()
		if bannerToken == my then
			TweenService:Create(banner, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
			local bst2 = banner:FindFirstChild("BannerStroke")
			if bst2 then
				TweenService:Create(bst2, TweenInfo.new(0.6), { Transparency = 1 }):Play()
			end
		end
	end)
end

local function onSpawned(name: string?, maxHealth: number?)
	local title = (name or "BOSS"):upper()
	nameLabel.Text = "☠ THE " .. title -- the plan's name plate: skull + THE <BOSS> riding the bar
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
