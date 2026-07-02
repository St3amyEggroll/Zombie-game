-- LobbyClient (LOBBY PLACE ONLY) — the hub HUD + the PARTY PAD menu + the inventory.
-- Step on an empty pad -> you HOST it (Map / Difficulty / Party Size + PLAY). After PLAY the panel becomes
-- party info + a LEAVE button; others who step on join (if they've unlocked the settings) or see why not.
-- The party launches when full or when the countdown ends. Self-contained (no game controllers run here).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("LobbyRemotes")
local StatsRemote = remotes:WaitForChild("Stats")
local ZoneEnter = remotes:WaitForChild("ZoneEnter")
local ZoneLeave = remotes:WaitForChild("ZoneLeave")
local FinalizeParty = remotes:WaitForChild("FinalizeParty")
local LeaveParty = remotes:WaitForChild("LeaveParty")
local PartyStatus = remotes:WaitForChild("PartyStatus")

local ACCENT = Color3.fromRGB(87, 196, 116)
local DIM = Color3.fromRGB(64, 68, 80)
local CARD = Color3.fromRGB(31, 34, 42)

local sel = { map = "forest", difficulty = "easy", size = 1 }
local unlocks = nil       -- unlock payload while configuring a pad
local zoneMode = nil      -- "config" | "party" | "blocked" (what the pad UI is showing)

local function fmt(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
local function cap(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end
local function corner(o, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = o
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "LobbyHUD"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 10
gui.Parent = playerGui

-- stats card
local stats = Instance.new("Frame")
stats.Position = UDim2.fromOffset(16, 16); stats.Size = UDim2.fromOffset(220, 96)
stats.BackgroundColor3 = Color3.fromRGB(22, 24, 30); stats.BackgroundTransparency = 0.05; stats.BorderSizePixel = 0
stats.Parent = gui; corner(stats, 12)
local sp = Instance.new("UIPadding"); sp.PaddingLeft = UDim.new(0, 12); sp.PaddingTop = UDim.new(0, 8); sp.Parent = stats
local sl = Instance.new("UIListLayout"); sl.Padding = UDim.new(0, 4); sl.Parent = stats
local function statLabel(color)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -12, 0, 26); l.BackgroundTransparency = 1; l.Font = Enum.Font.GothamBold
	l.TextSize = 18; l.TextXAlignment = Enum.TextXAlignment.Left; l.TextColor3 = color; l.Text = ""; l.Parent = stats
	return l
end
local moneyLabel = statLabel(Color3.fromRGB(235, 190, 85))
local bestLabel = statLabel(Color3.fromRGB(210, 210, 220))

-- selection panel
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5); panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(560, 380); panel.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
panel.BackgroundTransparency = 0.05; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 16)
local pstroke = Instance.new("UIStroke"); pstroke.Color = ACCENT; pstroke.Thickness = 2; pstroke.Transparency = 0.5; pstroke.Parent = panel

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 14); title.Size = UDim2.new(1, 0, 0, 34); title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack; title.TextSize = 22; title.TextColor3 = Color3.fromRGB(240, 240, 245)
title.Text = "CHOOSE YOUR RUN"; title.Parent = panel

local function sectionLabel(text, y)
	local l = Instance.new("TextLabel")
	l.Position = UDim2.new(0, 24, 0, y); l.Size = UDim2.new(1, -48, 0, 20); l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold; l.TextSize = 15; l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Color3.fromRGB(170, 180, 195); l.Text = text; l.Parent = panel
	return l
end
local function row(y, h)
	local f = Instance.new("Frame")
	f.Position = UDim2.new(0, 24, 0, y); f.Size = UDim2.new(1, -48, 0, h); f.BackgroundTransparency = 1; f.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal; list.Padding = UDim.new(0, 10); list.Parent = f
	return f
end
local function button(parent, w, h, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, h); b.BackgroundColor3 = CARD; b.AutoButtonColor = true; b.Text = text
	b.Font = Enum.Font.GothamBold; b.TextSize = 16; b.TextColor3 = Color3.fromRGB(235, 235, 245); b.Parent = parent
	corner(b, 8)
	return b
end

local mapLbl = sectionLabel("MAP", 56)
local mapRow = row(78, 40)
local diffLbl = sectionLabel("DIFFICULTY", 130)
local diffRow = row(152, 44)
local sizeLbl = sectionLabel("PARTY SIZE", 208)
local sizeRow = row(230, 40)

-- Party view (shown after the host presses PLAY / when you join someone's party).
local partyInfo = Instance.new("TextLabel")
partyInfo.Position = UDim2.new(0, 0, 0, 96); partyInfo.Size = UDim2.new(1, 0, 0, 40); partyInfo.BackgroundTransparency = 1
partyInfo.Font = Enum.Font.GothamBlack; partyInfo.TextSize = 24; partyInfo.TextColor3 = Color3.fromRGB(238, 240, 245)
partyInfo.Text = ""; partyInfo.Visible = false; partyInfo.Parent = panel

local partySub = Instance.new("TextLabel")
partySub.Position = UDim2.new(0, 0, 0, 140); partySub.Size = UDim2.new(1, 0, 0, 26); partySub.BackgroundTransparency = 1
partySub.Font = Enum.Font.GothamBold; partySub.TextSize = 16; partySub.TextColor3 = Color3.fromRGB(150, 156, 168)
partySub.Text = ""; partySub.Visible = false; partySub.Parent = panel

local blockedMsg = Instance.new("TextLabel")
blockedMsg.Position = UDim2.new(0, 24, 0, 110); blockedMsg.Size = UDim2.new(1, -48, 0, 80); blockedMsg.BackgroundTransparency = 1
blockedMsg.Font = Enum.Font.GothamBold; blockedMsg.TextSize = 17; blockedMsg.TextWrapped = true
blockedMsg.TextColor3 = Color3.fromRGB(238, 240, 245); blockedMsg.Text = ""; blockedMsg.Visible = false; blockedMsg.Parent = panel

local mapBtns, diffBtns, sizeBtns = {}, {}, {}

local play = Instance.new("TextButton")
play.AnchorPoint = Vector2.new(0.5, 1); play.Position = UDim2.new(0.5, 0, 1, -46); play.Size = UDim2.fromOffset(240, 52)
play.BackgroundColor3 = ACCENT; play.Font = Enum.Font.GothamBlack; play.TextSize = 20
play.TextColor3 = Color3.fromRGB(15, 25, 15); play.Text = "PLAY"; play.Parent = panel
corner(play, 10)

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 1); status.Position = UDim2.new(0.5, 0, 1, -12); status.Size = UDim2.new(1, -40, 0, 24)
status.BackgroundTransparency = 1; status.Font = Enum.Font.GothamBold; status.TextSize = 15
status.TextColor3 = Color3.fromRGB(150, 156, 168); status.Text = ""; status.Parent = panel

