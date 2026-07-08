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
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local ProgressionConfig = require(Config.ProgressionConfig)
local BuffConfig = require(Config.BuffConfig)     -- rarity colors
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)
local UITheme = require(Modules.UITheme)

local HUDController = {}

-- ===== STYLE (UITheme — gritty apocalypse) =====
local COL_PANEL     = UITheme.PANEL
local COL_TEXT      = UITheme.TEXT
local COL_TEXT_DIM  = UITheme.DIM
local COL_ACCENT    = UITheme.TOXIC
local COL_DANGER    = UITheme.ORANGE
local COL_GOLD      = UITheme.GOLD
local COL_TRACK     = UITheme.TRACK
local PANEL_ALPHA   = 0.06
local LOW_HP_PCT    = 0.4

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local healthFill, healthLabel, roundLabel, pointsLabel, coinsLabel, breakLabel, announceLabel
local levelLabel, levelFill
local enemiesTrack, enemiesFill, enemiesLabel
local healthPct = 1

local RARITY_COLOR = {}
for _, r in BuffConfig.Rarities do
	RARITY_COLOR[r.id] = r.color
end
local breakEndsAt = 0   -- os.clock() the wave break ends (drives the NEXT WAVE countdown)

-- ===== BUILD HELPERS =====
local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function panel(parent, name)
	local f = UITheme.Panel(parent, name, { alpha = PANEL_ALPHA, radius = 6 })
	return f
end

