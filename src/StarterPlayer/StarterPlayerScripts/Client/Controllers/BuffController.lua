--!nonstrict
-- BuffController.lua — the in-run level-up UI: a run XP bar, and the buff DRAFT (3 same-rarity cards that
-- "roll" through options before locking in). Clicking a card sends the pick to the server. Also mirrors the
-- server's current buff totals so the client can predict fire rate (Attack Speed) and auto-aim reach (Range).
--
-- The draft is a centered panel, NOT a full-screen block — the game never pauses, so zombies keep coming and
-- auto-shoot keeps firing while you choose.

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
local ROLL_TIME  = 1.1   -- seconds the cards "roll" through options before revealing
local CARD_W     = 190
local CARD_H     = 150

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local buffs = { damage = 0, attackspeed = 0, walkspeed = 0, range = 0, critchance = 0, critdamage = 0, luck = 0 }

-- Other controllers read these (InputController = fire rate, AimController = reach).
function BuffController.GetStat(key: string): number
	return buffs[key] or 0
end

local gui, banner, fill, levelLabel
local cards = {}
local rolling = false
local queue = {}

local function pct(frac: number): string
	return "+" .. tostring(math.floor(frac * 100 + 0.5)) .. "%"
end

-- ===== BUILD =====
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "BuffUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 8
	gui.Parent = playerGui

	-- ----- XP bar (bottom center) -----
	local barHolder = Instance.new("Frame")
	barHolder.Name = "XPBar"
	barHolder.AnchorPoint = Vector2.new(0.5, 1)
	barHolder.Position = UDim2.new(0.5, 0, 1, -14)
	barHolder.Size = UDim2.fromOffset(360, 16)
	barHolder.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	barHolder.BackgroundTransparency = 0.25
	barHolder.BorderSizePixel = 0
	barHolder.Parent = gui
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(1, 0)
	bc.Parent = barHolder

	fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(120, 220, 255)
	fill.BorderSizePixel = 0
	fill.Parent = barHolder
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(1, 0)
	fc.Parent = fill

	levelLabel = Instance.new("TextLabel")
	levelLabel.Name = "Level"
	levelLabel.AnchorPoint = Vector2.new(1, 0.5)
	levelLabel.Position = UDim2.new(0, -8, 0.5, 0)
	levelLabel.Size = UDim2.fromOffset(60, 20)
	levelLabel.BackgroundTransparency = 1
	levelLabel.Font = Enum.Font.GothamBold
	levelLabel.TextSize = 16
	levelLabel.TextColor3 = Color3.fromRGB(235, 235, 245)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Right
	levelLabel.Text = "Lv 1"
	levelLabel.Parent = barHolder

	-- ----- Draft panel (upper center) -----
	local panel = Instance.new("Frame")
	panel.Name = "Draft"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 70)
	panel.Size = UDim2.fromOffset(CARD_W * 3 + 40, CARD_H + 70)
	panel.BackgroundTransparency = 1
	panel.Visible = false
	panel.Parent = gui
	gui:SetAttribute("_panel", true)

	banner = Instance.new("TextLabel")
	banner.Name = "Rarity"
	banner.Size = UDim2.new(1, 0, 0, 40)
	banner.BackgroundTransparency = 1
	banner.Font = Enum.Font.GothamBlack
	banner.TextSize = 30
	banner.TextColor3 = Color3.fromRGB(200, 200, 200)
	banner.Text = "LEVEL UP!"
	banner.Parent = panel

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.AnchorPoint = Vector2.new(0.5, 0)
	row.Position = UDim2.new(0.5, 0, 0, 48)
	row.Size = UDim2.fromOffset(CARD_W * 3 + 40, CARD_H)
	row.BackgroundTransparency = 1
	row.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 20)
	layout.Parent = row

	for i = 1, BuffConfig.OptionsPerDraft do
		local btn = Instance.new("TextButton")
		btn.Name = "Card" .. i
		btn.Size = UDim2.fromOffset(CARD_W, CARD_H)
		btn.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
		btn.AutoButtonColor = true
		btn.Text = ""
		btn.LayoutOrder = i
		btn.Parent = row
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 12)
		cc.Parent = btn
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Color3.fromRGB(120, 120, 120)
		stroke.Parent = btn

		local title = Instance.new("TextLabel")
		title.AnchorPoint = Vector2.new(0.5, 0)
		title.Position = UDim2.new(0.5, 0, 0, 24)
		title.Size = UDim2.new(1, -12, 0, 40)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextSize = 20
		title.TextColor3 = Color3.fromRGB(240, 240, 245)
		title.TextWrapped = true
		title.Text = "?"
		title.Parent = btn

		local amount = Instance.new("TextLabel")
		amount.AnchorPoint = Vector2.new(0.5, 1)
		amount.Position = UDim2.new(0.5, 0, 1, -20)
		amount.Size = UDim2.new(1, -12, 0, 40)
		amount.BackgroundTransparency = 1
		amount.Font = Enum.Font.GothamBlack
		amount.TextSize = 28
		amount.TextColor3 = Color3.fromRGB(255, 255, 255)
		amount.Text = ""
		amount.Parent = btn

		local card = { btn = btn, stroke = stroke, title = title, amount = amount }
		btn.Activated:Connect(function()
			if rolling or not panel.Visible then
				return
			end
			Remotes.Get("BuffPick"):FireServer(i)
			BuffController._close()
		end)
		cards[i] = card
	end

	BuffController._panel = panel
