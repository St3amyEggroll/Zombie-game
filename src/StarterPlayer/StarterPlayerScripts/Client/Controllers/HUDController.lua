--!nonstrict
-- HUDController.lua — the in-game HUD, built fully in code with a clean professional style:
--   bottom-left : health bar (fill turns red when low) + HP number
--   top-center  : wave pill ("WAVE 7") — named RoundLabel (AutoShootController anchors to it)
--   top-right   : Coins (persistent) and Cash (this run) readouts
-- Element names (RoundLabel / PointsLabel / LobbyMoneyLabel / HealthLabel) are kept stable so other
-- controllers can find them by name.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local BuffConfig = require(Config.BuffConfig)     -- rarity colors for the potion buff chips
local PotionConfig = require(Config.PotionConfig) -- potion type labels (DMG / REGEN)
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

local healthFill, healthLabel, roundLabel, pointsLabel, coinsLabel, breakLabel, incomingLabel
local potionRow        -- chip row ABOVE the health bar: one chip per ACTIVE potion buff
local potionChips = {} -- { {timeLabel, endsAt, base} } (countdowns tick client-side)
local healthPct = 1

local RARITY_COLOR = {}
for _, r in BuffConfig.Rarities do
	RARITY_COLOR[r.id] = r.color
end
local breakEndsAt = 0   -- os.clock() the wave break ends (drives the NEXT WAVE countdown)
local incomingToken = 0 -- invalidates stale INCOMING hide timers

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

	-- Active potion buffs (chips right above the health bar): "DMG +30% - 42s" tinted by the potion's rarity.
	potionRow = Instance.new("Frame")
	potionRow.Name = "PotionBuffs"
	potionRow.AnchorPoint = Vector2.new(0, 1)
	potionRow.Position = UDim2.new(0, 16, 1, -84) -- sits on top of the HealthPanel
	potionRow.Size = UDim2.fromOffset(420, 24)
	potionRow.BackgroundTransparency = 1
	potionRow.Parent = gui
	local rowList = Instance.new("UIListLayout")
	rowList.FillDirection = Enum.FillDirection.Horizontal
	rowList.Padding = UDim.new(0, 6)
	rowList.VerticalAlignment = Enum.VerticalAlignment.Bottom
	rowList.Parent = potionRow

	-- Wave number (top-center, just below the run XP bar): plain large white text, no panel.
	roundLabel = text(gui, "RoundLabel", Enum.Font.GothamBlack, 30, Color3.fromRGB(255, 255, 255))
	roundLabel.AnchorPoint = Vector2.new(0.5, 0)
	roundLabel.Position = UDim2.new(0.5, 0, 0, 44)
	roundLabel.Size = UDim2.fromOffset(300, 36)
	roundLabel.Text = "WAVE 0"
	local waveStroke = Instance.new("UIStroke") -- thin dark outline so white text reads on bright skies
	waveStroke.Color = Color3.fromRGB(0, 0, 0)
	waveStroke.Transparency = 0.4
	waveStroke.Thickness = 1.5
	waveStroke.Parent = roundLabel

	-- NEXT WAVE countdown (under the wave number, only during the wave break).
	breakLabel = text(gui, "BreakLabel", Enum.Font.GothamBold, 16, COL_TEXT_DIM)
	breakLabel.AnchorPoint = Vector2.new(0.5, 0)
	breakLabel.Position = UDim2.new(0.5, 0, 0, 80)
	breakLabel.Size = UDim2.fromOffset(300, 20)
	breakLabel.Text = ""

	-- INCOMING! banner (below the wave counter, above the kill-streak flair).
	incomingLabel = text(gui, "IncomingLabel", Enum.Font.GothamBlack, 20, Color3.fromRGB(255, 120, 90))
	incomingLabel.AnchorPoint = Vector2.new(0.5, 0)
	incomingLabel.Position = UDim2.new(0.5, 0, 0, 102)
	incomingLabel.Size = UDim2.fromOffset(520, 26)
	incomingLabel.Text = ""
	incomingLabel.Visible = false
	local incStroke = Instance.new("UIStroke")
	incStroke.Color = Color3.fromRGB(0, 0, 0)
	incStroke.Transparency = 0.4
	incStroke.Thickness = 1.5
	incStroke.Parent = incomingLabel

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
		breakEndsAt = 0
	end)

	-- Pre-run countdown (waiting for the party to load in): shown in the wave slot until the run starts.
	Remotes.Get("StartCountdown").OnClientEvent:Connect(function(secs)
		secs = tonumber(secs) or 0
		if secs > 0 then
			roundLabel.Text = ("STARTING IN %d"):format(secs)
		end
	end)

	-- Between waves: run the NEXT WAVE countdown under the wave number.
	Remotes.Get("MatchStateChanged").OnClientEvent:Connect(function(phase)
		if phase == "RoundBreak" then
			breakEndsAt = os.clock() + GameConfig.RoundBreakSeconds
		else
			breakEndsAt = 0
		end
	end)
	RunService.RenderStepped:Connect(function()
		if breakEndsAt > 0 and os.clock() < breakEndsAt then
			breakLabel.Text = ("NEXT WAVE IN %d"):format(math.ceil(breakEndsAt - os.clock()))
		elseif breakLabel.Text ~= "" then
			breakLabel.Text = ""
		end
		-- Tick the potion chip countdowns (the server also re-pushes when a buff actually expires).
		local now = os.clock()
		for _, chip in potionChips do
			local left = chip.endsAt - now
			if left > 0 then
				chip.timeLabel.Text = ("%s · %ds"):format(chip.base, math.ceil(left))
			elseif chip.frame.Visible then
				chip.frame.Visible = false
			end
		end
	end)

	-- Active potion buffs strip: rebuild the chips on every server push.
	Remotes.Get("PotionBuffsChanged").OnClientEvent:Connect(function(list)
		for _, chip in potionChips do
			chip.frame:Destroy()
		end
		potionChips = {}
		if typeof(list) ~= "table" then
			return
		end
		for _, b in list do
			if typeof(b) == "table" and b.type then
				local tinfo = PotionConfig.Types[b.type]
				local col = RARITY_COLOR[b.rarity] or COL_TEXT
				local base = ("%s +%d%%"):format(tinfo and tinfo.hud or tostring(b.type):upper(),
					math.floor((tonumber(b.pct) or 0) * 100 + 0.5))
				local chip = Instance.new("Frame")
				chip.Size = UDim2.fromOffset(118, 24)
				chip.BackgroundColor3 = COL_PANEL
				chip.BackgroundTransparency = PANEL_ALPHA
				chip.BorderSizePixel = 0
				chip.Parent = potionRow
				corner(chip, 6)
				local cs = Instance.new("UIStroke")
				cs.Color = col
				cs.Transparency = 0.35
				cs.Thickness = 1.2
				cs.Parent = chip
				local lbl = text(chip, "Label", Enum.Font.GothamBold, 12, col)
				lbl.Size = UDim2.fromScale(1, 1)
				lbl.Text = base
				table.insert(potionChips, {
					frame = chip,
					timeLabel = lbl,
					base = base,
					endsAt = os.clock() + (tonumber(b.remaining) or 0),
				})
			end
		end
	end)

	-- "INCOMING!" — a NEW enemy type just spawned for the first time this run.
	Remotes.Get("EnemyIncoming").OnClientEvent:Connect(function(typeName)
		incomingLabel.Text = ("INCOMING!  New enemy: %s"):format(tostring(typeName))
		incomingLabel.Visible = true
		incomingToken += 1
		local myToken = incomingToken
		task.delay(4, function()
			if incomingToken == myToken then
				incomingLabel.Visible = false
			end
		end)
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
