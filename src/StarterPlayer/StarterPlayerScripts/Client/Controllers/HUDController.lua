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
local WeaponConfig = require(Config.WeaponConfig) -- next-unlock headline on the LVL card
local ProgressionConfig = require(Config.ProgressionConfig)
local BuffConfig = require(Config.BuffConfig)     -- rarity colors
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)
local UITheme = require(Modules.UITheme)

local AutoShootController = require(script.Parent.AutoShootController) -- the dock's AUTOFIRE toggle
local SettingsController = require(script.Parent.SettingsController)   -- the dock's SETTINGS button
local LobbyLook = require(Modules.LobbyLook) -- the LOBBY's exact builders (dock buttons, chrome panels)

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
local COL_XP        = Color3.fromRGB(66, 165, 245) -- XP/level is BLUE
local LOW_HP_PCT    = 0.4

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local healthFill, healthLabel, roundLabel, coinsLabel, breakLabel, announceLabel
local coinPopScale -- UIScale on the coins label (pickup pop)
local coinTarget, coinShown, coinHoldUntil = 0, 0, 0 -- NEW: counter ticks up as loot coins land
local extractChip                    -- NEW: persistent "next cash-out / live payout multiplier" line
local extractMult, currentRound = 1, 0 -- so the extraction loop is legible BETWEEN the choice windows
local leaveBtn                        -- hoisted: hidden during an open extraction window (see below)
local levelLabel, levelFill
local lvlHeadline, lvlXPText -- the LVL card's next-unlock line + "x / y XP" bar overlay
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
	local c = f:FindFirstChildOfClass("UICorner")
	if c then
		c.CornerRadius = UDim.new(0, 8) -- crisp RECTANGLES (the theme curve made these pill-ish)
	end
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

	-- (HEALTH PANEL REMOVED — owner call, HUD renovation. The hurt flash / low-HP vignette / heartbeat
	-- in HealthFeedbackController carry damage state, and your own PARTY chip's ring shows your HP.)

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

	-- Row 1 (RENOVATION): ONE strip pill — [WAVE N][enemies bar][◇ cash-out chip] — replacing the old
	-- big wave text + separate bar + separate chip stack. LEAVE/SKIP moved to absolute TOP-RIGHT.
	local waveRow = panel(lane, "WaveStrip")
	waveRow.Size = UDim2.fromOffset(560, 40)
	waveRow.LayoutOrder = 10

	enemiesTrack = Instance.new("Frame")
	enemiesTrack.Name = "EnemiesTrack"
	enemiesTrack.Position = UDim2.fromOffset(150, 7)
	enemiesTrack.Size = UDim2.fromOffset(250, 26)
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

	-- SKIP WAVE (Robux dev product) + LEAVE — TOP-RIGHT now (out of the strip, away from combat).
	-- Skip prompts the purchase (GameConfig.SkipWaveProductId — 0 = warns); Leave banks + exits.
	local skipBtn = UITheme.Button(gui, "SKIP WAVE", "gold")
	skipBtn.Name = "SkipWaveButton"
	skipBtn.AnchorPoint = Vector2.new(1, 0)
	skipBtn.Position = UDim2.new(1, -16, 0, 14)
	skipBtn.Size = UDim2.fromOffset(100, 34)
	skipBtn.TextSize = UITheme.Type.Caption
	skipBtn.TextColor3 = Color3.fromRGB(255, 255, 255) -- readable white (the variant's dark text read as black)
	skipBtn.Activated:Connect(function()
		local id = tonumber(GameConfig.SkipWaveProductId) or 0
		if id > 0 then
			MarketplaceService:PromptProductPurchase(localPlayer, id)
		else
			warn("[HUD] SKIP WAVE: set GameConfig.SkipWaveProductId to your Developer Product id")
		end
	end)
	do -- NEW: show the live Robux price on the button once the product id is set
		local id = tonumber(GameConfig.SkipWaveProductId) or 0
		if id > 0 then
			task.spawn(function()
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
				end)
				if ok and info and tonumber(info.PriceInRobux) then
					skipBtn.Size = UDim2.fromOffset(112, 34)
					skipBtn.Text = ("SKIP  R$%d"):format(info.PriceInRobux)
				end
			end)
		end
	end

	leaveBtn = UITheme.Button(gui, "LEAVE", "danger")
	leaveBtn.Name = "LeaveButton"
	leaveBtn.AnchorPoint = Vector2.new(1, 0)
	leaveBtn.Position = UDim2.new(1, -(16 + 100 + 8), 0, 14) -- left of SKIP in the top-right pair
	leaveBtn.Size = UDim2.fromOffset(84, 34)
	leaveBtn.TextSize = UITheme.Type.Caption
	leaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	leaveBtn.Activated:Connect(function()
		Remotes.Get("LeaveRun"):FireServer()
	end)

	-- The wave number LIVES IN THE STRIP now (left slot) — same variable, so every updater still works.
	roundLabel = text(waveRow, "RoundLabel", UITheme.TitleFace, 20, COL_TEXT)
	roundLabel.Position = UDim2.fromOffset(14, 0)
	roundLabel.Size = UDim2.fromOffset(130, 40)
	roundLabel.TextXAlignment = Enum.TextXAlignment.Left
	roundLabel.TextTruncate = Enum.TextTruncate.AtEnd
	roundLabel.Text = "WAVE 0"
	local waveStroke = Instance.new("UIStroke") -- thin dark outline so white text reads on bright skies
	waveStroke.Color = Color3.fromRGB(0, 0, 0)
	waveStroke.Transparency = 0.4
	waveStroke.Thickness = 1.5
	waveStroke.Parent = roundLabel

	-- The EXTRACTION chip rides the strip's right slot — the "cash out or double down" rhythm stays
	-- legible BETWEEN the choice windows (next cash-out wave + the live payout multiplier).
	extractChip = text(waveRow, "ExtractChip", UITheme.BodyBoldFace, UITheme.Type.Value, COL_GOLD)
	extractChip.AnchorPoint = Vector2.new(1, 0)
	extractChip.Position = UDim2.new(1, -14, 0, 0)
	extractChip.Size = UDim2.fromOffset(148, 40)
	extractChip.TextXAlignment = Enum.TextXAlignment.Right
	extractChip.Visible = false
	extractChip.Text = ""

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

	-- ===== BOTTOM-LEFT: the COINS PILL — the lobby's, verbatim (dark rounded pill, coin icon, gold
	-- number, gold +). RENOVATION: no more stacked boxes; LVL moved to its own bottom-RIGHT card.
	local coinsPill = panel(gui, "CoinsPill")
	coinsPill.AnchorPoint = Vector2.new(0, 1)
	coinsPill.Position = UDim2.new(0, 16, 1, -14)
	coinsPill.Size = UDim2.fromOffset(252, 54)

	local coinImg = Instance.new("ImageLabel")
	coinImg.Name = "CoinIcon"
	coinImg.AnchorPoint = Vector2.new(0, 0.5)
	coinImg.Position = UDim2.new(0, 8, 0.5, 0)
	coinImg.Size = UDim2.fromOffset(40, 40)
	coinImg.BackgroundTransparency = 1
	coinImg.ScaleType = Enum.ScaleType.Fit
	coinImg.Image = "rbxassetid://84729396970772"
	coinImg.Parent = coinsPill
	coinsLabel = text(coinsPill, "LobbyMoneyLabel", UITheme.TitleFace, 28, COL_GOLD)
	coinsLabel.Position = UDim2.new(0, 54, 0, 0)
	coinsLabel.Size = UDim2.new(1, -54 - 44, 1, 0)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinsLabel.TextTruncate = Enum.TextTruncate.AtEnd
	coinsLabel.Text = "0"
	local coinStroke = Instance.new("UIStroke")
	coinStroke.Color = Color3.fromRGB(0, 0, 0)
	coinStroke.Transparency = 0.35
	coinStroke.Thickness = 1.5
	coinStroke.Parent = coinsLabel
	coinPopScale = Instance.new("UIScale") -- pickup pop when a loot coin lands
	coinPopScale.Parent = coinsLabel

	-- ===== GET COINS (in-run coin bundles) ===== a small gold "+" beside the coin readout opens a
	-- buy card with the same Developer Products as the lobby shop (GameConfig.CoinBundleProducts).
	-- Being broke at the mid-run gun shop is the moment this exists for. Rows with id=0 say SOON.
	local bundles = GameConfig.CoinBundleProducts or {}
	-- The card rides its OWN modal-fit gui: in the HUD gui it would shrink with the phone HUD scale.
	local cardGui = Instance.new("ScreenGui")
	cardGui.Name = "CoinShop"
	cardGui.ResetOnSpawn = false
	cardGui.IgnoreGuiInset = true
	cardGui.DisplayOrder = UITheme.Layer.ShopModal
	cardGui.Parent = gui.Parent
	UITheme.Attach(cardGui, 404, 120 + #bundles * 56)
	-- LOBBY CHROME (owner: panels must match the lobby exactly): fat gold header bar, dark studded
	-- body, the juiced red X. `card` is the chrome ROOT — Visible toggles pop it open like the lobby.
	local card, cardBody, _, cardX = LobbyLook.ChromePanel(cardGui, 360, 24 + #bundles * 56, LobbyLook.HeaderColors.shop, "GET COINS")
	cardX.Activated:Connect(function()
		card.Visible = false
	end)
	for i, b in bundles do
		local row = UITheme.Button(cardBody, "", "gold")
		row.Name = "Bundle" .. i
		row.Position = UDim2.fromOffset(16, 16 + (i - 1) * 56)
		row.Size = UDim2.new(1, -32, 0, 46)
		row.TextSize = 17
		row.TextColor3 = Color3.fromRGB(255, 255, 255)
		local base = Util.FormatNumber(b.coins) .. " COINS" .. (b.bonus and ("  " .. b.bonus) or "")
		local bid = tonumber(b.id) or 0
		if bid > 0 then
			row.Text = base
			task.spawn(function()
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(bid, Enum.InfoType.Product)
				end)
				if ok and info and tonumber(info.PriceInRobux) then
					row.Text = base .. ("  —  R$%d"):format(info.PriceInRobux)
				end
			end)
			row.Activated:Connect(function()
				MarketplaceService:PromptProductPurchase(localPlayer, bid)
			end)
		else
			row.Text = base .. "  —  SOON"
			row.AutoButtonColor = false
		end
	end

	local plusBtn = UITheme.Button(coinsPill, "+", "gold")
	plusBtn.Name = "GetCoinsButton"
	plusBtn.AnchorPoint = Vector2.new(1, 0.5)
	plusBtn.Position = UDim2.new(1, -8, 0.5, 0)
	plusBtn.Size = UDim2.fromOffset(30, 30)
	plusBtn.TextSize = 22
	plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	plusBtn.Activated:Connect(function()
		card.Visible = not card.Visible
	end)
	HUDController.ToggleCoinShop = function() -- the dock's SHOP circle opens the same card
		card.Visible = not card.Visible
	end

	-- ===== BOTTOM-RIGHT: the LVL / XP card — the lobby's, verbatim (big blue LVL, next-unlock
	-- headline, XP bar with the numbers riding on it).
	local lp = panel(gui, "LevelCard")
	lp.AnchorPoint = Vector2.new(1, 1)
	lp.Position = UDim2.new(1, -16, 1, -14)
	lp.Size = UDim2.fromOffset(310, 62)

	levelLabel = text(lp, "LevelLabel", UITheme.TitleFace, 24, COL_XP)
	levelLabel.Position = UDim2.fromOffset(14, 0)
	levelLabel.Size = UDim2.fromOffset(92, 62)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Left
	levelLabel.Text = "LVL 1"
	local lvStroke = Instance.new("UIStroke")
	lvStroke.Color = Color3.fromRGB(0, 0, 0)
	lvStroke.Transparency = 0.35
	lvStroke.Thickness = 1.5
	lvStroke.Parent = levelLabel

	lvlHeadline = text(lp, "Headline", UITheme.BodyBoldFace, 12, UITheme.TOXIC_HI or COL_ACCENT)
	lvlHeadline.Position = UDim2.fromOffset(108, 8)
	lvlHeadline.Size = UDim2.new(1, -122, 0, 16)
	lvlHeadline.TextXAlignment = Enum.TextXAlignment.Left
	lvlHeadline.TextTruncate = Enum.TextTruncate.AtEnd
	lvlHeadline.Text = ""

	local lvTrack
	lvTrack, levelFill = UITheme.Bar(lp, "XPTrack", COL_XP)
	lvTrack.Position = UDim2.fromOffset(108, 30)
	lvTrack.Size = UDim2.new(1, -122, 0, 16)
	levelFill.Size = UDim2.fromScale(0, 1)
	lvlXPText = text(lvTrack, "XPText", UITheme.BodyBoldFace, 11, COL_TEXT)
	lvlXPText.Size = UDim2.fromScale(1, 1)
	lvlXPText.ZIndex = 3
	lvlXPText.TextXAlignment = Enum.TextXAlignment.Center
	lvlXPText.Text = ""

	-- ===== THE DOCK ===== lobby-style round buttons at the bottom, seated to the RIGHT of the hotbar
	-- (the hotbar does NOT move — owner call, especially for phones): SHOP · CODES · SETTINGS · AUTOFIRE.
	-- AUTOFIRE is a live toggle (green = on, T still works); the others open their panels.
	-- CODES panel — the lobby's chrome, same accent as its shop pages; replies via the RedeemCode remote.
	local codesGui = Instance.new("ScreenGui")
	codesGui.Name = "GameCodes"
	codesGui.ResetOnSpawn = false
	codesGui.IgnoreGuiInset = true
	codesGui.DisplayOrder = UITheme.Layer.ShopModal
	codesGui.Parent = gui.Parent
	UITheme.Attach(codesGui, 404, 240)
	local codesPanel, codesBody, _, codesX = LobbyLook.ChromePanel(codesGui, 360, 178, LobbyLook.HeaderColors.shop, "CODES")
	codesX.Activated:Connect(function()
		codesPanel.Visible = false
	end)
	local codeBox = Instance.new("TextBox")
	codeBox.Name = "CodeBox"
	codeBox.Position = UDim2.fromOffset(18, 16)
	codeBox.Size = UDim2.new(1, -36, 0, 44)
	codeBox.BackgroundColor3 = COL_TRACK
	codeBox.BorderSizePixel = 0
	codeBox.FontFace = UITheme.BodyBoldFace
	codeBox.TextSize = 18
	codeBox.TextColor3 = COL_TEXT
	codeBox.PlaceholderText = "ENTER CODE"
	codeBox.PlaceholderColor3 = COL_TEXT_DIM
	codeBox.ClearTextOnFocus = false
	codeBox.Text = ""
	codeBox.Parent = codesBody
	UITheme.Corner(codeBox, 6)
	UITheme.Edge(codeBox, UITheme.BLACK, 2)
	local codesResult = text(codesBody, "Result", UITheme.BodyBoldFace, 13, COL_TEXT_DIM)
	codesResult.Position = UDim2.fromOffset(18, 66)
	codesResult.Size = UDim2.new(1, -36, 0, 18)
	codesResult.TextXAlignment = Enum.TextXAlignment.Left
	codesResult.Text = "Codes drop on the socials — one use each."
	local redeemBtn = UITheme.Button(codesBody, "REDEEM", "gold")
	redeemBtn.Position = UDim2.fromOffset(18, 96)
	redeemBtn.Size = UDim2.new(1, -36, 0, 48)
	redeemBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	redeemBtn.Activated:Connect(function()
		local code = codeBox.Text
		if #code > 0 then
			codesResult.Text = "CHECKING..."
			codesResult.TextColor3 = COL_TEXT_DIM
			Remotes.Get("RedeemCode"):FireServer(code)
		end
	end)
	Remotes.Get("RedeemCode").OnClientEvent:Connect(function(res)
		if typeof(res) ~= "table" then
			return
		end
		codesResult.Text = tostring(res.msg or "")
		codesResult.TextColor3 = res.ok and COL_ACCENT or COL_DANGER
		if res.ok then
			codeBox.Text = ""
		end
	end)

	-- The dock: the LOBBY'S BUTTONS, verbatim (LobbyLook.DockButton — same 66x84 holders, 83px
	-- spacing, dark-glass circles, same photo ids, Title-case labels on the rim), centered UNDERNEATH
	-- the guns (the hotbar lifts to seat it — HotbarController).
	local DOCK = {
		{ label = "Shop", icon = "71412141929869", onClick = function()
			card.Visible = not card.Visible
		end },
		{ label = "Codes", icon = "106591567271932", onClick = function()
			codesPanel.Visible = not codesPanel.Visible
		end },
		{ label = "Settings", icon = "94140673883223", onClick = function()
			if SettingsController.Toggle then
				SettingsController.Toggle()
			end
		end },
		{ label = "Autofire", icon = "", emoji = "🎯", onClick = function()
			AutoShootController.Toggle()
		end },
	}
	local autoRing
	for i, def in DOCK do
		local holder, circ = LobbyLook.DockButton(gui, def.label, def.icon, def.emoji)
		holder.Position = UDim2.new(0.5, -math.floor(((#DOCK - 1) * 83 + 66) / 2) + (i - 1) * 83, 1, -6)
		circ.Activated:Connect(def.onClick)
		if def.label == "Autofire" then -- the toggle state rides a toxic ring on the glass circle
			autoRing = Instance.new("UIStroke")
			autoRing.Color = UITheme.TOXIC
			autoRing.Thickness = 3
			autoRing.Transparency = 1
			autoRing.Parent = circ
		end
	end
	local function paintAuto(on)
		if autoRing then
			autoRing.Transparency = on and 0.05 or 1
		end
	end
	paintAuto(AutoShootController.IsOn())
	AutoShootController.Changed:Connect(paintAuto)
end

-- Account XP -> the bottom-right LVL card (shared curve with the lobby).
local function setXP(totalXP)
	local level, into, need = ProgressionConfig.LevelForXP(tonumber(totalXP) or 0)
	localPlayer:SetAttribute("AccountLevel", level) -- the GUNS screen reads this for its level locks
	if levelLabel then
		levelLabel.Text = "LVL " .. level
	end
	if levelFill then
		levelFill.Size = UDim2.fromScale(need > 0 and math.clamp(into / need, 0, 1) or 1, 1)
	end
	if lvlXPText then
		lvlXPText.Text = need > 0 and (Util.FormatNumber(into) .. " / " .. Util.FormatNumber(need) .. " XP") or "MAX LEVEL"
	end
	if lvlHeadline then
		-- Headline = the NEXT gun on the level ladder (the lobby card's "ALL GUNS UNLOCKED" line).
		local bestLvl, bestName
		for _, w in WeaponConfig do
			if typeof(w) == "table" and tonumber(w.unlock) and w.unlock > level then
				if not bestLvl or w.unlock < bestLvl then
					bestLvl, bestName = w.unlock, w.name or w.id
				end
			end
		end
		lvlHeadline.Text = bestLvl and (tostring(bestName):upper() .. " AT LV " .. bestLvl) or "ALL GUNS UNLOCKED"
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
-- (The persistent health BAR is gone — owner call. healthPct still tracks for anything that reads it;
-- the hurt vignette/heartbeat + your own party chip's ring are the visible health signals now.)
local function setHealth(health, maxHealth)
	health = math.max(0, health)
	maxHealth = math.max(1, maxHealth)
	healthPct = math.clamp(health / maxHealth, 0, 1)
end

-- ===== LIFECYCLE =====
-- ===== LOOT-COIN COUNTER TICK ===== (called by CoinDropController)
-- The real payout is instant + server-authoritative; only the DISPLAY waits for the flying coins.
-- CoinBurstStarted opens a short hold window (server totals stop snapping in); each CoinArrived
-- closes 1/remaining of the gap so the last coin always lands the counter exactly on the target.
function HUDController.CoinBurstStarted()
	coinHoldUntil = os.clock() + 2.5
	task.delay(2.6, function() -- failsafe: never leave the counter behind if coins get cut short
		if os.clock() >= coinHoldUntil and coinShown ~= coinTarget then
			coinShown = coinTarget
			if coinsLabel then
				coinsLabel.Text = Util.FormatNumber(coinTarget)
			end
		end
	end)
end

function HUDController.CoinArrived(frac: number)
	coinHoldUntil = math.max(coinHoldUntil, os.clock() + 1.2)
	if frac >= 1 then
		coinShown = coinTarget
	else
		coinShown += (coinTarget - coinShown) * frac
	end
	if not coinsLabel then
		return
	end
	coinsLabel.Text = Util.FormatNumber(math.floor(coinShown + 0.5))
	if coinPopScale then -- little pickup pop
		coinPopScale.Scale = 1.16
		TweenService:Create(coinPopScale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()
	end
end

-- ===== EXTRACTION CHIP ===== next cash-out wave + live payout multiplier (drives loop comprehension).
local function updateExtractChip()
	if not extractChip then
		return
	end
	local every = (GameConfig.Extraction and GameConfig.Extraction.Every) or 0
	if every <= 0 or currentRound < 1 then
		extractChip.Visible = false
		return
	end
	local nextWave = (math.floor(currentRound / every) + 1) * every
	-- Short forms: the chip lives in the wave strip's right slot now (148px).
	if extractMult > 1 then
		extractChip.Text = ("◇ ×%.1f · CASH OUT W%d"):format(extractMult, nextWave)
	else
		extractChip.Text = ("◇ CASH OUT AT W%d"):format(nextWave)
	end
	extractChip.Visible = true
end

function HUDController.Start()
	build()

	Remotes.Get("HealthChanged").OnClientEvent:Connect(setHealth)
	Remotes.Get("RoundChanged").OnClientEvent:Connect(function(round)
		breakEndsAt = 0
		currentRound = tonumber(round) or 0
		if currentRound <= 1 then
			extractMult = 1 -- a fresh run resets the payout multiplier (server does the same)
		end
		if leaveBtn then
			leaveBtn.Visible = true -- the horde is back: any extraction window has closed, restore LEAVE
		end
		updateExtractChip()
		if tonumber(round) == 1 then
			-- The round-start audio leads by 1s; the text lands on its beat.
			task.delay(1, function()
				roundLabel.Text = "WAVE " .. tostring(round)
			end)
		else
			roundLabel.Text = "WAVE " .. tostring(round)
		end
	end)

	-- Live payout multiplier: the stayers doubled down, so the pot rides higher now.
	Remotes.Get("ExtractMult").OnClientEvent:Connect(function(mult)
		extractMult = tonumber(mult) or 1
		updateExtractChip()
	end)

	-- LEAVE is a footgun during a cash-out window: leaving banks only the base and skips the WIN + bonus,
	-- while CASH OUT (on the extraction card) always pays at least as much. So hide LEAVE while the window
	-- is open — the card's CASH OUT / DOUBLE DOWN are the exits — and bring it back when the wave resumes.
	Remotes.Get("ExtractWindow").OnClientEvent:Connect(function(info)
		local open = typeof(info) == "table" and (tonumber(info.seconds) or 0) > 0
		if leaveBtn then
			leaveBtn.Visible = not open
		end
	end)

	-- Pre-run countdown (waiting for the party to load in): shown in the wave slot until the run starts.
	Remotes.Get("StartCountdown").OnClientEvent:Connect(function(secs)
		secs = tonumber(secs) or 0
		if secs > 0 then
			roundLabel.Text = ("STARTING IN %d"):format(secs)
			currentRound = 0 -- pre-run: hide the extraction chip until wave 1 lands
			updateExtractChip()
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
			-- Between waves the bar STAYS (the run isn't over) and reads LOADING while the next wave preps.
			enemiesTrack.Visible = true
			enemiesLabel.Text = "LOADING..."
			enemiesFill.Size = UDim2.fromScale(1, 1)
		end
	end)

	-- Enemies left to kill this wave — the count bar under the wave number.
	Remotes.Get("WaveProgress").OnClientEvent:Connect(function(remaining, total)
		remaining = tonumber(remaining) or 0
		total = tonumber(total) or 0
		if total <= 0 or remaining <= 0 then
			enemiesLabel.Text = "LOADING..." -- wave cleared: hold the bar, full fill, until the next wave
			enemiesFill.Size = UDim2.fromScale(1, 1)
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

	Remotes.Get("DataReady").OnClientEvent:Connect(function(data)
		if typeof(data) == "table" and data.lobbyMoney then
			coinTarget = data.lobbyMoney
			coinShown = coinTarget
			coinsLabel.Text = Util.FormatNumber(coinTarget)
		end
		if typeof(data) == "table" and data.xp ~= nil then
			setXP(data.xp)
		end
	end)
	Remotes.Get("ProgressChanged").OnClientEvent:Connect(function(xp)
		setXP(xp)
	end)
	-- CHANGED: the server total is the TARGET; while loot coins are in flight (CoinDropController) the
	-- displayed number holds back and ticks up per arriving coin instead of snapping.
	Remotes.Get("LobbyMoneyChanged").OnClientEvent:Connect(function(total)
		coinTarget = total
		if os.clock() >= coinHoldUntil then
			coinShown = total
			coinsLabel.Text = Util.FormatNumber(total)
		end
	end)

	-- Seed initial values.
	setHealth(GameConfig.PlayerMaxHealth, GameConfig.PlayerMaxHealth)

	print("[HUDController] started (styled HUD)")
end

return HUDController
