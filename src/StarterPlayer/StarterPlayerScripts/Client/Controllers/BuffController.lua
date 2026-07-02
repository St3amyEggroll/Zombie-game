--!nonstrict
-- BuffController.lua — the in-run level-up UI: a run XP bar with an AUTOPICK button, and the buff DRAFT
-- (3 same-rarity cards that "roll" through options before locking in). Styled after a card-draft layout:
-- rarity pill on top, a name header, an icon box (emoji placeholder — swap for real icons later), the green
-- effect, and your current total for that stat at the bottom. Clicking a card sends the pick to the server.
--
-- Also mirrors the server's buff totals so the client predicts fire rate (Attack Speed) and reach (Range).
-- Not a full-screen block — the game never pauses; zombies keep coming and auto-shoot keeps firing.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local BuffConfig = require(Config.BuffConfig)
local Remotes = require(Modules.Remotes)

local BuffController = {}

-- ===== TUNABLES =====
local ROLL_TIME = 1.1
local CARD_W    = 230
local CARD_H    = 380
local CARD_GAP  = 26
local NAVY      = Color3.fromRGB(26, 32, 58)
local ICON_BG   = Color3.fromRGB(238, 242, 250)
local GREEN     = Color3.fromRGB(90, 220, 110)

-- Placeholder icons per buff (swap for real images later).
local ICONS = {
	damage = "💥", attackspeed = "⚡", walkspeed = "👟", range = "🎯",
	critchance = "🎲", critdamage = "💢", luck = "🍀",
}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local buffs = { damage = 0, attackspeed = 0, walkspeed = 0, range = 0, critchance = 0, critdamage = 0, luck = 0 }

function BuffController.GetStat(key: string): number
	return buffs[key] or 0
end

local gui, panel, fill, levelLabel, xpLabel, autopick

-- Is the 3-card buff draft currently on screen? (CrosshairController frees the mouse while any UI is up.)
function BuffController.IsDraftOpen(): boolean
	return panel ~= nil and panel.Visible
end
local cards = {}
local rolling = false
local queue = {}

local function pct(frac: number): string
	return tostring(math.floor((frac or 0) * 100 + 0.5)) .. "%"
end

-- ===== BUILD =====
local function makeCorner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end