-- ===== RENDER =====
local function refresh()
	if not unlocks then return end
	-- map buttons
	for _, b in mapBtns do b:Destroy() end
	mapBtns = {}
	for _, w in unlocks.worldOrder do
		local info = unlocks.worlds[w]
		local b = button(mapRow, 150, 40, cap(w))
		b.LayoutOrder = #mapBtns + 1
		if not info.unlocked then
			b.Text = cap(w) .. " 🔒"; b.AutoButtonColor = false; b.TextColor3 = Color3.fromRGB(150, 150, 160)
		end
		b.BackgroundColor3 = (sel.map == w) and ACCENT or CARD
		b.Activated:Connect(function()
			if info.unlocked then sel.map = w; refresh() end
		end)
		table.insert(mapBtns, b)
	end
	-- difficulty buttons
	for _, b in diffBtns do b:Destroy() end
	diffBtns = {}
	local worldInfo = unlocks.worlds[sel.map]
	for _, d in unlocks.order do
		local unlocked = worldInfo and worldInfo.diffs[d]
		local b = button(diffRow, 120, 44, unlocked and cap(d) or (cap(d) .. " 🔒"))
		b.LayoutOrder = #diffBtns + 1
		if not unlocked then
			b.AutoButtonColor = false; b.BackgroundColor3 = DIM; b.TextColor3 = Color3.fromRGB(150, 150, 160)
		else
			b.BackgroundColor3 = (sel.difficulty == d) and ACCENT or CARD
			b.TextColor3 = (sel.difficulty == d) and Color3.fromRGB(15, 25, 15) or Color3.fromRGB(235, 235, 245)
		end
		b.Activated:Connect(function()
			if unlocked then sel.difficulty = d; refresh() end
		end)
		table.insert(diffBtns, b)
	end
	-- size buttons
	for _, b in sizeBtns do b:Destroy() end
	sizeBtns = {}
	for n = 1, 4 do
		local b = button(sizeRow, 60, 40, tostring(n))
		b.LayoutOrder = n
		b.BackgroundColor3 = (sel.size == n) and ACCENT or CARD
		b.TextColor3 = (sel.size == n) and Color3.fromRGB(15, 25, 15) or Color3.fromRGB(235, 235, 245)
		b.Activated:Connect(function()
			sel.size = n; refresh()
		end)
		table.insert(sizeBtns, b)
	end
end

-- default difficulty = first unlocked for the selected map
local function pickDefaultDifficulty()
	local info = unlocks and unlocks.worlds[sel.map]
	if info then
		for _, d in unlocks.order do
			if info.diffs[d] then sel.difficulty = d; return end
		end
	end
end

-- Show/hide the three pad-UI modes inside the one panel.
local function setPanelMode(mode)
	zoneMode = mode
	local config = (mode == "config")
	mapLbl.Visible = config; mapRow.Visible = config
	diffLbl.Visible = config; diffRow.Visible = config
	sizeLbl.Visible = config; sizeRow.Visible = config
	partyInfo.Visible = (mode == "party")
	partySub.Visible = (mode == "party")
	blockedMsg.Visible = (mode == "blocked")
	play.Visible = (mode ~= "blocked")
	if mode == "config" then
		title.Text = "SET UP YOUR RUN"
		play.Text = "PLAY"
		play.BackgroundColor3 = ACCENT
		play.TextColor3 = Color3.fromRGB(15, 25, 15)
	elseif mode == "party" then
		title.Text = "PARTY"
		play.Text = "LEAVE"
		play.BackgroundColor3 = Color3.fromRGB(224, 82, 82)
		play.TextColor3 = Color3.fromRGB(255, 255, 255)
	else
		title.Text = "PARTY PAD"
	end
end

-- ===== EVENTS =====
StatsRemote.OnClientEvent:Connect(function(s)
	if typeof(s) ~= "table" then return end
	moneyLabel.Text = fmt(s.lobbyMoney or 0) .. " Coins"
	bestLabel.Text = "Best: Wave " .. tostring(s.bestWave or 0)
end)

ZoneEnter.OnClientEvent:Connect(function(p)
	if typeof(p) ~= "table" then return end
	status.Text = ""
	if p.mode == "config" then
		unlocks = p.unlocks
		if unlocks then
			if not unlocks.worlds[sel.map] then sel.map = unlocks.worldOrder[1] end
			pickDefaultDifficulty()
		end
		sel.size = 1
		setPanelMode("config")
		refresh()
	elseif p.mode == "party" then
		setPanelMode("party")
		partyInfo.Text = ("%s  ·  %s"):format(cap(p.map or "?"), cap(p.difficulty or "?"))
		partySub.Text = "Waiting for players..."
	else
		setPanelMode("blocked")
		blockedMsg.Text = p.reason or "You can't join this pad right now."
	end
	panel.Visible = true
end)

ZoneLeave.OnClientEvent:Connect(function()
	panel.Visible = false
	status.Text = ""
end)

PartyStatus.OnClientEvent:Connect(function(info)
	if typeof(info) ~= "table" then return end
	if zoneMode == "party" then
		partySub.Text = ("Party %d/%d  ·  starting in %ds"):format(info.count or 1, info.size or 1, info.seconds or 0)
	end
end)

play.Activated:Connect(function()
	if zoneMode == "config" then
		FinalizeParty:FireServer({ map = sel.map, difficulty = sel.difficulty, size = sel.size })
	elseif zoneMode == "party" then
		LeaveParty:FireServer()
	end
end)

-- =====================================================================================================
-- ===== INVENTORY (Weapons / Cases / Potions) =========================================================
-- =====================================================================================================
local TweenService = game:GetService("TweenService")
local InvRequest = remotes:WaitForChild("InvRequest")
local InvSync    = remotes:WaitForChild("InvSync")
local EquipSlot = remotes:WaitForChild("EquipSlot")
local OpenCase   = remotes:WaitForChild("OpenCase")
local CaseResult = remotes:WaitForChild("CaseResult")

local invData = nil          -- latest snapshot: { catalog, owned, selected, cases, potions, coins }
local activeTab = "weapons"
local rolling = false

local BLACK = Color3.fromRGB(12, 13, 18)