end

-- ===== DRAFT FLOW =====
function BuffController._close()
	if BuffController._panel then
		BuffController._panel.Visible = false
	end
	rolling = false
	local nextDraft = table.remove(queue, 1)
	if nextDraft then
		BuffController._show(nextDraft)
	end
end

function BuffController._show(draft)
	local panel = BuffController._panel
	local finalTier = math.clamp(draft.rarityIndex or 1, 1, #BuffConfig.Rarities)
	rolling = true
	panel.Visible = true

	task.spawn(function()
		local t, interval = 0, 0.04
		while t < ROLL_TIME and panel.Parent do
			local tierNow = math.clamp(1 + math.floor((t / ROLL_TIME) * finalTier), 1, #BuffConfig.Rarities)
			local r = BuffConfig.Rarities[tierNow]
			banner.Text = string.upper(r.name)
			banner.TextColor3 = r.color
			for _, card in cards do
				local rb = BuffConfig.Buffs[math.random(#BuffConfig.Buffs)]
				card.title.Text = rb.name
				card.amount.Text = pct(BuffConfig.Magnitude(rb.base, tierNow))
				card.stroke.Color = r.color
			end
			task.wait(interval)
			t += interval
			interval = math.min(0.13, interval + 0.006) -- ease-out: slows as it settles
		end

		-- Lock in the real options.
		local col = draft.color or BuffConfig.Rarities[finalTier].color
		banner.Text = string.upper(draft.rarityName or BuffConfig.Rarities[finalTier].name)
		banner.TextColor3 = col
		for i, card in cards do
			local opt = draft.options and draft.options[i]
			if opt then
				card.btn.Visible = true
				card.title.Text = opt.name
				card.amount.Text = pct(opt.amount)
				card.amount.TextColor3 = col
				card.stroke.Color = col
			else
				card.btn.Visible = false
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
		if levelLabel then
			levelLabel.Text = "Lv " .. tostring(level or 1)
		end
		if fill then
			local frac = (needed and needed > 0) and math.clamp(xp / needed, 0, 1) or 0
			TweenService:Create(fill, TweenInfo.new(0.25), { Size = UDim2.new(frac, 0, 1, 0) }):Play()
		end
	end)

	Remotes.Get("BuffDraft").OnClientEvent:Connect(function(draft)
		if typeof(draft) ~= "table" then
			return
		end
		if rolling or (BuffController._panel and BuffController._panel.Visible) then
			table.insert(queue, draft) -- one at a time; show the next after this one is chosen
		else
			BuffController._show(draft)
		end
	end)

	print("[BuffController] started")
end

return BuffController