local function text(parent, name, font, size, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font
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
	gui.DisplayOrder = UITheme.Layer.HUD
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- ===== BOTTOM-LEFT: health panel (caption 12 / value 16 on the shared scale, no frame overlap) =====
	local hp = panel(gui, "HealthPanel")
	hp.Position = UDim2.new(0, 16, 1, -(64 + 16))
	hp.Size = UDim2.fromOffset(240, 64)

	local hpCaption = text(hp, "Caption", UITheme.BodyBoldFace, UITheme.Type.Caption, COL_TEXT_DIM)
	hpCaption.Position = UDim2.fromOffset(14, 6)
	hpCaption.Size = UDim2.fromOffset(90, 14)
	hpCaption.TextXAlignment = Enum.TextXAlignment.Left
	hpCaption.Text = "HEALTH"

	healthLabel = text(hp, "HealthLabel", UITheme.BodyBoldFace, UITheme.Type.Value, COL_TEXT)
	healthLabel.AnchorPoint = Vector2.new(1, 0)
	healthLabel.Position = UDim2.new(1, -14, 0, 4)
	healthLabel.Size = UDim2.new(1, -122, 0, 18) -- starts where the caption box ends: no overlap
	healthLabel.TextXAlignment = Enum.TextXAlignment.Right
	healthLabel.TextTruncate = Enum.TextTruncate.AtEnd
	healthLabel.Text = "100 / 100"

	local track
	track, healthFill = UITheme.Bar(hp, "Track", COL_ACCENT)
	track.Position = UDim2.fromOffset(14, 34)
	track.Size = UDim2.new(1, -28, 0, 16)

	-- ===== TOP-CENTER: ONE lane owns the whole stack ===== (enemies bar+buttons → wave → countdown →
	-- announcements → boss bar). A UIListLayout does the spacing — no more hand-tuned magic offsets, and
	-- hidden elements collapse instead of leaving holes.
	local lane = Instance.new("Frame")
	lane.Name = "TopLane"
	lane.AnchorPoint = Vector2.new(0.5, 0)
	lane.Position = UDim2.new(0.5, 0, 0, 14)
	lane.Size = UDim2.fromOffset(700, 0)
	lane.AutomaticSize = Enum.AutomaticSize.Y
	lane.BackgroundTransparency = 1
	lane.Parent = gui
	local laneList = Instance.new("UIListLayout")
	laneList.FillDirection = Enum.FillDirection.Vertical
	laneList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	laneList.SortOrder = Enum.SortOrder.LayoutOrder
	laneList.Padding = UDim.new(0, UITheme.Space.Row)
	laneList.Parent = lane

	-- Row 1: enemies-left bar, with the small SKIP WAVE (Robux) + LEAVE pair right beside it.
	-- The row is symmetric around the track so the bar stays exactly screen-centered.
	local waveRow = Instance.new("Frame")
	waveRow.Name = "WaveRow"
	waveRow.BackgroundTransparency = 1
	waveRow.Size = UDim2.fromOffset(178 + 340 + 178, 26)
	waveRow.LayoutOrder = 10
	waveRow.Parent = lane

	enemiesTrack = Instance.new("Frame")
	enemiesTrack.Name = "EnemiesTrack"
	enemiesTrack.Position = UDim2.fromOffset(178, 0)
	enemiesTrack.Size = UDim2.fromOffset(340, 26)
	enemiesTrack.BackgroundColor3 = COL_TRACK
	enemiesTrack.BackgroundTransparency = 0.15
	enemiesTrack.BorderSizePixel = 0
	enemiesTrack.Visible = false
	enemiesTrack.Parent = waveRow
	UITheme.Corner(enemiesTrack, 5) -- through the theme curve like every other surface (was a raw radius)
	UITheme.Edge(enemiesTrack, UITheme.BLACK, 2)

	enemiesFill = Instance.new("Frame")
	enemiesFill.Name = "Fill"
	enemiesFill.Size = UDim2.fromScale(1, 1)
	enemiesFill.BackgroundColor3 = COL_DANGER
	enemiesFill.BorderSizePixel = 0
	enemiesFill.Parent = enemiesTrack
	UITheme.Corner(enemiesFill, 5)

	enemiesLabel = text(enemiesTrack, "EnemiesLabel", UITheme.BodyBoldFace, UITheme.Type.Value, COL_TEXT)
	enemiesLabel.Size = UDim2.fromScale(1, 1)
	enemiesLabel.ZIndex = 2
	enemiesLabel.TextXAlignment = Enum.TextXAlignment.Center
	enemiesLabel.Text = ""
	local enStroke = Instance.new("UIStroke")
	enStroke.Color = Color3.fromRGB(0, 0, 0)
	enStroke.Transparency = 0.35
	enStroke.Thickness = 1.5
	enStroke.Parent = enemiesLabel

	-- SKIP WAVE (Robux dev product) + LEAVE, small, right beside the bar. Skip prompts the purchase
	-- (GameConfig.SkipWaveProductId — 0 = not set up yet); Leave banks the run and returns to the lobby.
	local skipBtn = UITheme.Button(waveRow, "SKIP WAVE", "gold")
	skipBtn.Name = "SkipWaveButton"
	skipBtn.Position = UDim2.fromOffset(178 + 340 + 8, 0)
	skipBtn.Size = UDim2.fromOffset(82, 26)
	skipBtn.TextSize = UITheme.Type.Caption
	skipBtn.Activated:Connect(function()
		local id = tonumber(GameConfig.SkipWaveProductId) or 0
		if id > 0 then
			MarketplaceService:PromptProductPurchase(localPlayer, id)
		else
			warn("[HUD] SKIP WAVE: set GameConfig.SkipWaveProductId to your Developer Product id")
		end
	end)

	local leaveBtn = UITheme.Button(waveRow, "LEAVE", "danger")
	leaveBtn.Name = "LeaveButton"
	leaveBtn.Position = UDim2.fromOffset(178 - 8 - 82, 0) -- LEFT of the bar (skip sits on the right)
	leaveBtn.Size = UDim2.fromOffset(82, 26)
	leaveBtn.TextSize = UITheme.Type.Caption
	leaveBtn.Activated:Connect(function()
		Remotes.Get("LeaveRun"):FireServer()
	end)

	-- Row 2: the wave number (Screen tier — the ambient anchor; alerts at Item tier now read as louder events).
	roundLabel = text(lane, "RoundLabel", UITheme.TitleFace, UITheme.Type.Screen, COL_TEXT)
	roundLabel.Size = UDim2.fromOffset(320, 32)
	roundLabel.LayoutOrder = 20
	roundLabel.TextTruncate = Enum.TextTruncate.AtEnd
	roundLabel.Text = "WAVE 0"
	local waveStroke = Instance.new("UIStroke") -- thin dark outline so white text reads on bright skies
	waveStroke.Color = Color3.fromRGB(0, 0, 0)
	waveStroke.Transparency = 0.4
	waveStroke.Thickness = 1.5
	waveStroke.Parent = roundLabel

	-- Row 3: NEXT WAVE countdown (collapses out of the lane whenever it's empty).
	breakLabel = text(lane, "BreakLabel", UITheme.BodyBoldFace, UITheme.Type.Value, COL_TEXT_DIM)
	breakLabel.Size = UDim2.fromOffset(300, 20)
	breakLabel.LayoutOrder = 30
	breakLabel.Visible = false
	breakLabel.Text = ""

	-- Row 4: the ANNOUNCEMENT slot — one label, fed by a queue (INCOMING!, FLAWLESS, crate drops...).
	-- Simultaneous events take turns instead of printing on top of each other.
	announceLabel = text(lane, "AnnounceLabel", UITheme.TitleFace, UITheme.Type.Item, COL_GOLD)
	announceLabel.Size = UDim2.fromOffset(560, 28)
	announceLabel.LayoutOrder = 40
	announceLabel.Visible = false
	announceLabel.TextTruncate = Enum.TextTruncate.AtEnd
	announceLabel.Text = ""
	local anStroke = Instance.new("UIStroke")
	anStroke.Color = Color3.fromRGB(0, 0, 0)
	anStroke.Transparency = 0.4
	anStroke.Thickness = 1.5
	anStroke.Parent = announceLabel
	-- (Row 5 — LayoutOrder 50 — is the boss bar; BossController parents it into this lane.)

	-- ===== TOP-RIGHT: currency panel (same recipe + metrics as the health panel) =====
	local cur = panel(gui, "CurrencyPanel")
	cur.AnchorPoint = Vector2.new(1, 0)
	cur.Position = UDim2.new(1, -16, 0, 14)
	cur.Size = UDim2.fromOffset(240, 64)

	local coinsCaption = text(cur, "CoinsCaption", UITheme.BodyBoldFace, UITheme.Type.Caption, COL_TEXT_DIM)
	coinsCaption.Position = UDim2.fromOffset(14, 8)
	coinsCaption.Size = UDim2.fromOffset(90, 14)
	coinsCaption.TextXAlignment = Enum.TextXAlignment.Left
	coinsCaption.Text = "COINS"

	coinsLabel = text(cur, "LobbyMoneyLabel", UITheme.BodyBoldFace, UITheme.Type.Value, COL_GOLD)
	coinsLabel.AnchorPoint = Vector2.new(1, 0)
	coinsLabel.Position = UDim2.new(1, -14, 0, 6)
	coinsLabel.Size = UDim2.new(1, -122, 0, 18) -- no overlap with the caption; long totals truncate
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
	coinsLabel.TextTruncate = Enum.TextTruncate.AtEnd
	coinsLabel.Text = "0"

	local cashCaption = text(cur, "CashCaption", UITheme.BodyBoldFace, UITheme.Type.Caption, COL_TEXT_DIM)
	cashCaption.Position = UDim2.fromOffset(14, 36)
	cashCaption.Size = UDim2.fromOffset(90, 14)
	cashCaption.TextXAlignment = Enum.TextXAlignment.Left
	cashCaption.Text = "CASH"

	pointsLabel = text(cur, "PointsLabel", UITheme.BodyBoldFace, UITheme.Type.Value, COL_ACCENT)
	pointsLabel.AnchorPoint = Vector2.new(1, 0)
	pointsLabel.Position = UDim2.new(1, -14, 0, 34)
	pointsLabel.Size = UDim2.new(1, -122, 0, 18)
	pointsLabel.TextXAlignment = Enum.TextXAlignment.Right
	pointsLabel.TextTruncate = Enum.TextTruncate.AtEnd
	pointsLabel.Text = "$0"

	-- ===== BOTTOM-RIGHT: account LEVEL (above the settings gear; the SKIN CRATES button stacks above it).
	local lp = panel(gui, "LevelPanel")
	lp.AnchorPoint = Vector2.new(1, 1)
	lp.Position = UDim2.new(1, -12, 1, -(12 + UITheme.Ctl.Std + 8)) -- directly above the gear
	lp.Size = UDim2.fromOffset(220, 44)

	levelLabel = text(lp, "LevelLabel", UITheme.TitleFace, UITheme.Type.Section, COL_ACCENT)
	levelLabel.Position = UDim2.fromOffset(14, 4)
	levelLabel.Size = UDim2.new(1, -28, 0, 20)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Left
	levelLabel.Text = "LVL 1"
	local lvStroke = Instance.new("UIStroke")
	lvStroke.Color = Color3.fromRGB(0, 0, 0)
	lvStroke.Transparency = 0.35
	lvStroke.Thickness = 1.5
	lvStroke.Parent = levelLabel

	local lvTrack
	lvTrack, levelFill = UITheme.Bar(lp, "XPTrack", COL_ACCENT)
	lvTrack.Position = UDim2.fromOffset(14, 28)
	lvTrack.Size = UDim2.new(1, -28, 0, 8)
	levelFill.Size = UDim2.fromScale(0, 1)
end

-- Account XP -> the bottom-right level readout (shared curve with the lobby).
local function setXP(totalXP)
	local level, into, need = ProgressionConfig.LevelForXP(tonumber(totalXP) or 0)
	if levelLabel then
		levelLabel.Text = "LVL " .. level
	end
	if levelFill then
		levelFill.Size = UDim2.fromScale(need > 0 and math.clamp(into / need, 0, 1) or 1, 1)
	end
end

-- ===== ANNOUNCEMENT QUEUE ===== one slot in the top lane; events take turns. Other controllers
-- (crate toasts etc.) can call HUDController.Announce(text, color, seconds) too.
local announceQueue = {}
local announceBusy = false
function HUDController.Announce(textStr: string, color: Color3?, dur: number?)
	table.insert(announceQueue, { text = tostring(textStr), color = color or COL_GOLD, dur = dur or 3.5 })
	if announceBusy or not announceLabel then
		return
	end
	announceBusy = true
	task.spawn(function()
		while #announceQueue > 0 do
			local a = table.remove(announceQueue, 1)
			announceLabel.Text = a.text
			announceLabel.TextColor3 = a.color
			announceLabel.Visible = true
			task.wait(a.dur)
			announceLabel.Visible = false
			task.wait(0.15) -- a beat between back-to-back announcements
		end
		announceBusy = false
	end)
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
		breakEndsAt = 0
		if tonumber(round) == 1 then
			-- The round-start audio leads by 1s; the text lands on its beat.
			task.delay(1, function()
				roundLabel.Text = "WAVE " .. tostring(round)
			end)
		else
			roundLabel.Text = "WAVE " .. tostring(round)
		end
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
		if enemiesTrack and phase ~= "Playing" then
			enemiesTrack.Visible = false -- no live wave between rounds / in the lobby countdown
		end
	end)

	-- Enemies left to kill this wave — the count bar under the wave number.
	Remotes.Get("WaveProgress").OnClientEvent:Connect(function(remaining, total)
		remaining = tonumber(remaining) or 0
		total = tonumber(total) or 0
		if total <= 0 or remaining <= 0 then
			enemiesTrack.Visible = false
			return
		end
		enemiesTrack.Visible = true
		enemiesLabel.Text = ("%d %s LEFT"):format(remaining, remaining == 1 and "ENEMY" or "ENEMIES")
		TweenService:Create(enemiesFill, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(math.clamp(remaining / total, 0, 1), 1),
		}):Play()
	end)
	RunService.RenderStepped:Connect(function()
		if breakEndsAt > 0 and os.clock() < breakEndsAt then
			breakLabel.Text = ("NEXT WAVE IN %d"):format(math.ceil(breakEndsAt - os.clock()))
			breakLabel.Visible = true
		elseif breakLabel.Visible then
			breakLabel.Text = ""
			breakLabel.Visible = false -- collapses its lane slot
		end
	end)

	-- Event banners ride the announcement QUEUE — simultaneous events take turns in the one slot.
	Remotes.Get("EnemyIncoming").OnClientEvent:Connect(function(typeName)
		HUDController.Announce(("INCOMING!  New enemy: %s"):format(tostring(typeName)), COL_DANGER, 4)
	end)
	Remotes.Get("FlawlessWave").OnClientEvent:Connect(function(streak, mult)
		streak = tonumber(streak) or 1
		mult = tonumber(mult) or 1
		local msg = (streak > 1)
			and ("FLAWLESS WAVE ×%d  —  Coins ×%.2f"):format(streak, mult)
			or "FLAWLESS WAVE!"
		HUDController.Announce(msg, COL_GOLD, 3.5)
	end)

	Remotes.Get("PointsChanged").OnClientEvent:Connect(function(points)
		pointsLabel.Text = "$" .. Util.FormatNumber(points)
	end)
	Remotes.Get("DataReady").OnClientEvent:Connect(function(data)
		if typeof(data) == "table" and data.lobbyMoney then
			coinsLabel.Text = Util.FormatNumber(data.lobbyMoney)
		end
		if typeof(data) == "table" and data.xp ~= nil then
			setXP(data.xp)
		end
	end)
	Remotes.Get("ProgressChanged").OnClientEvent:Connect(function(xp)
		setXP(xp)
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