local function rarityColor(rarityId)
	local r = invData and invData.catalog.rarities[rarityId]
	if r then
		return Color3.fromRGB(r.color[1], r.color[2], r.color[3])
	end
	return Color3.fromRGB(160, 160, 170)
end
local function weaponInfo(id)
	return invData and invData.catalog.weapons[id]
end
local function ownsSet()
	local s = {}
	if invData then
		for _, id in invData.owned do s[id] = true end
	end
	return s
end

-- ===== INVENTORY GUI (its own layer, above the selection menu) =====
local invGui = Instance.new("ScreenGui")
invGui.Name = "LobbyInventory"; invGui.ResetOnSpawn = false; invGui.IgnoreGuiInset = true; invGui.DisplayOrder = 11
invGui.Parent = playerGui

-- ===== HOVER TOOLTIP (shared: case odds + weapon stats) =====
local tip = Instance.new("Frame")
tip.Name = "Tooltip"; tip.BackgroundColor3 = Color3.fromRGB(10, 12, 18); tip.BackgroundTransparency = 0.05
tip.BorderSizePixel = 0; tip.Visible = false; tip.ZIndex = 60; tip.AutomaticSize = Enum.AutomaticSize.XY
tip.Size = UDim2.fromOffset(0, 0); tip.Parent = invGui
corner(tip, 8)
local tipStroke = Instance.new("UIStroke"); tipStroke.Color = ACCENT; tipStroke.Thickness = 1.2; tipStroke.Transparency = 0.35; tipStroke.Parent = tip
local tipPad = Instance.new("UIPadding")
tipPad.PaddingTop = UDim.new(0, 8); tipPad.PaddingBottom = UDim.new(0, 8)
tipPad.PaddingLeft = UDim.new(0, 10); tipPad.PaddingRight = UDim.new(0, 10); tipPad.Parent = tip
local tipList = Instance.new("UIListLayout"); tipList.Padding = UDim.new(0, 2); tipList.SortOrder = Enum.SortOrder.LayoutOrder; tipList.Parent = tip

local function showTip(lines)
	for _, c in tip:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	for i, ln in lines do
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1; l.AutomaticSize = Enum.AutomaticSize.XY
		l.Font = ln.bold and Enum.Font.GothamBold or Enum.Font.Gotham
		l.TextSize = ln.size or 14; l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextColor3 = ln.color or Color3.fromRGB(230, 232, 240); l.Text = ln.text; l.ZIndex = 61
		l.LayoutOrder = i; l.Parent = tip
	end
	tip.Visible = true
end
local function hideTip()
	tip.Visible = false
end
local function moveTip(x, y)
	local w, h = tip.AbsoluteSize.X, tip.AbsoluteSize.Y
	local screen = invGui.AbsoluteSize
	local px = math.min(x + 16, screen.X - w - 8)
	local py = math.min(y + 12, screen.Y - h - 8)
	tip.Position = UDim2.fromOffset(px, py)
end
-- Attach a hover tooltip to any GuiObject; buildLines() returns { {text=,color=,size=,bold=}, ... }.
local function attachTip(guiObj, buildLines)
	guiObj.MouseEnter:Connect(function(x, y)
		showTip(buildLines()); moveTip(x, y)
	end)
	guiObj.MouseMoved:Connect(function(x, y)
		if tip.Visible then moveTip(x, y) end
	end)
	guiObj.MouseLeave:Connect(hideTip)
end

local function weaponTipLines(weaponId)
	local w = weaponInfo(weaponId)
	if not w then return {} end
	local col = rarityColor(w.rarity)
	local dps = (w.damage or 0) * (w.fireRate or 0) * (w.pellets or 1)
	return {
		{ text = w.name, color = col, size = 16, bold = true },
		{ text = (invData.catalog.rarities[w.rarity].name) .. "  ·  Tier " .. tostring(w.tier), color = col, size = 12 },
		{ text = ("Damage: %s%s"):format(tostring(w.damage or "?"), w.pellets and ("  ×" .. w.pellets) or ""), size = 14 },
		{ text = ("Fire Rate: %s/s"):format(tostring(w.fireRate or "?")), size = 14 },
		{ text = ("Range: %s"):format(tostring(w.range or "?")), size = 14 },
		{ text = ("DPS: ~%d"):format(math.floor(dps + 0.5)), color = Color3.fromRGB(150, 220, 150), size = 14 },
	}
end

local function caseTipLines(caseId)
	local disp = invData.catalog.cases[caseId]
	if not disp then return {} end
	local lines = { { text = disp.name .. " — Drop Odds", color = Color3.fromRGB(150, 190, 255), size = 15, bold = true } }
	for _, o in (disp.odds or {}) do
		table.insert(lines, {
			text = ("%s: %.1f%%"):format(invData.catalog.rarities[o.rarity].name, o.pct),
			color = rarityColor(o.rarity), size = 14,
		})
	end
	return lines
end

-- Left-side Inventory button (opens the panel).
local invBtn = Instance.new("TextButton")
invBtn.Position = UDim2.fromOffset(16, 124); invBtn.Size = UDim2.fromOffset(220, 46)
invBtn.BackgroundColor3 = Color3.fromRGB(22, 24, 30); invBtn.BorderSizePixel = 0
invBtn.Font = Enum.Font.GothamBold; invBtn.TextSize = 15; invBtn.TextColor3 = Color3.fromRGB(235, 235, 245)
invBtn.Text = "INVENTORY"; invBtn.Parent = invGui; corner(invBtn, 10)
local ibStroke = Instance.new("UIStroke"); ibStroke.Color = ACCENT; ibStroke.Thickness = 1.5; ibStroke.Transparency = 0.4; ibStroke.Parent = invBtn

-- Panel.
local invPanel = Instance.new("Frame")
invPanel.AnchorPoint = Vector2.new(0.5, 0.5); invPanel.Position = UDim2.fromScale(0.5, 0.5)
invPanel.Size = UDim2.fromOffset(760, 480); invPanel.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
invPanel.BackgroundTransparency = 0.03; invPanel.BorderSizePixel = 0; invPanel.Visible = false; invPanel.Parent = invGui
corner(invPanel, 16)
local ipStroke = Instance.new("UIStroke"); ipStroke.Color = ACCENT; ipStroke.Thickness = 2; ipStroke.Transparency = 0.5; ipStroke.Parent = invPanel

