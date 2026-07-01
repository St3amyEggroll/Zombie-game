--!nonstrict
-- HUDController.lua — the in-game HUD, built fully in code with a clean professional style:
--   bottom-left : health bar (fill turns red when low) + HP number
--   top-center  : wave pill ("WAVE 7") — named RoundLabel (AutoShootController anchors to it)
--   top-right   : Coins (persistent) and Cash (this run) readouts
-- Element names (RoundLabel / PointsLabel / LobbyMoneyLabel / HealthLabel) are kept stable so other
-- controllers can find them by name.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local HUDController = {}

-- ===== STYLE (shared design system) =====
local COL_PANEL     = Color3.fromRGB(22, 24, 30)
local COL_TEXT      = Color3.fromRGB(238, 240, 245)
local COL_TEXT_DIM  = Color3.fromRGB(150, 156, 168)
local COL_ACCENT    = Color3.fromRGB(87, 196, 116)
local COL_DANGER    = Color3.fromRGB(224, 82, 82)
local COL_GOLD      = Color3.fromRGB(235, 190, 85)
local COL_TRACK     = Color3.fromRGB(40, 44, 54)
local PANEL_ALPHA   = 0.15
local LOW_HP_PCT    = 0.4

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local healthFill, healthLabel, roundLabel, pointsLabel, coinsLabel
local healthPct = 1

-- ===== BUILD HELPERS =====
local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function hairline(o)
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Transparency = 0.92
	s.Thickness = 1
	s.Parent = o
end

local function panel(parent, name)
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = COL_PANEL
	f.BackgroundTransparency = PANEL_ALPHA
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 10)
	hairline(f)
	return f
end

local function text(parent, name, font, size, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextSize = size
	l.TextColor3 = color
	l.Text = ""
	l.Parent = parent
	return l
end

-- ===== BUILD =====
local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "GameHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4
	gui.Parent = playerGui

	-- Health (bottom-left): "HEALTH" caption, bar, HP number.
	local hp = panel(gui, "HealthPanel")
	hp.Position = UDim2.new(0, 16, 1, -78)
	hp.Size = UDim2.fromOffset(260, 62)

	local hpCaption = text(hp, "Caption", Enum.Font.GothamBold, 11, COL_TEXT_DIM)
	hpCaption.Position = UDim2.fromOffset(14, 8)
	hpCaption.Size = UDim2.fromOffset(120, 12)
	hpCaption.TextXAlignment = Enum.TextXAlignment.Left
	hpCaption.Text = "HEALTH"

	healthLabel = text(hp, "HealthLabel", Enum.Font.GothamBold, 14, COL_TEXT)
	healthLabel.AnchorPoint = Vector2.new(1, 0)
	healthLabel.Position = UDim2.new(1, -14, 0, 6)
	healthLabel.Size = UDim2.fromOffset(120, 16)
	healthLabel.TextXAlignment = Enum.TextXAlignment.Right
	healthLabel.Text = "100 / 100"

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(14, 30)
	track.Size = UDim2.new(1, -28, 0, 16)
	track.BackgroundColor3 = COL_TRACK
	track.BorderSizePixel = 0
	track.Parent = hp
	corner(track, 8)

	healthFill = Instance.new("Frame")
	healthFill.Name = "Fill"
	healthFill.Size = UDim2.fromScale(1, 1)
	healthFill.BackgroundColor3 = COL_ACCENT
	healthFill.BorderSizePixel = 0
	healthFill.Parent = track
	corner(healthFill, 8)

	-- Wave pill (top-center).
	local wave = panel(gui, "WavePanel")
	wave.AnchorPoint = Vector2.new(0.5, 0)
	wave.Position = UDim2.new(0.5, 0, 0, 12)
	wave.Size = UDim2.fromOffset(150, 40)

	roundLabel = text(wave, "RoundLabel", Enum.Font.GothamBlack, 19, COL_TEXT)
	roundLabel.Size = UDim2.fromScale(1, 1)
	roundLabel.Text = "WAVE 0"

	-- Currency (top-right): Coins over Cash.
	local cur = panel(gui, "CurrencyPanel")
	cur.AnchorPoint = Vector2.new(1, 0)
	cur.Position = UDim2.new(1, -16, 0, 12)
	cur.Size = UDim2.fromOffset(190, 66)

	local coinsCaption = text(cur, "CoinsCaption", Enum.Font.GothamBold, 11, COL_TEXT_DIM)
	coinsCaption.Position = UDim2.fromOffset(14, 8)
	coinsCaption.Size = UDim2.fromOffset(90, 14)
	coinsCaption.TextXAlignment = Enum.TextXAlignment.Left
	coinsCaption.Text = "COINS"

	coinsLabel = text(cur, "LobbyMoneyLabel", Enum.Font.GothamBold, 15, COL_GOLD)
	coinsLabel.AnchorPoint = Vector2.new(1, 0)
	coinsLabel.Position = UDim2.new(1, -14, 0, 7)
	coinsLabel.Size = UDim2.fromOffset(110, 16)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
	coinsLabel.Text = "0"

	local cashCaption = text(cur, "CashCaption", Enum.Font.GothamBold, 11, COL_TEXT_DIM)
	cashCaption.Position = UDim2.fromOffset(14, 36)
	cashCaption.Size = UDim2.fromOffset(90, 14)
	cashCaption.TextXAlignment = Enum.TextXAlignment.Left
	cashCaption.Text = "CASH"

	pointsLabel = text(cur, "PointsLabel", Enum.Font.GothamBold, 15, COL_ACCENT)
	pointsLabel.AnchorPoint = Vector2.new(1, 0)
	pointsLabel.Position = UDim2.new(1, -14, 0, 35)
	pointsLabel.Size = UDim2.fromOffset(110, 16)
	pointsLabel.TextXAlignment = Enum.TextXAlignment.Right
	pointsLabel.Text = "$0"
end

-- ===== UPDATES =====
local function setHealth(health, maxHealth)
	health = math.max(0, health)
	maxHealth = math.max(1, maxHealth)
	healthPct = math.clamp(health / maxHealth, 0, 1)
	healthLabel.Text = ("%d / %d"):format(math.floor(health + 0.5), math.floor(maxHealth + 0.5))
	TweenService:Create(healthFill, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(healthPct, 1),
		BackgroundColor3 = (healthPct <= LOW_HP_PCT) and COL_DANGER or COL_ACCENT,
	}):Play()
end

-- ===== LIFECYCLE =====
function HUDController.Start()
	build()

	Remotes.Get("HealthChanged").OnClientEvent:Connect(setHealth)
	Remotes.Get("RoundChanged").OnClientEvent:Connect(function(round)
		roundLabel.Text = "WAVE " .. tostring(round)
	end)
	Remotes.Get("PointsChanged").OnClientEvent:Connect(function(points)
		pointsLabel.Text = "$" .. Util.FormatNumber(points)
	end)
	Remotes.Get("DataReady").OnClientEvent:Connect(function(data)
		if typeof(data) == "table" and data.lobbyMoney then
			coinsLabel.Text = Util.FormatNumber(data.lobbyMoney)
		end
	end)
	Remotes.Get("LobbyMoneyChanged").OnClientEvent:Connect(function(total)
		coinsLabel.Text = Util.FormatNumber(total)
	end)

	-- Seed initial values.
	setHealth(GameConfig.PlayerMaxHealth, GameConfig.PlayerMaxHealth)
	pointsLabel.Text = "$" .. Util.FormatNumber(GameConfig.StartingPoints)

	print("[HUDController] started (styled HUD)")
end

return HUDController