local function makeCard(order: number)
	local card = Instance.new("TextButton")
	card.Name = "Card" .. order
	card.Size = UDim2.fromOffset(CARD_W, CARD_H)
	card.BackgroundColor3 = NAVY
	card.AutoButtonColor = false
	card.Text = ""
	card.LayoutOrder = order
	makeCorner(card, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(200, 220, 255)
	stroke.Parent = card

	-- rarity pill (straddles the top edge)
	local pill = Instance.new("TextLabel")
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.new(0.5, 0, 0, 2)
	pill.Size = UDim2.fromOffset(120, 30)
	pill.BackgroundColor3 = Color3.fromRGB(80, 145, 255)
	pill.Font = Enum.Font.GothamBold
	pill.TextSize = 16
	pill.TextColor3 = Color3.fromRGB(255, 255, 255)
	pill.Text = "Rare"
	pill.ZIndex = 3
	pill.Parent = card
	makeCorner(pill, 8)

	-- name header
	local header = Instance.new("TextLabel")
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Position = UDim2.new(0.5, 0, 0, 30)
	header.Size = UDim2.fromOffset(CARD_W - 26, 46)
	header.BackgroundColor3 = Color3.fromRGB(80, 145, 255)
	header.Font = Enum.Font.GothamBlack
	header.TextSize = 24
	header.TextColor3 = Color3.fromRGB(255, 255, 255)
	header.Text = "Buff"
	header.Parent = card
	makeCorner(header, 8)

	-- icon box (white rounded square)
	local iconBox = Instance.new("Frame")
	iconBox.AnchorPoint = Vector2.new(0.5, 0)
	iconBox.Position = UDim2.new(0.5, 0, 0, 90)
	iconBox.Size = UDim2.fromOffset(150, 150)
	iconBox.BackgroundColor3 = ICON_BG
	iconBox.Parent = card
	makeCorner(iconBox, 14)
	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.Font = Enum.Font.GothamBold
	icon.TextSize = 72
	icon.Text = "?"
	icon.Parent = iconBox

	-- green effect line
	local effect = Instance.new("TextLabel")
	effect.AnchorPoint = Vector2.new(0.5, 0)
	effect.Position = UDim2.new(0.5, 0, 0, 258)
	effect.Size = UDim2.fromOffset(CARD_W - 20, 40)
	effect.BackgroundTransparency = 1
	effect.Font = Enum.Font.GothamBlack
	effect.TextSize = 22
	effect.TextColor3 = GREEN
	effect.Text = "+0%"
	effect.TextWrapped = true
	effect.Parent = card

	-- current total (bottom)
	local total = Instance.new("TextLabel")
	total.AnchorPoint = Vector2.new(0.5, 1)
	total.Position = UDim2.new(0.5, 0, 1, -16)
	total.Size = UDim2.fromOffset(CARD_W - 20, 24)
	total.BackgroundTransparency = 1
	total.Font = Enum.Font.GothamBold
	total.TextSize = 16
	total.TextColor3 = Color3.fromRGB(180, 190, 210)
	total.Text = ""
	total.Parent = card

	local ref = { card = card, stroke = stroke, pill = pill, header = header, icon = icon, effect = effect, total = total }
	card.Activated:Connect(function()
		if rolling or not panel.Visible then
			return
		end
		Remotes.Get("BuffPick"):FireServer(order)
		BuffController._close()
	end)
	return ref
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "BuffUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	-- ----- Level bar (TOP center, always visible) -----
	local barHolder = Instance.new("Frame")
	barHolder.Name = "XPBar"
	barHolder.AnchorPoint = Vector2.new(0.5, 0)
	barHolder.Position = UDim2.new(0.5, 0, 0, 12)
	barHolder.Size = UDim2.fromOffset(560, 26)
	barHolder.BackgroundColor3 = Color3.fromRGB(18, 22, 34)
	barHolder.BackgroundTransparency = 0.1
	barHolder.BorderSizePixel = 0
	barHolder.Parent = gui
	makeCorner(barHolder, 13)

	fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(120, 210, 90)
	fill.BorderSizePixel = 0
	fill.Parent = barHolder
	makeCorner(fill, 13)

	xpLabel = Instance.new("TextLabel")
	xpLabel.AnchorPoint = Vector2.new(0, 0.5)
	xpLabel.Position = UDim2.new(0, 14, 0.5, 0)
	xpLabel.Size = UDim2.fromOffset(120, 22)
	xpLabel.BackgroundTransparency = 1
	xpLabel.Font = Enum.Font.GothamBold
	xpLabel.TextSize = 16
	xpLabel.TextXAlignment = Enum.TextXAlignment.Left
	xpLabel.TextColor3 = Color3.fromRGB(235, 240, 250)
	xpLabel.Text = "0"
	xpLabel.ZIndex = 2
	xpLabel.Parent = barHolder

	levelLabel = Instance.new("TextLabel")
	levelLabel.AnchorPoint = Vector2.new(1, 0.5)
	levelLabel.Position = UDim2.new(1, -14, 0.5, 0)
	levelLabel.Size = UDim2.fromOffset(120, 22)
	levelLabel.BackgroundTransparency = 1
	levelLabel.Font = Enum.Font.GothamBlack
	levelLabel.TextSize = 16
	levelLabel.TextXAlignment = Enum.TextXAlignment.Right
	levelLabel.TextColor3 = Color3.fromRGB(235, 240, 250)
	levelLabel.Text = "LV. 1"
	levelLabel.ZIndex = 2
	levelLabel.Parent = barHolder

	-- AUTOPICK button (over the bar; only during a draft)
	autopick = Instance.new("TextButton")
	autopick.Name = "AutoPick"
	autopick.AnchorPoint = Vector2.new(0.5, 1)
	autopick.Position = UDim2.new(0.5, 0, 1, -8)
	autopick.Size = UDim2.fromOffset(220, 58)
	autopick.BackgroundColor3 = Color3.fromRGB(230, 65, 70)
	autopick.Font = Enum.Font.GothamBlack
	autopick.TextSize = 26
	autopick.TextColor3 = Color3.fromRGB(255, 255, 255)
	autopick.Text = "AUTOPICK"
	autopick.Visible = false
	autopick.ZIndex = 5
	autopick.Parent = gui
	makeCorner(autopick, 12)
	local aps = Instance.new("UIStroke")
	aps.Thickness = 3
	aps.Color = Color3.fromRGB(255, 255, 255)
	aps.Transparency = 0.3
	aps.Parent = autopick
	autopick.Activated:Connect(function()
		if rolling or not panel.Visible then
			return
		end
		local opts = cards
		Remotes.Get("BuffPick"):FireServer(math.random(#opts)) -- auto = let the game choose one
		BuffController._close()
	end)

	-- ----- Draft cards -----
	panel = Instance.new("Frame")
	panel.Name = "Draft"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 84)
	panel.Size = UDim2.fromOffset(CARD_W * 3 + CARD_GAP * 2, CARD_H)
	panel.BackgroundTransparency = 1
	panel.Visible = false
	panel.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Padding = UDim.new(0, CARD_GAP)
	layout.Parent = panel

	for i = 1, BuffConfig.OptionsPerDraft do
		local ref = makeCard(i)
		ref.card.Parent = panel
		cards[i] = ref
	end
end

-- ===== CARD CONTENT =====
local function paintCard(ref, rarity, buffDef, amount)
	ref.pill.Text = rarity.name
	ref.pill.BackgroundColor3 = rarity.color
	ref.header.Text = buffDef.name
	ref.header.BackgroundColor3 = rarity.color
	ref.stroke.Color = rarity.color
	ref.icon.Text = ICONS[buffDef.stat] or "?"
	ref.effect.Text = "+" .. pct(amount)
	ref.total.Text = (buffDef.name:gsub(" ", "")) .. ": " .. pct(buffs[buffDef.stat])
	-- readable header text on light rarities
	local lum = (rarity.color.R * 0.3 + rarity.color.G * 0.59 + rarity.color.B * 0.11)
	local dark = lum > 0.6
	ref.header.TextColor3 = dark and Color3.fromRGB(25, 30, 45) or Color3.fromRGB(255, 255, 255)
	ref.pill.TextColor3 = dark and Color3.fromRGB(25, 30, 45) or Color3.fromRGB(255, 255, 255)
end

-- ===== DRAFT FLOW =====
function BuffController._close()
	if panel then panel.Visible = false end
	if autopick then autopick.Visible = false end
	rolling = false
	local nextDraft = table.remove(queue, 1)
	if nextDraft then
		BuffController._show(nextDraft)
	end
end

function BuffController._show(draft)
	local finalTier = math.clamp(draft.rarityIndex or 1, 1, #BuffConfig.Rarities)
	rolling = true
	panel.Visible = true
	autopick.Visible = true

	task.spawn(function()
		local t, interval = 0, 0.04
		while t < ROLL_TIME and panel.Parent do
			local tierNow = math.clamp(1 + math.floor((t / ROLL_TIME) * finalTier), 1, #BuffConfig.Rarities)
			local r = BuffConfig.Rarities[tierNow]
			for _, ref in cards do
				local b = BuffConfig.Buffs[math.random(#BuffConfig.Buffs)]
				paintCard(ref, r, b, BuffConfig.Magnitude(b.base, tierNow))
			end
			task.wait(interval)
			t += interval
			interval = math.min(0.13, interval + 0.006) -- ease-out: settles at the end
		end

		-- Lock in the real options.
		local rarity = BuffConfig.Rarities[finalTier]
		if draft.rarityName then
			rarity = { name = draft.rarityName, color = draft.color or rarity.color }
		end
		for i, ref in cards do
			local opt = draft.options and draft.options[i]
			if opt then
				ref.card.Visible = true
				paintCard(ref, rarity, { name = opt.name, stat = opt.stat }, opt.amount)
			else
				ref.card.Visible = false
			end
		end
		rolling = false
	end)
end

-- ===== LIFECYCLE =====
function BuffController.Start()
	build()

	Remotes.Get("BuffsChanged").OnClientEvent:Connect(function(b)
		if typeof(b) == "table" then
			for k, v in b do
				buffs[k] = v
			end
		end
	end)

	Remotes.Get("RunXPChanged").OnClientEvent:Connect(function(xp, needed, level)
		if levelLabel then levelLabel.Text = "LV. " .. tostring(level or 1) end
		if xpLabel then xpLabel.Text = tostring(math.floor(xp or 0)) end
		if fill then
			local frac = (needed and needed > 0) and math.clamp(xp / needed, 0, 1) or 0
			TweenService:Create(fill, TweenInfo.new(0.25), { Size = UDim2.new(frac, 0, 1, 0) }):Play()
		end
	end)

	Remotes.Get("BuffDraft").OnClientEvent:Connect(function(draft)
		if typeof(draft) ~= "table" then
			return
		end
		if rolling or (panel and panel.Visible) then
			table.insert(queue, draft)
		else
			BuffController._show(draft)
		end
	end)

	print("[BuffController] started")
end

return BuffController