local invTitle = Instance.new("TextLabel")
invTitle.Position = UDim2.new(0, 0, 0, 12); invTitle.Size = UDim2.new(1, 0, 0, 32); invTitle.BackgroundTransparency = 1
invTitle.Font = Enum.Font.GothamBlack; invTitle.TextSize = 24; invTitle.TextColor3 = Color3.fromRGB(240, 240, 245)
invTitle.Text = "INVENTORY"; invTitle.Parent = invPanel

local invCoins = Instance.new("TextLabel")
invCoins.Position = UDim2.new(1, -180, 0, 16); invCoins.Size = UDim2.fromOffset(150, 24); invCoins.BackgroundTransparency = 1
invCoins.Font = Enum.Font.GothamBold; invCoins.TextSize = 16; invCoins.TextXAlignment = Enum.TextXAlignment.Right
invCoins.TextColor3 = Color3.fromRGB(235, 190, 85); invCoins.Text = "0 Coins"; invCoins.Parent = invPanel

local invClose = Instance.new("TextButton")
invClose.AnchorPoint = Vector2.new(1, 0); invClose.Position = UDim2.new(1, -12, 0, 12); invClose.Size = UDim2.fromOffset(32, 32)
invClose.BackgroundColor3 = Color3.fromRGB(224, 82, 82); invClose.Font = Enum.Font.GothamBold; invClose.TextSize = 16
invClose.TextColor3 = Color3.fromRGB(255, 255, 255); invClose.Text = "✕"; invClose.Parent = invPanel; corner(invClose, 8)

-- Left sub-nav (Weapons / Cases / Potions).
local nav = Instance.new("Frame")
nav.Position = UDim2.fromOffset(16, 56); nav.Size = UDim2.fromOffset(150, 408); nav.BackgroundTransparency = 1; nav.Parent = invPanel
local navList = Instance.new("UIListLayout"); navList.Padding = UDim.new(0, 8); navList.Parent = nav
local navBtns = {}
local function navButton(id, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 46); b.BackgroundColor3 = CARD; b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold; b.TextSize = 16; b.TextColor3 = Color3.fromRGB(235, 235, 245); b.Text = text; b.Parent = nav
	corner(b, 8)
	navBtns[id] = b
	return b
end
navButton("weapons", "Weapons")
navButton("cases", "Cases")
navButton("potions", "Potions")

-- Content area (a frame per tab).
local content = Instance.new("Frame")
content.Position = UDim2.fromOffset(178, 56); content.Size = UDim2.fromOffset(566, 408)
content.BackgroundColor3 = Color3.fromRGB(17, 19, 24); content.BackgroundTransparency = 0.2; content.BorderSizePixel = 0
content.Parent = invPanel; corner(content, 12)

local weaponsTab = Instance.new("Frame")
weaponsTab.Size = UDim2.fromScale(1, 1); weaponsTab.BackgroundTransparency = 1; weaponsTab.Parent = content
local casesTab = Instance.new("Frame")
casesTab.Size = UDim2.fromScale(1, 1); casesTab.BackgroundTransparency = 1; casesTab.Visible = false; casesTab.Parent = content
local potionsTab = Instance.new("Frame")
potionsTab.Size = UDim2.fromScale(1, 1); potionsTab.BackgroundTransparency = 1; potionsTab.Visible = false; potionsTab.Parent = content

-- ---------- WEAPONS TAB ---------- 2 EQUIP SLOTS on top; all owned guns below. Click a slot to select it,
-- then click a gun to put it there (clicking a gun already in the other slot swaps them).
local slotsHint = Instance.new("TextLabel")
slotsHint.Position = UDim2.fromOffset(14, 10); slotsHint.Size = UDim2.new(1, -28, 0, 18); slotsHint.BackgroundTransparency = 1
slotsHint.Font = Enum.Font.GothamBold; slotsHint.TextSize = 13; slotsHint.TextXAlignment = Enum.TextXAlignment.Left
slotsHint.TextColor3 = Color3.fromRGB(170, 180, 195); slotsHint.Text = "YOUR LOADOUT — equip any 2 guns"; slotsHint.Parent = weaponsTab

local slotsRow = Instance.new("Frame")
slotsRow.Position = UDim2.fromOffset(14, 32); slotsRow.Size = UDim2.new(1, -28, 0, 96); slotsRow.BackgroundTransparency = 1; slotsRow.Parent = weaponsTab
local slotsList = Instance.new("UIListLayout")
slotsList.FillDirection = Enum.FillDirection.Horizontal; slotsList.Padding = UDim.new(0, 10); slotsList.Parent = slotsRow

local gunsHint = Instance.new("TextLabel")
gunsHint.Position = UDim2.fromOffset(14, 138); gunsHint.Size = UDim2.new(1, -28, 0, 18); gunsHint.BackgroundTransparency = 1
gunsHint.Font = Enum.Font.GothamBold; gunsHint.TextSize = 13; gunsHint.TextXAlignment = Enum.TextXAlignment.Left
gunsHint.TextColor3 = Color3.fromRGB(170, 180, 195); gunsHint.Text = ""; gunsHint.Parent = weaponsTab

local gunsScroll = Instance.new("ScrollingFrame")
gunsScroll.Position = UDim2.fromOffset(14, 160); gunsScroll.Size = UDim2.new(1, -28, 1, -172)
gunsScroll.BackgroundTransparency = 1; gunsScroll.BorderSizePixel = 0; gunsScroll.ScrollBarThickness = 6
gunsScroll.CanvasSize = UDim2.new(); gunsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; gunsScroll.Parent = weaponsTab
local gunsGrid = Instance.new("UIGridLayout")
gunsGrid.CellSize = UDim2.fromOffset(122, 92); gunsGrid.CellPadding = UDim2.fromOffset(10, 10); gunsGrid.Parent = gunsScroll

local activeSlot = 1 -- which loadout slot a gun click assigns to

local function weaponCard(parent, weaponId, subtitle, onClick, highlight)
	local info = weaponInfo(weaponId)
	local col = info and rarityColor(info.rarity) or Color3.fromRGB(150, 150, 160)
	local card = Instance.new("TextButton")
	card.BackgroundColor3 = col:Lerp(BLACK, 0.55); card.AutoButtonColor = onClick ~= nil; card.Text = ""
	card.BorderSizePixel = 0; card.Parent = parent
	corner(card, 8)
	local st = Instance.new("UIStroke"); st.Color = col; st.Thickness = highlight and 2.5 or 1.2
	st.Transparency = highlight and 0 or 0.35; st.Parent = card
	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(0, 0); bar.Size = UDim2.new(1, 0, 0, 4); bar.BackgroundColor3 = col
	bar.BorderSizePixel = 0; bar.Parent = card
	local name = Instance.new("TextLabel")
	name.Position = UDim2.fromOffset(4, 22); name.Size = UDim2.new(1, -8, 0, 24); name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold; name.TextSize = 14; name.TextColor3 = Color3.fromRGB(240, 240, 245)
	name.Text = info and info.name or weaponId; name.TextScaled = true; name.Parent = card
	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(4, 56); sub.Size = UDim2.new(1, -8, 0, 16); sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Gotham; sub.TextSize = 12; sub.TextColor3 = col; sub.Text = subtitle or ""; sub.TextScaled = true; sub.Parent = card
	if onClick then
		card.Activated:Connect(onClick)
	end
	attachTip(card, function() return weaponTipLines(weaponId) end) -- hover → weapon stats
	return card
end

local function renderWeaponsTab()
	if not invData then return end
	for _, c in slotsRow:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	for _, c in gunsScroll:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end

	-- The 2 equip slots (click one to make it the active target for gun clicks).
	local loadout = invData.loadout or {}
	for slot = 1, 2 do
		local id = loadout[slot]
		local info = id and weaponInfo(id)
		local isActive = (activeSlot == slot)
		local holder
		if info then
			holder = weaponCard(slotsRow, id, "SLOT " .. slot, nil, isActive)
		else
			holder = Instance.new("TextButton")
			holder.BackgroundColor3 = Color3.fromRGB(22, 25, 36); holder.Text = ""; holder.BorderSizePixel = 0
			holder.AutoButtonColor = true; holder.Parent = slotsRow
			corner(holder, 8)
			local hs = Instance.new("UIStroke"); hs.Color = isActive and ACCENT or Color3.fromRGB(60, 64, 80)
			hs.Thickness = isActive and 2.5 or 1; hs.Parent = holder
			local em = Instance.new("TextLabel")
			em.Position = UDim2.fromOffset(0, 26); em.Size = UDim2.new(1, 0, 0, 20); em.BackgroundTransparency = 1
			em.Font = Enum.Font.Gotham; em.TextSize = 13; em.TextColor3 = Color3.fromRGB(120, 125, 140)
			em.Text = "Empty"; em.Parent = holder
			local sl = Instance.new("TextLabel")
			sl.Position = UDim2.fromOffset(0, 56); sl.Size = UDim2.new(1, 0, 0, 16); sl.BackgroundTransparency = 1
			sl.Font = Enum.Font.GothamBold; sl.TextSize = 12; sl.TextColor3 = Color3.fromRGB(150, 160, 175)
			sl.Text = "SLOT " .. slot; sl.Parent = holder
		end
		holder.Size = UDim2.fromOffset(150, 92)
		holder.LayoutOrder = slot
		holder.Activated:Connect(function()
			activeSlot = slot
			renderWeaponsTab()
		end)
	end

	gunsHint.Text = ("ALL YOUR GUNS — click one to equip it in SLOT %d"):format(activeSlot)

	-- Owned guns sorted by tier; ones already in the loadout are highlighted.
	local ids = {}
	for _, id in invData.owned do
		if weaponInfo(id) then table.insert(ids, id) end
	end
	table.sort(ids, function(a, b)
		return (weaponInfo(a).tier or 0) < (weaponInfo(b).tier or 0)
	end)
	for _, id in ids do
		local inSlot = (id == loadout[1] and 1) or (id == loadout[2] and 2) or nil
		weaponCard(gunsScroll, id, inSlot and ("EQUIPPED · SLOT " .. inSlot) or (invData.catalog.rarities[weaponInfo(id).rarity].name),
			function()
				if inSlot ~= activeSlot then
					EquipSlot:FireServer({ slot = activeSlot, weaponId = id })
				end
			end, inSlot ~= nil)
	end
end

-- ---------- CASES TAB ----------
local casesScroll = Instance.new("ScrollingFrame")
casesScroll.Position = UDim2.fromOffset(14, 44); casesScroll.Size = UDim2.new(1, -28, 1, -58)
casesScroll.BackgroundTransparency = 1; casesScroll.BorderSizePixel = 0; casesScroll.ScrollBarThickness = 6
casesScroll.CanvasSize = UDim2.new(); casesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; casesScroll.Parent = casesTab
local casesGrid = Instance.new("UIGridLayout")
casesGrid.CellSize = UDim2.fromOffset(160, 150); casesGrid.CellPadding = UDim2.fromOffset(12, 12); casesGrid.Parent = casesScroll
local casesHint = Instance.new("TextLabel")
casesHint.Position = UDim2.fromOffset(14, 12); casesHint.Size = UDim2.new(1, -28, 0, 20); casesHint.BackgroundTransparency = 1
casesHint.Font = Enum.Font.GothamBold; casesHint.TextSize = 13; casesHint.TextXAlignment = Enum.TextXAlignment.Left
casesHint.TextColor3 = Color3.fromRGB(170, 180, 195); casesHint.Text = "OPEN CASES to unlock new weapons"; casesHint.Parent = casesTab

local playReel -- forward decl
local function renderCasesTab()
	if not invData then return end
	for _, c in casesScroll:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	local any = false
	for _, caseId in invData.catalog.rarityOrder do
		local disp = invData.catalog.cases[caseId]
		if not disp then continue end
		local count = invData.cases[caseId] or 0
		any = any or count > 0
		local card = Instance.new("Frame")
		card.BackgroundColor3 = Color3.fromRGB(26, 30, 44); card.BorderSizePixel = 0; card.Parent = casesScroll
		corner(card, 10)
		attachTip(card, function() return caseTipLines(caseId) end) -- hover → rarity drop odds
		local st = Instance.new("UIStroke"); st.Color = Color3.fromRGB(90, 120, 200); st.Thickness = 1.5; st.Transparency = 0.3; st.Parent = card
		local icon = Instance.new("TextLabel")
		icon.Position = UDim2.fromOffset(0, 10); icon.Size = UDim2.new(1, 0, 0, 40); icon.BackgroundTransparency = 1
		icon.Font = Enum.Font.GothamBlack; icon.TextSize = 22; icon.Text = "CASE"; icon.TextColor3 = Color3.fromRGB(120, 150, 210); icon.Parent = card
		local nm = Instance.new("TextLabel")
		nm.Position = UDim2.fromOffset(4, 52); nm.Size = UDim2.new(1, -8, 0, 20); nm.BackgroundTransparency = 1
		nm.Font = Enum.Font.GothamBold; nm.TextSize = 15; nm.TextColor3 = Color3.fromRGB(240, 240, 245); nm.Text = disp.name; nm.TextScaled = true; nm.Parent = card
		local cnt = Instance.new("TextLabel")
		cnt.Position = UDim2.fromOffset(4, 74); cnt.Size = UDim2.new(1, -8, 0, 16); cnt.BackgroundTransparency = 1
		cnt.Font = Enum.Font.Gotham; cnt.TextSize = 13; cnt.TextColor3 = Color3.fromRGB(180, 190, 205); cnt.Text = "Owned: " .. count; cnt.Parent = card
		local open = Instance.new("TextButton")
		open.AnchorPoint = Vector2.new(0.5, 1); open.Position = UDim2.new(0.5, 0, 1, -10); open.Size = UDim2.new(1, -20, 0, 36)
		open.Font = Enum.Font.GothamBlack; open.TextSize = 16; open.BorderSizePixel = 0; open.Parent = card; corner(open, 8)
		if count > 0 then
			open.BackgroundColor3 = ACCENT; open.TextColor3 = Color3.fromRGB(15, 25, 15); open.Text = "OPEN"
			open.Activated:Connect(function()
				if rolling then return end
				rolling = true
				open.Text = "..."; open.BackgroundColor3 = DIM
				OpenCase:FireServer({ caseId = caseId })
			end)
		else
			open.BackgroundColor3 = DIM; open.TextColor3 = Color3.fromRGB(160, 165, 180); open.Text = "NONE"; open.AutoButtonColor = false
		end
	end
	if not any then
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.fromOffset(540, 40); msg.BackgroundTransparency = 1; msg.Font = Enum.Font.GothamBold
		msg.TextSize = 15; msg.TextColor3 = Color3.fromRGB(150, 155, 170)
		msg.Text = "No cases right now — earn them by playing!"; msg.Parent = casesScroll
	end
end

-- ---------- POTIONS TAB (UI works; effects come later) ----------
local potionsScroll = Instance.new("ScrollingFrame")
potionsScroll.Position = UDim2.fromOffset(14, 44); potionsScroll.Size = UDim2.new(1, -28, 1, -58)
potionsScroll.BackgroundTransparency = 1; potionsScroll.BorderSizePixel = 0; potionsScroll.ScrollBarThickness = 6
potionsScroll.CanvasSize = UDim2.new(); potionsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; potionsScroll.Parent = potionsTab
local potionsGrid = Instance.new("UIGridLayout")
potionsGrid.CellSize = UDim2.fromOffset(160, 130); potionsGrid.CellPadding = UDim2.fromOffset(12, 12); potionsGrid.Parent = potionsScroll
local potionsHint = Instance.new("TextLabel")
potionsHint.Position = UDim2.fromOffset(14, 12); potionsHint.Size = UDim2.new(1, -28, 0, 20); potionsHint.BackgroundTransparency = 1
potionsHint.Font = Enum.Font.GothamBold; potionsHint.TextSize = 13; potionsHint.TextXAlignment = Enum.TextXAlignment.Left
potionsHint.TextColor3 = Color3.fromRGB(170, 180, 195); potionsHint.Text = "POTIONS — consumable boosts (coming soon)"; potionsHint.Parent = potionsTab

local function renderPotionsTab()
	if not invData then return end
	for _, c in potionsScroll:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	for potId, disp in invData.catalog.potions do
		local count = invData.potions[potId] or 0
		local col = rarityColor(disp.rarity)
		local card = Instance.new("Frame")
		card.BackgroundColor3 = col:Lerp(BLACK, 0.6); card.BorderSizePixel = 0; card.Parent = potionsScroll
		corner(card, 10)
		local st = Instance.new("UIStroke"); st.Color = col; st.Thickness = 1.4; st.Transparency = 0.3; st.Parent = card
		local icon = Instance.new("TextLabel")
		icon.Position = UDim2.fromOffset(0, 10); icon.Size = UDim2.new(1, 0, 0, 36); icon.BackgroundTransparency = 1
		icon.Font = Enum.Font.GothamBlack; icon.TextSize = 18; icon.Text = "POTION"; icon.TextColor3 = col; icon.Parent = card
		local nm = Instance.new("TextLabel")
		nm.Position = UDim2.fromOffset(4, 48); nm.Size = UDim2.new(1, -8, 0, 20); nm.BackgroundTransparency = 1
		nm.Font = Enum.Font.GothamBold; nm.TextSize = 15; nm.TextColor3 = Color3.fromRGB(240, 240, 245); nm.Text = disp.name; nm.TextScaled = true; nm.Parent = card
		local ds = Instance.new("TextLabel")
		ds.Position = UDim2.fromOffset(6, 70); ds.Size = UDim2.new(1, -12, 0, 30); ds.BackgroundTransparency = 1
		ds.Font = Enum.Font.Gotham; ds.TextSize = 12; ds.TextColor3 = Color3.fromRGB(190, 195, 210); ds.Text = disp.desc; ds.TextWrapped = true; ds.Parent = card
		local use = Instance.new("TextButton")
		use.AnchorPoint = Vector2.new(0.5, 1); use.Position = UDim2.new(0.5, 0, 1, -8); use.Size = UDim2.new(1, -20, 0, 30)
		use.Font = Enum.Font.GothamBold; use.TextSize = 14; use.BorderSizePixel = 0; use.Parent = card; corner(use, 8)
		use.BackgroundColor3 = DIM; use.TextColor3 = Color3.fromRGB(160, 165, 180); use.AutoButtonColor = false
		use.Text = "x" .. count .. "  (Soon)"
	end
end

-- ===== TAB SWITCHING =====
local function showTab(id)
	hideTip()
	activeTab = id
	weaponsTab.Visible = (id == "weapons")
	casesTab.Visible = (id == "cases")
	potionsTab.Visible = (id == "potions")
	for bid, b in navBtns do
		local on = (bid == id)
		b.BackgroundColor3 = on and ACCENT or CARD
		b.TextColor3 = on and Color3.fromRGB(15, 25, 15) or Color3.fromRGB(235, 235, 245)
	end
	if id == "weapons" then renderWeaponsTab()
	elseif id == "cases" then renderCasesTab()
	else renderPotionsTab() end
end
for bid, b in navBtns do
	b.Activated:Connect(function()
		if not rolling then showTab(bid) end
	end)
end

local function renderActive()
	invCoins.Text = "🪙 " .. fmt(invData and invData.coins or 0)
	if activeTab == "weapons" then renderWeaponsTab()
	elseif activeTab == "cases" then renderCasesTab()
	else renderPotionsTab() end
end

-- ===== CASE-OPENING REEL (CS:GO-style horizontal scroll) =====
local TILE_W, GAP = 100, 8
local STEP = TILE_W + GAP
local N_TILES = 50
local WIN_INDEX = 44
local REEL_W = 540
local REEL_H = 120

local reel = Instance.new("Frame") -- full overlay while opening
reel.Size = UDim2.fromScale(1, 1); reel.BackgroundColor3 = Color3.fromRGB(8, 9, 14); reel.BackgroundTransparency = 0.08
reel.BorderSizePixel = 0; reel.Visible = false; reel.ZIndex = 5; reel.Parent = invPanel; corner(reel, 16)
local reelTitle = Instance.new("TextLabel")
reelTitle.Position = UDim2.new(0, 0, 0, 40); reelTitle.Size = UDim2.new(1, 0, 0, 30); reelTitle.BackgroundTransparency = 1
reelTitle.Font = Enum.Font.GothamBlack; reelTitle.TextSize = 24; reelTitle.TextColor3 = Color3.fromRGB(240, 240, 245)
reelTitle.Text = "OPENING..."; reelTitle.ZIndex = 6; reelTitle.Parent = reel
local window = Instance.new("Frame")
window.AnchorPoint = Vector2.new(0.5, 0.5); window.Position = UDim2.fromScale(0.5, 0.5); window.Size = UDim2.fromOffset(REEL_W, REEL_H)
window.BackgroundColor3 = Color3.fromRGB(16, 18, 26); window.BorderSizePixel = 0; window.ClipsDescendants = true; window.ZIndex = 6; window.Parent = reel
corner(window, 10)
local strip = Instance.new("Frame")
strip.Position = UDim2.fromOffset(0, 0); strip.Size = UDim2.fromOffset(N_TILES * STEP, REEL_H); strip.BackgroundTransparency = 1; strip.ZIndex = 6; strip.Parent = window
local pointer = Instance.new("Frame")
pointer.AnchorPoint = Vector2.new(0.5, 0.5); pointer.Position = UDim2.fromScale(0.5, 0.5); pointer.Size = UDim2.fromOffset(3, REEL_H)
pointer.BackgroundColor3 = ACCENT; pointer.BorderSizePixel = 0; pointer.ZIndex = 8; pointer.Parent = window
local resultLabel = Instance.new("TextLabel")
resultLabel.AnchorPoint = Vector2.new(0.5, 0); resultLabel.Position = UDim2.new(0.5, 0, 0.5, REEL_H / 2 + 16); resultLabel.Size = UDim2.fromOffset(560, 30)
resultLabel.BackgroundTransparency = 1; resultLabel.Font = Enum.Font.GothamBlack; resultLabel.TextSize = 22; resultLabel.Text = ""
resultLabel.TextColor3 = Color3.fromRGB(240, 240, 245); resultLabel.ZIndex = 7; resultLabel.Parent = reel
local reelBtn = Instance.new("TextButton") -- doubles as Skip (while rolling) and Continue (after)
reelBtn.AnchorPoint = Vector2.new(0.5, 1); reelBtn.Position = UDim2.new(0.5, 0, 1, -34); reelBtn.Size = UDim2.fromOffset(200, 44)
reelBtn.BackgroundColor3 = CARD; reelBtn.Font = Enum.Font.GothamBold; reelBtn.TextSize = 18; reelBtn.TextColor3 = Color3.fromRGB(235, 235, 245)
reelBtn.Text = "SKIP"; reelBtn.ZIndex = 7; reelBtn.Parent = reel; corner(reelBtn, 8)

local activeTween = nil
local finishReel = nil

playReel = function(caseId, wonId, duplicate, coins)
	local disp = invData.catalog.cases[caseId]
	local poolIds = disp and disp.poolIds or { wonId }
	for _, c in strip:GetChildren() do c:Destroy() end
	for i = 1, N_TILES do
		local id = (i == WIN_INDEX) and wonId or poolIds[math.random(1, #poolIds)]
		local info = weaponInfo(id)
		local col = info and rarityColor(info.rarity) or Color3.fromRGB(150, 150, 160)
		local tile = Instance.new("Frame")
		tile.Position = UDim2.fromOffset((i - 1) * STEP, 8); tile.Size = UDim2.fromOffset(TILE_W, REEL_H - 16)
		tile.BackgroundColor3 = col:Lerp(BLACK, 0.5); tile.BorderSizePixel = 0; tile.ZIndex = 6; tile.Parent = strip
		corner(tile, 8)
		local ts = Instance.new("UIStroke"); ts.Color = col; ts.Thickness = 1.5; ts.Parent = tile
		local ic = Instance.new("TextLabel")
		ic.Position = UDim2.fromOffset(0, 12); ic.Size = UDim2.new(1, 0, 0, 34); ic.BackgroundTransparency = 1
		ic.Font = Enum.Font.GothamBlack; ic.TextSize = 12; ic.Text = ""; ic.BackgroundTransparency = 1; ic.ZIndex = 7; ic.Parent = tile
		local tbar = Instance.new("Frame"); tbar.Position = UDim2.fromOffset(0, 0); tbar.Size = UDim2.new(1, 0, 0, 4)
		tbar.BackgroundColor3 = col; tbar.BorderSizePixel = 0; tbar.ZIndex = 7; tbar.Parent = tile
		local nm = Instance.new("TextLabel")
		nm.Position = UDim2.fromOffset(4, 34); nm.Size = UDim2.new(1, -8, 0, 26); nm.BackgroundTransparency = 1
		nm.Font = Enum.Font.GothamBold; nm.TextSize = 13; nm.TextColor3 = Color3.fromRGB(240, 240, 245)
		nm.Text = info and info.name or id; nm.TextScaled = true; nm.ZIndex = 7; nm.Parent = tile
		local rr = Instance.new("TextLabel")
		rr.Position = UDim2.fromOffset(4, 64); rr.Size = UDim2.new(1, -8, 0, 16); rr.BackgroundTransparency = 1
		rr.Font = Enum.Font.Gotham; rr.TextSize = 11; rr.TextColor3 = col
		rr.Text = info and invData.catalog.rarities[info.rarity].name or ""; rr.TextScaled = true; rr.ZIndex = 7; rr.Parent = tile
	end

	reelTitle.Text = "OPENING " .. (disp and disp.name or "CASE"):upper()
	resultLabel.Text = ""
	reelBtn.Text = "SKIP"; reelBtn.BackgroundColor3 = CARD; reelBtn.TextColor3 = Color3.fromRGB(235, 235, 245)
	reel.Visible = true

	local jitter = math.random(-10, 10) + (TILE_W * 0.5) * (math.random() - 0.5)
	local target = math.floor(REEL_W / 2 - ((WIN_INDEX - 1) * STEP + TILE_W / 2) + jitter)
	strip.Position = UDim2.fromOffset(0, 0)

	local revealed = false
	finishReel = function()
		if revealed then return end
		revealed = true
		if activeTween then activeTween:Cancel() end
		strip.Position = UDim2.fromOffset(target, 0)
		local info = weaponInfo(wonId)
		local col = info and rarityColor(info.rarity) or Color3.fromRGB(240, 240, 245)
		if duplicate then
			resultLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
			resultLabel.Text = ("Duplicate %s — sold for 🪙 %d"):format(info and info.name or wonId, coins)
		else
			resultLabel.TextColor3 = col
			resultLabel.Text = ("Unlocked %s!"):format(info and info.name or wonId)
		end
		reelBtn.Text = "CONTINUE"; reelBtn.BackgroundColor3 = ACCENT; reelBtn.TextColor3 = Color3.fromRGB(15, 25, 15)
	end

	activeTween = TweenService:Create(strip, TweenInfo.new(4.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(target, 0) })
	activeTween.Completed:Connect(function()
		finishReel()
	end)
	activeTween:Play()
end

reelBtn.Activated:Connect(function()
	if not finishReel then return end
	if reelBtn.Text == "CONTINUE" then
		reel.Visible = false
		rolling = false
		renderActive()
	else
		finishReel() -- SKIP: snap to the result
	end
end)

-- ===== OPEN / CLOSE + REMOTE WIRING =====
local function openInventory()
	InvRequest:FireServer()
	showTab(activeTab)
	renderActive()
	invPanel.Visible = true
end
invBtn.Activated:Connect(openInventory)
invClose.Activated:Connect(function()
	if rolling then return end -- don't close mid-open
	hideTip()
	invPanel.Visible = false
end)

InvSync.OnClientEvent:Connect(function(snap)
	if typeof(snap) ~= "table" then return end
	invData = snap
	if invPanel.Visible then
		renderActive()
	end
end)

CaseResult.OnClientEvent:Connect(function(res)
	if typeof(res) ~= "table" or not res.caseId then
		rolling = false
		return
	end
	showTab("cases") -- make sure we're on the cases view behind the reel
	playReel(res.caseId, res.wonId, res.duplicate == true, tonumber(res.coins) or 0)
end)

-- =====================================================================================================
-- ===== RUN SUMMARY CARD ("Run over — Wave 14 · 87 kills · +215 Coins") ===============================
-- =====================================================================================================
-- The game place sends { summary = { wave, kills, money, win? } } in TeleportData when it returns you
-- to the lobby (death or victory). Show it once as a small card at the top of the screen.
do
	local TeleportService = game:GetService("TeleportService")
	local ok, td = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	local summary = ok and typeof(td) == "table" and typeof(td.summary) == "table" and td.summary or nil
	if summary then
		local SHOW_SECONDS = 8
		local isWin = summary.win == true

		local card = Instance.new("Frame")
		card.Name = "RunSummary"
		card.AnchorPoint = Vector2.new(0.5, 0)
		card.Position = UDim2.new(0.5, 0, 0, -110) -- starts off-screen, slides down
		card.Size = UDim2.fromOffset(360, 92)
		card.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
		card.BackgroundTransparency = 0.05
		card.BorderSizePixel = 0
		card.Parent = gui
		corner(card, 12)
		local cStroke = Instance.new("UIStroke")
		cStroke.Color = isWin and ACCENT or Color3.fromRGB(224, 82, 82)
		cStroke.Transparency = 0.35
		cStroke.Thickness = 1.5
		cStroke.Parent = card

		local cTitle = Instance.new("TextLabel")
		cTitle.Position = UDim2.fromOffset(0, 14)
		cTitle.Size = UDim2.new(1, 0, 0, 24)
		cTitle.BackgroundTransparency = 1
		cTitle.Font = Enum.Font.GothamBlack
		cTitle.TextSize = 20
		cTitle.TextColor3 = isWin and ACCENT or Color3.fromRGB(224, 82, 82)
		cTitle.Text = isWin and "VICTORY!" or "RUN OVER"
		cTitle.Parent = card

		local cLine = Instance.new("TextLabel")
		cLine.Position = UDim2.fromOffset(0, 44)
		cLine.Size = UDim2.new(1, 0, 0, 20)
		cLine.BackgroundTransparency = 1
		cLine.Font = Enum.Font.GothamBold
		cLine.TextSize = 15
		cLine.TextColor3 = Color3.fromRGB(238, 240, 245)
		cLine.Text = ("Wave %d   ·   %d kills   ·   +%s Coins"):format(
			tonumber(summary.wave) or 0,
			tonumber(summary.kills) or 0,
			fmt(tonumber(summary.money) or 0)
		)
		cLine.Parent = card

		local cHint = Instance.new("TextLabel")
		cHint.Position = UDim2.fromOffset(0, 66)
		cHint.Size = UDim2.new(1, 0, 0, 14)
		cHint.BackgroundTransparency = 1
		cHint.Font = Enum.Font.Gotham
		cHint.TextSize = 11
		cHint.TextColor3 = Color3.fromRGB(150, 156, 168)
		cHint.Text = "Coins banked to your account"
		cHint.Parent = card

		local cClose = Instance.new("TextButton")
		cClose.AnchorPoint = Vector2.new(1, 0)
		cClose.Position = UDim2.new(1, -6, 0, 6)
		cClose.Size = UDim2.fromOffset(22, 22)
		cClose.BackgroundTransparency = 1
		cClose.Font = Enum.Font.GothamBold
		cClose.TextSize = 14
		cClose.TextColor3 = Color3.fromRGB(150, 156, 168)
		cClose.Text = "✕"
		cClose.Parent = card

		local dismissed = false
		local function dismiss()
			if dismissed then return end
			dismissed = true
			local out = TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.new(0.5, 0, 0, -110),
			})
			out.Completed:Once(function()
				card:Destroy()
			end)
			out:Play()
		end
		cClose.Activated:Connect(dismiss)

		TweenService:Create(card, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0, 18),
		}):Play()
		task.delay(SHOW_SECONDS, dismiss)
	end
end

print("[LobbyClient] started")
