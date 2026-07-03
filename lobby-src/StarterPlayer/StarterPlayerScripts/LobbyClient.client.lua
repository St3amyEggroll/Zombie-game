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

-- ===== THEME (synced copy of the game's UITheme — gritty apocalypse; change there, mirror here) =====
-- FONTS: paste the same Creator Store family ids as src/.../UITheme.lua FONT_IDS. Blank = fallbacks.
local FONT_IDS = { Title = "", Body = "" } -- Black Ops One / Orbitron
local function makeFace(id, weight, fallbackEnum)
	if id and id ~= "" then
		local ok, face = pcall(function()
			return Font.new("rbxassetid://" .. id, weight)
		end)
		if ok and face then return face end
	end
	return Font.new(Font.fromEnum(fallbackEnum).Family, weight)
end
local TITLE_FACE = makeFace(FONT_IDS.Title, Enum.FontWeight.Regular, Enum.Font.Sarpanch)
local BODY_FACE  = makeFace(FONT_IDS.Body, Enum.FontWeight.Medium, Enum.Font.Michroma)
local BODYB_FACE = makeFace(FONT_IDS.Body, Enum.FontWeight.Bold, Enum.Font.Michroma)

local PANEL   = Color3.fromRGB(21, 24, 17)
local PANEL2  = Color3.fromRGB(29, 33, 23)
local TRACK   = Color3.fromRGB(36, 41, 28)
local LINE    = Color3.fromRGB(74, 82, 56)
local TBLACK  = Color3.fromRGB(6, 7, 5)
local ACCENT  = Color3.fromRGB(124, 219, 35)   -- toxic green
local ORANGE  = Color3.fromRGB(255, 96, 34)    -- blood orange
local ORANGE_DK = Color3.fromRGB(150, 44, 12)
local TEXTCOL = Color3.fromRGB(222, 227, 209)
local DIMTEXT = Color3.fromRGB(134, 142, 116)
local GOLD    = Color3.fromRGB(230, 180, 76)
local DIM = TRACK          -- (legacy name: disabled-button fill)
local CARD = PANEL2        -- (legacy name: card/button fill)
local STUDS_TEXTURE = "rbxassetid://6965996718"

local function darker(c, f)
	return Color3.new(c.R * (1 - f), c.G * (1 - f), c.B * (1 - f))
end
local function ledge(o, color, thickness, transparency)
	local st = Instance.new("UIStroke")
	st.Color = color or TBLACK
	st.Thickness = thickness or 2
	st.Transparency = transparency or 0
	st.Parent = o
	return st
end
local function ldepth(o, k)
	local g = Instance.new("UIGradient")
	k = k or 0.22
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1 - k, 1 - k, 1 - k))
	g.Rotation = 90
	g.Parent = o
	return g
end
local function lstuds(frame, tile, transparency)
	frame.ClipsDescendants = true
	local img = Instance.new("ImageLabel")
	img.Name = "Studs"
	img.BackgroundTransparency = 1
	img.Image = STUDS_TEXTURE
	img.ScaleType = Enum.ScaleType.Tile
	img.TileSize = UDim2.fromOffset(tile or 42, tile or 42)
	img.ImageColor3 = darker(frame.BackgroundColor3, 0.45)
	img.ImageTransparency = transparency or 0.62
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = frame.ZIndex
	img.Parent = frame
	return img
end
-- Responsive: one live UIScale per ScreenGui (designed 1920x1080, clamped, touch bump).
local UserInputService = game:GetService("UserInputService")
local function lattach(screenGui)
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	local function compute()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		local sc = math.min(vp.X / 1920, vp.Y / 1080)
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			sc *= 1.12
		end
		return math.clamp(sc, 0.55, 1.3)
	end
	scale.Scale = compute()
	scale.Parent = screenGui
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			scale.Scale = compute()
		end)
	end
end

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
lattach(gui)

-- stats card
local stats = Instance.new("Frame")
stats.Position = UDim2.fromOffset(16, 64); stats.Size = UDim2.fromOffset(220, 96)
stats.BackgroundColor3 = PANEL; stats.BackgroundTransparency = 0; stats.BorderSizePixel = 0
stats.Parent = gui; corner(stats, 6)
lstuds(stats); ldepth(stats); ledge(stats); ledge(stats, LINE, 1, 0.5)
local sp = Instance.new("UIPadding"); sp.PaddingLeft = UDim.new(0, 12); sp.PaddingTop = UDim.new(0, 8); sp.Parent = stats
local sl = Instance.new("UIListLayout"); sl.Padding = UDim.new(0, 4); sl.Parent = stats
local function statLabel(color)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -12, 0, 26); l.BackgroundTransparency = 1; l.FontFace = BODYB_FACE
	l.TextSize = 18; l.TextXAlignment = Enum.TextXAlignment.Left; l.TextColor3 = color; l.Text = ""; l.Parent = stats
	return l
end
local moneyLabel = statLabel(GOLD)
local bestLabel = statLabel(TEXTCOL)

-- selection panel
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5); panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(600, 430); panel.BackgroundColor3 = PANEL
panel.BackgroundTransparency = 0; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 8)
lstuds(panel); ldepth(panel); ledge(panel, TBLACK, 3); ledge(panel, ACCENT, 1, 0.45)

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 14); title.Size = UDim2.new(1, 0, 0, 34); title.BackgroundTransparency = 1
title.FontFace = TITLE_FACE; title.TextSize = 28; title.TextColor3 = TEXTCOL
title.Text = "CHOOSE YOUR RUN"; title.Parent = panel

local function sectionLabel(text, y)
	local l = Instance.new("TextLabel")
	l.Position = UDim2.new(0, 24, 0, y); l.Size = UDim2.new(1, -48, 0, 20); l.BackgroundTransparency = 1
	l.FontFace = BODYB_FACE; l.TextSize = 18; l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = DIMTEXT; l.Text = text; l.Parent = panel
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
	b.FontFace = BODYB_FACE; b.TextSize = 20; b.TextColor3 = TEXTCOL; b.Parent = parent
	corner(b, 6); ledge(b, TBLACK, 2)
	return b
end

local mapLbl = sectionLabel("MAP", 58)
local mapRow = row(84, 48)
local diffLbl = sectionLabel("DIFFICULTY", 146)
local diffRow = row(172, 52)
local sizeLbl = sectionLabel("PARTY SIZE", 238)
local sizeRow = row(262, 48)

-- PARTY MODE has no panel at all: just one BIG red LEAVE button at the bottom of the screen with a
-- live status line above it (the billboard over the pad shows the rest).
local leaveBtn = Instance.new("TextButton")
leaveBtn.AnchorPoint = Vector2.new(0.5, 1); leaveBtn.Position = UDim2.new(0.5, 0, 1, -28)
leaveBtn.Size = UDim2.fromOffset(380, 70); leaveBtn.BackgroundColor3 = ORANGE; leaveBtn.BorderSizePixel = 0
leaveBtn.FontFace = TITLE_FACE; leaveBtn.TextSize = 28; leaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
leaveBtn.Text = "LEAVE PARTY"; leaveBtn.Visible = false; leaveBtn.Parent = gui
corner(leaveBtn, 8); ldepth(leaveBtn); ledge(leaveBtn, TBLACK, 3)

local leaveStatus = Instance.new("TextLabel")
leaveStatus.AnchorPoint = Vector2.new(0.5, 1); leaveStatus.Position = UDim2.new(0.5, 0, 1, -104)
leaveStatus.Size = UDim2.fromOffset(520, 26); leaveStatus.BackgroundTransparency = 1
leaveStatus.FontFace = BODYB_FACE; leaveStatus.TextSize = 18; leaveStatus.TextColor3 = TEXTCOL
leaveStatus.Text = ""; leaveStatus.Visible = false; leaveStatus.Parent = gui

local blockedMsg = Instance.new("TextLabel")
blockedMsg.Position = UDim2.new(0, 24, 0, 110); blockedMsg.Size = UDim2.new(1, -48, 0, 80); blockedMsg.BackgroundTransparency = 1
blockedMsg.FontFace = BODYB_FACE; blockedMsg.TextSize = 17; blockedMsg.TextWrapped = true
blockedMsg.TextColor3 = TEXTCOL; blockedMsg.Text = ""; blockedMsg.Visible = false; blockedMsg.Parent = panel

local mapBtns, diffBtns, sizeBtns = {}, {}, {}

local play = Instance.new("TextButton")
play.AnchorPoint = Vector2.new(0.5, 1); play.Position = UDim2.new(0.5, 0, 1, -40); play.Size = UDim2.fromOffset(300, 60)
play.BackgroundColor3 = ACCENT; play.FontFace = TITLE_FACE; play.TextSize = 24
play.TextColor3 = Color3.fromRGB(14, 22, 6); play.Text = "PLAY"; play.Parent = panel
corner(play, 6)
ldepth(play); ledge(play, TBLACK, 2)

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 1); status.Position = UDim2.new(0.5, 0, 1, -12); status.Size = UDim2.new(1, -40, 0, 24)
status.BackgroundTransparency = 1; status.FontFace = BODYB_FACE; status.TextSize = 15
status.TextColor3 = DIMTEXT; status.Text = ""; status.Parent = panel

-- ===== RENDER =====
local function refresh()
	if not unlocks then return end
	-- map buttons
	for _, b in mapBtns do b:Destroy() end
	mapBtns = {}
	for _, w in unlocks.worldOrder do
		local info = unlocks.worlds[w]
		local b = button(mapRow, 160, 48, cap(w))
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
		local b = button(diffRow, 100, 52, unlocked and cap(d) or (cap(d) .. " 🔒")) -- 94px: five fit (incl. Endless)
		b.LayoutOrder = #diffBtns + 1
		if not unlocked then
			b.AutoButtonColor = false; b.BackgroundColor3 = DIM; b.TextColor3 = Color3.fromRGB(150, 150, 160)
		else
			b.BackgroundColor3 = (sel.difficulty == d) and ACCENT or CARD
			b.TextColor3 = (sel.difficulty == d) and Color3.fromRGB(14, 22, 6) or TEXTCOL
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
		local b = button(sizeRow, 64, 48, tostring(n))
		b.LayoutOrder = n
		b.BackgroundColor3 = (sel.size == n) and ACCENT or CARD
		b.TextColor3 = (sel.size == n) and Color3.fromRGB(14, 22, 6) or TEXTCOL
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
	blockedMsg.Visible = (mode == "blocked")
	play.Visible = config
	-- PARTY mode: the modal disappears completely — just the big red LEAVE button + status line.
	panel.Visible = (mode ~= "party")
	leaveBtn.Visible = (mode == "party")
	leaveStatus.Visible = (mode == "party")
	if mode == "config" then
		title.Text = "SET UP YOUR RUN"
	else
		title.Text = "PARTY PAD"
	end
end

-- ===== EVENTS =====
local saveWarn = nil -- the profile-failed-to-load banner (built once, stays up all session)
StatsRemote.OnClientEvent:Connect(function(s)
	if typeof(s) ~= "table" then return end
	moneyLabel.Text = fmt(s.lobbyMoney or 0) .. " Coins"
	bestLabel.Text = "Best: Wave " .. tostring(s.bestWave or 0)
	-- All profile-load retries failed: this session runs on a fallback that will NEVER be saved
	-- (opening cases / buying is blocked server-side). Tell the player instead of failing silently.
	if s.noPersist and not saveWarn then
		saveWarn = Instance.new("TextLabel")
		saveWarn.AnchorPoint = Vector2.new(0.5, 0)
		saveWarn.Position = UDim2.new(0.5, 0, 0, 8)
		saveWarn.Size = UDim2.fromOffset(620, 36)
		saveWarn.BackgroundColor3 = ORANGE
		saveWarn.BorderSizePixel = 0
		saveWarn.FontFace = BODYB_FACE
		saveWarn.TextSize = 15
		saveWarn.TextColor3 = Color3.fromRGB(255, 255, 255)
		saveWarn.Text = "⚠  Your save data couldn't load — progress will NOT save. Please rejoin."
		saveWarn.ZIndex = 50
		saveWarn.Parent = gui
		corner(saveWarn, 8)
	end
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
		leaveStatus.Text = ("%s  ·  %s  —  waiting for players..."):format(cap(p.map or "?"), cap(p.difficulty or "?"))
	else
		setPanelMode("blocked")
		blockedMsg.Text = p.reason or "You can't join this pad right now."
	end
end)

ZoneLeave.OnClientEvent:Connect(function()
	panel.Visible = false
	leaveBtn.Visible = false
	leaveStatus.Visible = false
	status.Text = ""
end)

PartyStatus.OnClientEvent:Connect(function(info)
	if typeof(info) ~= "table" then return end
	if zoneMode == "party" then
		leaveStatus.Text = ("PARTY %d/%d  ·  STARTING IN %ds"):format(info.count or 1, info.size or 1, info.seconds or 0)
	end
end)

play.Activated:Connect(function()
	if zoneMode == "config" then
		FinalizeParty:FireServer({ map = sel.map, difficulty = sel.difficulty, size = sel.size })
	end
end)

leaveBtn.Activated:Connect(function()
	LeaveParty:FireServer()
end)

-- =====================================================================================================
-- ===== INVENTORY (Weapons / Cases / Potions) =========================================================
-- =====================================================================================================
local TweenService = game:GetService("TweenService")
local InvRequest = remotes:WaitForChild("InvRequest")
local InvSync    = remotes:WaitForChild("InvSync")
local EquipSlot = remotes:WaitForChild("EquipSlot")
local UpgradeGun = remotes:WaitForChild("UpgradeGun")
local OpenCase   = remotes:WaitForChild("OpenCase")
local CaseResult = remotes:WaitForChild("CaseResult")

local invData = nil          -- latest snapshot: { catalog, owned, selected, cases, potions, coins }
local activeTab = "weapons"
local rolling = false
local rollToken = 0          -- watchdog id: if the server never answers an open, unstick `rolling`
local armRollTimeout         -- assigned after the reel exists (needs its upvalues)

local BLACK = darker(PANEL, 0.5)

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

-- ===== INVENTORY GUI ===== top tab strip over a full-width grid; clicking a card slides in a DETAIL
-- pane on the right (equip / upgrade / open / info). Click the card again or the pane's X to close it.
local invGui = Instance.new("ScreenGui")
invGui.Name = "LobbyInventory"; invGui.ResetOnSpawn = false; invGui.IgnoreGuiInset = true; invGui.DisplayOrder = 11
invGui.Parent = playerGui
lattach(invGui)

local function hideTip() end -- (legacy no-op: hover tooltips were replaced by the detail pane)

-- Left-side Inventory button (opens the panel).
local invBtn = Instance.new("TextButton")
invBtn.Position = UDim2.fromOffset(16, 172); invBtn.Size = UDim2.fromOffset(220, 52)
invBtn.BackgroundColor3 = PANEL; invBtn.BorderSizePixel = 0
invBtn.FontFace = TITLE_FACE; invBtn.TextSize = 17; invBtn.TextColor3 = TEXTCOL
invBtn.Text = "INVENTORY"; invBtn.Parent = invGui; corner(invBtn, 6)
lstuds(invBtn); ldepth(invBtn); ledge(invBtn); ledge(invBtn, ACCENT, 1, 0.35)

local PANEL_W, PANEL_H = 780, 500
local DETAIL_W = 292

local invPanel = Instance.new("Frame")
invPanel.AnchorPoint = Vector2.new(0.5, 0.5); invPanel.Position = UDim2.fromScale(0.5, 0.5)
invPanel.Size = UDim2.fromOffset(PANEL_W, PANEL_H); invPanel.BackgroundColor3 = PANEL
invPanel.BorderSizePixel = 0; invPanel.Visible = false; invPanel.Parent = invGui
corner(invPanel, 8)
lstuds(invPanel); ldepth(invPanel); ledge(invPanel, TBLACK, 3); ledge(invPanel, ACCENT, 1, 0.45)

local invTitle = Instance.new("TextLabel")
invTitle.Position = UDim2.fromOffset(18, 0); invTitle.Size = UDim2.fromOffset(300, 46); invTitle.BackgroundTransparency = 1
invTitle.FontFace = TITLE_FACE; invTitle.TextSize = 24; invTitle.TextXAlignment = Enum.TextXAlignment.Left
invTitle.TextColor3 = TEXTCOL; invTitle.Text = "INVENTORY"; invTitle.Parent = invPanel

local invCoins = Instance.new("TextLabel")
invCoins.AnchorPoint = Vector2.new(1, 0); invCoins.Position = UDim2.new(1, -54, 0, 12); invCoins.Size = UDim2.fromOffset(170, 24)
invCoins.BackgroundTransparency = 1; invCoins.FontFace = BODYB_FACE; invCoins.TextSize = 16
invCoins.TextXAlignment = Enum.TextXAlignment.Right; invCoins.TextColor3 = GOLD; invCoins.Text = "0"; invCoins.Parent = invPanel

local invClose = Instance.new("TextButton")
invClose.AnchorPoint = Vector2.new(1, 0); invClose.Position = UDim2.new(1, -10, 0, 8); invClose.Size = UDim2.fromOffset(34, 34)
invClose.BackgroundColor3 = ORANGE; invClose.FontFace = BODYB_FACE; invClose.TextSize = 16
invClose.TextColor3 = Color3.fromRGB(255, 255, 255); invClose.Text = "✕"; invClose.Parent = invPanel
corner(invClose, 6); ledge(invClose)

-- Top tab strip.
local invTabs = Instance.new("Frame")
invTabs.Position = UDim2.fromOffset(14, 50); invTabs.Size = UDim2.new(1, -28, 0, 38); invTabs.BackgroundTransparency = 1; invTabs.Parent = invPanel
local invTabList = Instance.new("UIListLayout")
invTabList.FillDirection = Enum.FillDirection.Horizontal; invTabList.Padding = UDim.new(0, 8); invTabList.Parent = invTabs
local invTabBtns = {}
local function invTabButton(id, textStr)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(150, 38); b.BackgroundColor3 = PANEL2; b.BorderSizePixel = 0
	b.FontFace = TITLE_FACE; b.TextSize = 15; b.TextColor3 = DIMTEXT; b.Text = textStr; b.Parent = invTabs
	corner(b, 5); ledge(b, TBLACK, 2)
	local under = Instance.new("Frame")
	under.Name = "Under"; under.AnchorPoint = Vector2.new(0.5, 1); under.Position = UDim2.new(0.5, 0, 1, -3)
	under.Size = UDim2.new(1, -16, 0, 3); under.BackgroundColor3 = ACCENT; under.BorderSizePixel = 0
	under.Visible = false; under.Parent = b
	invTabBtns[id] = b
	return b
end
invTabButton("weapons", "WEAPONS")
invTabButton("cases", "CASES")
invTabButton("potions", "POTIONS")

-- Grid (full width; shrinks when the detail pane opens) + the detail pane.
local CONTENT_Y = 96
local invGrid = Instance.new("ScrollingFrame")
invGrid.Position = UDim2.fromOffset(14, CONTENT_Y); invGrid.Size = UDim2.new(1, -28, 1, -(CONTENT_Y + 14))
invGrid.BackgroundTransparency = 1; invGrid.BorderSizePixel = 0; invGrid.ScrollBarThickness = 6
invGrid.CanvasSize = UDim2.new(); invGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y; invGrid.Parent = invPanel
local invGridLayout = Instance.new("UIGridLayout")
invGridLayout.CellSize = UDim2.fromOffset(112, 104); invGridLayout.CellPadding = UDim2.fromOffset(10, 10); invGridLayout.Parent = invGrid

local invDetail = Instance.new("Frame")
invDetail.AnchorPoint = Vector2.new(1, 0); invDetail.Position = UDim2.new(1, -14, 0, CONTENT_Y)
invDetail.Size = UDim2.fromOffset(DETAIL_W, PANEL_H - CONTENT_Y - 14)
invDetail.BackgroundColor3 = PANEL2; invDetail.BorderSizePixel = 0; invDetail.Visible = false; invDetail.Parent = invPanel
corner(invDetail, 6); lstuds(invDetail, 42, 0.75); ledge(invDetail, TBLACK, 2); ledge(invDetail, LINE, 1, 0.5)

local selectedInv = nil -- { kind = "weapon"|"case"|"potion", id } — drives the detail pane

local function invLayout()
	if selectedInv then
		invGrid.Size = UDim2.new(1, -(28 + DETAIL_W + 10), 1, -(CONTENT_Y + 14))
		invDetail.Visible = true
	else
		invGrid.Size = UDim2.new(1, -28, 1, -(CONTENT_Y + 14))
		invDetail.Visible = false
	end
end

-- Level / copies / upgrade math for a gun, straight from the snapshot (nil-safe everywhere).
local function gunLevelInfo(weaponId)
	local info = weaponInfo(weaponId)
	local gl = invData and invData.catalog.gunLevels
	local level = (invData and invData.gunLevels and invData.gunLevels[weaponId]) or 1
	local copies = (invData and invData.gunCopies and invData.gunCopies[weaponId]) or 0
	local maxLevel = (gl and gl.maxLevel) or 10
	if not info or not gl or level >= maxLevel then
		return level, maxLevel, copies, nil, nil
	end
	local t = gl.thresholds[info.rarity] or gl.thresholds.common
	local need = t[level] or t[#t]
	local cost = gl.coinCosts[level] or gl.coinCosts[#gl.coinCosts]
	return level, maxLevel, copies, need, cost
end

local renderActive -- forward decl (grid + detail render)
local playReel -- forward decl (the reel section below assigns it)

local function invSelect(kind, id)
	if selectedInv and selectedInv.kind == kind and selectedInv.id == id then
		selectedInv = nil
	else
		selectedInv = { kind = kind, id = id }
	end
	renderActive()
end

local function clearChildren(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

-- Compact square card in the grid.
local function invCard(opts)
	local col = opts.color
	local isSel = selectedInv and selectedInv.kind == opts.kind and selectedInv.id == opts.id
	local f = Instance.new("TextButton")
	f.BackgroundColor3 = col:Lerp(BLACK, 0.62); f.AutoButtonColor = true; f.Text = ""
	f.BorderSizePixel = 0; f.LayoutOrder = opts.order or 0; f.Parent = invGrid
	corner(f, 6); ledge(f, isSel and ACCENT or TBLACK, 2)
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 4); bar.BackgroundColor3 = col; bar.BorderSizePixel = 0; bar.Parent = f
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(6, 12); nm.Size = UDim2.new(1, -12, 0, 40); nm.BackgroundTransparency = 1
	nm.FontFace = BODYB_FACE; nm.TextSize = 12; nm.TextWrapped = true
	nm.TextColor3 = TEXTCOL; nm.Text = opts.name; nm.Parent = f
	-- PHOTO SLOT: any catalog entry with an `image` id renders it on the card (add ids later, zero code).
	if typeof(opts.image) == "string" and opts.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.AnchorPoint = Vector2.new(0.5, 1); img.Position = UDim2.new(0.5, 0, 1, -24)
		img.Size = UDim2.fromOffset(64, 44); img.BackgroundTransparency = 1
		img.Image = opts.image; img.ScaleType = Enum.ScaleType.Fit; img.Parent = f
	end
	if opts.chip then
		local chip = Instance.new("TextLabel")
		chip.AnchorPoint = Vector2.new(1, 1); chip.Position = UDim2.new(1, -6, 1, -6)
		chip.Size = UDim2.fromOffset(46, 16); chip.BackgroundColor3 = darker(col, 0.7); chip.BorderSizePixel = 0
		chip.FontFace = BODYB_FACE; chip.TextSize = 10; chip.TextColor3 = col; chip.Text = opts.chip; chip.Parent = f
		corner(chip, 3)
	end
	if opts.tag then
		local tag = Instance.new("TextLabel")
		tag.Position = UDim2.fromOffset(6, 56); tag.Size = UDim2.new(1, -12, 0, 14); tag.BackgroundTransparency = 1
		tag.FontFace = TITLE_FACE; tag.TextSize = 10; tag.TextXAlignment = Enum.TextXAlignment.Left
		tag.TextColor3 = ACCENT; tag.Text = opts.tag; tag.Parent = f
	end
	f.Activated:Connect(function()
		invSelect(opts.kind, opts.id)
	end)
	return f
end

local function invEmptyNote(textStr)
	local msg = Instance.new("TextLabel")
	msg.Size = UDim2.fromOffset(480, 40); msg.BackgroundTransparency = 1; msg.FontFace = BODYB_FACE
	msg.TextSize = 14; msg.TextColor3 = DIMTEXT; msg.Text = textStr; msg.Parent = invGrid
end

-- Themed action button for the detail pane.
local function paneButton(textStr, fillA, fillB, textCol)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = fillA; b.BorderSizePixel = 0; b.AutoButtonColor = true
	b.FontFace = TITLE_FACE; b.TextSize = 14; b.TextColor3 = textCol; b.Text = textStr; b.Parent = invDetail
	corner(b, 5); ledge(b, TBLACK, 2)
	local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(fillA, fillB); g.Rotation = 90; g.Parent = b
	return b
end

-- ===== DETAIL PANE =====
local function renderInvDetail()
	clearChildren(invDetail)
	if not selectedInv or not invData then
		return
	end
	local kind, id = selectedInv.kind, selectedInv.id

	local dClose = Instance.new("TextButton")
	dClose.AnchorPoint = Vector2.new(1, 0); dClose.Position = UDim2.new(1, -6, 0, 6); dClose.Size = UDim2.fromOffset(24, 24)
	dClose.BackgroundTransparency = 1; dClose.FontFace = BODYB_FACE; dClose.TextSize = 14
	dClose.TextColor3 = DIMTEXT; dClose.Text = "✕"; dClose.Parent = invDetail
	dClose.Activated:Connect(function()
		selectedInv = nil
		renderActive()
	end)

	-- PHOTO SLOT: entries with an `image` id get a thumbnail in the pane's corner.
	local entry
	if kind == "weapon" then entry = weaponInfo(id)
	elseif kind == "case" then entry = invData.catalog.cases[id]
	else entry = invData.catalog.potions[id] end
	if entry and typeof(entry.image) == "string" and entry.image ~= "" then
		local thumb = Instance.new("ImageLabel")
		thumb.AnchorPoint = Vector2.new(1, 0); thumb.Position = UDim2.new(1, -34, 0, 8)
		thumb.Size = UDim2.fromOffset(72, 54); thumb.BackgroundTransparency = 1
		thumb.Image = entry.image; thumb.ScaleType = Enum.ScaleType.Fit; thumb.Parent = invDetail
	end

	local function bigTitle(textStr, col)
		local t = Instance.new("TextLabel")
		t.Position = UDim2.fromOffset(14, 12); t.Size = UDim2.new(1, -44, 0, 44); t.BackgroundTransparency = 1
		t.FontFace = TITLE_FACE; t.TextSize = 19; t.TextWrapped = true
		t.TextXAlignment = Enum.TextXAlignment.Left; t.TextColor3 = col or TEXTCOL; t.Text = textStr; t.Parent = invDetail
	end
	local function line(y, textStr, col, size, h)
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromOffset(14, y); l.Size = UDim2.new(1, -28, 0, h or 40); l.BackgroundTransparency = 1
		l.FontFace = BODY_FACE; l.TextSize = size or 12; l.TextWrapped = true
		l.TextXAlignment = Enum.TextXAlignment.Left; l.TextYAlignment = Enum.TextYAlignment.Top
		l.TextColor3 = col or TEXTCOL; l.Text = textStr; l.Parent = invDetail
	end

	if kind == "weapon" then
		local w = weaponInfo(id)
		if not w then return end
		local col = rarityColor(w.rarity)
		local level, maxLevel, copies, need, cost = gunLevelInfo(id)
		local dpl = (invData.catalog.gunLevels and invData.catalog.gunLevels.damagePerLevel) or 0
		local lvDamage = (w.damage or 0) * (1 + dpl * (level - 1))
		local dps = lvDamage * (w.fireRate or 0) * (w.pellets or 1)
		bigTitle(w.name, col)
		line(58, ((invData.catalog.rarities[w.rarity] or {}).name or "") .. "  ·  LV " .. level .. " / " .. maxLevel, col, 13, 18)
		line(80, ("DMG %.0f%s   ·   %s/s   ·   RNG %s\nDPS ~%d"):format(
			lvDamage, w.pellets and (" ×" .. w.pellets) or "", tostring(w.fireRate or "?"),
			tostring(w.range or "?"), math.floor(dps + 0.5)), TEXTCOL, 12, 36)

		-- Copies progress toward the next level.
		if need then
			line(122, ("COPIES  %d / %d"):format(copies, need), DIMTEXT, 11, 14)
			local track = Instance.new("Frame")
			track.Position = UDim2.fromOffset(14, 140); track.Size = UDim2.new(1, -28, 0, 8)
			track.BackgroundColor3 = darker(TRACK, 0.25); track.BorderSizePixel = 0; track.Parent = invDetail
			corner(track, 3)
			local frac = math.clamp(copies / need, 0, 1)
			if frac > 0 then
				local fillBar = Instance.new("Frame")
				fillBar.Size = UDim2.fromScale(frac, 1)
				fillBar.BackgroundColor3 = (copies >= need) and GOLD or ACCENT
				fillBar.BorderSizePixel = 0; fillBar.Parent = track
				corner(fillBar, 3)
			end
		else
			line(122, "MAX LEVEL — extra copies become Coins", GOLD, 12, 16)
		end

		-- Actions: equip into either slot; upgrade when the stack + Coins are there.
		local inS1 = (invData.loadout[1] == id)
		local inS2 = (invData.loadout[2] == id)
		local eq1 = paneButton(inS1 and "IN SLOT 1" or "EQUIP SLOT 1", PANEL2, darker(PANEL2, 0.3), inS1 and ACCENT or TEXTCOL)
		eq1.Position = UDim2.fromOffset(14, 162); eq1.Size = UDim2.new(0.5, -18, 0, 36)
		local eq2 = paneButton(inS2 and "IN SLOT 2" or "EQUIP SLOT 2", PANEL2, darker(PANEL2, 0.3), inS2 and ACCENT or TEXTCOL)
		eq2.AnchorPoint = Vector2.new(1, 0); eq2.Position = UDim2.new(1, -14, 0, 162); eq2.Size = UDim2.new(0.5, -18, 0, 36)
		eq1.Activated:Connect(function()
			if not inS1 then EquipSlot:FireServer({ slot = 1, weaponId = id }) end
		end)
		eq2.Activated:Connect(function()
			if not inS2 then EquipSlot:FireServer({ slot = 2, weaponId = id }) end
		end)

		if need then
			local canCopies = copies >= need
			local canCoins = (invData.coins or 0) >= (cost or 0)
			local up
			if canCopies and canCoins then
				up = paneButton(("UPGRADE  ·  🪙 %s"):format(fmt(cost or 0)), GOLD, darker(GOLD, 0.45), Color3.fromRGB(34, 24, 6))
				up.Activated:Connect(function()
					UpgradeGun:FireServer({ weaponId = id })
				end)
			else
				up = paneButton(canCopies and ("NEED 🪙 %s"):format(fmt(cost or 0))
					or ("NEED %d MORE COPIES"):format(need - copies), TRACK, darker(TRACK, 0.2), DIMTEXT)
				up.AutoButtonColor = false
			end
			up.AnchorPoint = Vector2.new(0.5, 1); up.Position = UDim2.new(0.5, 0, 1, -12); up.Size = UDim2.new(1, -28, 0, 42)
		end
	elseif kind == "case" then
		local disp = invData.catalog.cases[id]
		if not disp then return end
		local col = rarityColor(id)
		local count = invData.cases[id] or 0
		bigTitle(disp.name, col)
		line(58, ("You have: x%d"):format(count), TEXTCOL, 13, 18)
		-- Drop odds straight on the pane (this replaced the hover tooltip).
		local y = 84
		line(y, "DROP ODDS", DIMTEXT, 11, 14)
		y += 18
		for _, o in (disp.odds or {}) do
			line(y, ("%s  %.1f%%"):format((invData.catalog.rarities[o.rarity] or {}).name or o.rarity, o.pct),
				rarityColor(o.rarity), 12, 16)
			y += 17
		end
		local open
		if count > 0 then
			open = paneButton("OPEN CASE", ACCENT, darker(ACCENT, 0.5), Color3.fromRGB(14, 22, 6))
			open.Activated:Connect(function()
				if rolling then return end
				rolling = true
				armRollTimeout()
				OpenCase:FireServer({ caseId = id })
			end)
		else
			open = paneButton("NONE LEFT", TRACK, darker(TRACK, 0.2), DIMTEXT)
			open.AutoButtonColor = false
		end
		open.AnchorPoint = Vector2.new(0.5, 1); open.Position = UDim2.new(0.5, 0, 1, -12); open.Size = UDim2.new(1, -28, 0, 42)
	elseif kind == "potion" then
		local disp = invData.catalog.potions[id]
		if not disp then return end
		local col = rarityColor(disp.rarity)
		bigTitle(disp.name, col)
		line(58, disp.desc or "", TEXTCOL, 13, 40)
		line(102, ("You have: x%d"):format(invData.potions[id] or 0), DIMTEXT, 12, 16)
		local note = paneButton("DRINK IT IN A RUN", TRACK, darker(TRACK, 0.2), DIMTEXT)
		note.AutoButtonColor = false
		note.AnchorPoint = Vector2.new(0.5, 1); note.Position = UDim2.new(0.5, 0, 1, -12); note.Size = UDim2.new(1, -28, 0, 36)
	end
end

-- ===== GRID RENDERS =====
local function renderWeaponsGrid()
	local ids = {}
	for _, id in invData.owned do
		if weaponInfo(id) then table.insert(ids, id) end
	end
	table.sort(ids, function(a, b)
		return (weaponInfo(a).tier or 0) < (weaponInfo(b).tier or 0)
	end)
	for i, id in ids do
		local w = weaponInfo(id)
		local slotTag = (invData.loadout[1] == id and "EQUIPPED · S1") or (invData.loadout[2] == id and "EQUIPPED · S2") or nil
		local level = (invData.gunLevels and invData.gunLevels[id]) or 1
		invCard({ kind = "weapon", id = id, name = w.name, color = rarityColor(w.rarity), chip = "LV " .. level, tag = slotTag, order = i, image = w.image })
	end
end

local function renderCasesGrid()
	local any = false
	local order = 0
	for _, caseId in invData.catalog.rarityOrder do
		local disp = invData.catalog.cases[caseId]
		local count = invData.cases[caseId] or 0
		if disp and count > 0 then
			any = true
			order += 1
			invCard({ kind = "case", id = caseId, name = disp.name, color = rarityColor(caseId), chip = "x" .. count, order = order, image = disp.image })
		end
	end
	if not any then
		invEmptyNote("No cases right now — kill BOSSES in runs (or hit the SHOP) to get more!")
	end
end

local function renderPotionsGrid()
	local any = false
	local order = 0
	for _, rarity in invData.catalog.rarityOrder do
		for _, ptype in { "damage", "regen" } do
			local potId = ptype .. "_" .. rarity
			local disp = invData.catalog.potions[potId]
			local count = disp and (invData.potions[potId] or 0) or 0
			if disp and count > 0 then
				any = true
				order += 1
				invCard({ kind = "potion", id = potId, name = disp.name, color = rarityColor(disp.rarity), chip = "x" .. count, order = order, image = disp.image })
			end
		end
	end
	if not any then
		invEmptyNote("No potions yet — kill glowing ELITE zombies in runs to earn them!")
	end
end

-- ===== TAB SWITCHING + MASTER RENDER =====
local function showTab(id)
	activeTab = id
	selectedInv = nil -- switching tabs closes the pane
	for bid, b in invTabBtns do
		local on = (bid == id)
		b.TextColor3 = on and TEXTCOL or DIMTEXT
		b.Under.Visible = on
	end
end

renderActive = function()
	invCoins.Text = "🪙 " .. fmt(invData and invData.coins or 0)
	for bid, b in invTabBtns do
		local on = (bid == activeTab)
		b.TextColor3 = on and TEXTCOL or DIMTEXT
		b.Under.Visible = on
	end
	if not invData then return end
	clearChildren(invGrid)
	invLayout()
	if activeTab == "weapons" then renderWeaponsGrid()
	elseif activeTab == "cases" then renderCasesGrid()
	else renderPotionsGrid() end
	renderInvDetail()
end

for bid, b in invTabBtns do
	b.Activated:Connect(function()
		if not rolling then
			showTab(bid)
			renderActive()
		end
	end)
end

-- ===== CASE-OPENING REEL (CS:GO-style horizontal scroll) =====
local TILE_W, GAP = 100, 8
local STEP = TILE_W + GAP
local N_TILES = 50
local WIN_INDEX = 44
local REEL_W = 540
local REEL_H = 120

-- The reel lives on its OWN top layer (not inside the inventory panel) so BUY & OPEN can spin it from
-- the shop too — it draws over whichever panel launched it.
local reelGui = Instance.new("ScreenGui")
reelGui.Name = "LobbyCaseReel"; reelGui.ResetOnSpawn = false; reelGui.IgnoreGuiInset = true; reelGui.DisplayOrder = 13
reelGui.Parent = playerGui
lattach(reelGui)

local reel = Instance.new("Frame") -- overlay while opening
reel.AnchorPoint = Vector2.new(0.5, 0.5); reel.Position = UDim2.fromScale(0.5, 0.5)
reel.Size = UDim2.fromOffset(760, 480); reel.BackgroundColor3 = darker(PANEL, 0.45); reel.BackgroundTransparency = 0
reel.BorderSizePixel = 0; reel.Visible = false; reel.ZIndex = 5; reel.Parent = reelGui; corner(reel, 8)
lstuds(reel); ledge(reel, TBLACK, 3); ledge(reel, ACCENT, 1, 0.45)
local reelTitle = Instance.new("TextLabel")
reelTitle.Position = UDim2.new(0, 0, 0, 40); reelTitle.Size = UDim2.new(1, 0, 0, 30); reelTitle.BackgroundTransparency = 1
reelTitle.FontFace = TITLE_FACE; reelTitle.TextSize = 24; reelTitle.TextColor3 = TEXTCOL
reelTitle.Text = "OPENING..."; reelTitle.ZIndex = 6; reelTitle.Parent = reel
local window = Instance.new("Frame")
window.AnchorPoint = Vector2.new(0.5, 0.5); window.Position = UDim2.fromScale(0.5, 0.5); window.Size = UDim2.fromOffset(REEL_W, REEL_H)
window.BackgroundColor3 = darker(PANEL, 0.35); window.BorderSizePixel = 0; window.ClipsDescendants = true; window.ZIndex = 6; window.Parent = reel
corner(window, 10)
local strip = Instance.new("Frame")
strip.Position = UDim2.fromOffset(0, 0); strip.Size = UDim2.fromOffset(N_TILES * STEP, REEL_H); strip.BackgroundTransparency = 1; strip.ZIndex = 6; strip.Parent = window
local pointer = Instance.new("Frame")
pointer.AnchorPoint = Vector2.new(0.5, 0.5); pointer.Position = UDim2.fromScale(0.5, 0.5); pointer.Size = UDim2.fromOffset(3, REEL_H)
pointer.BackgroundColor3 = ACCENT; pointer.BorderSizePixel = 0; pointer.ZIndex = 8; pointer.Parent = window
local resultLabel = Instance.new("TextLabel")
resultLabel.AnchorPoint = Vector2.new(0.5, 0); resultLabel.Position = UDim2.new(0.5, 0, 0.5, REEL_H / 2 + 16); resultLabel.Size = UDim2.fromOffset(560, 30)
resultLabel.BackgroundTransparency = 1; resultLabel.FontFace = TITLE_FACE; resultLabel.TextSize = 22; resultLabel.Text = ""
resultLabel.TextColor3 = TEXTCOL; resultLabel.ZIndex = 7; resultLabel.Parent = reel
local reelBtn = Instance.new("TextButton") -- doubles as Skip (while rolling) and Continue (after)
reelBtn.AnchorPoint = Vector2.new(0.5, 1); reelBtn.Position = UDim2.new(0.5, 0, 1, -34); reelBtn.Size = UDim2.fromOffset(200, 44)
reelBtn.BackgroundColor3 = CARD; reelBtn.FontFace = BODYB_FACE; reelBtn.TextSize = 18; reelBtn.TextColor3 = TEXTCOL
reelBtn.Text = "SKIP"; reelBtn.ZIndex = 7; reelBtn.Parent = reel; corner(reelBtn, 8)

local activeTween = nil
local finishReel = nil

playReel = function(caseId, wonId, res)
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
		ic.FontFace = TITLE_FACE; ic.TextSize = 12; ic.Text = ""; ic.BackgroundTransparency = 1; ic.ZIndex = 7; ic.Parent = tile
		local tbar = Instance.new("Frame"); tbar.Position = UDim2.fromOffset(0, 0); tbar.Size = UDim2.new(1, 0, 0, 4)
		tbar.BackgroundColor3 = col; tbar.BorderSizePixel = 0; tbar.ZIndex = 7; tbar.Parent = tile
		local nm = Instance.new("TextLabel")
		nm.Position = UDim2.fromOffset(4, 34); nm.Size = UDim2.new(1, -8, 0, 26); nm.BackgroundTransparency = 1
		nm.FontFace = BODYB_FACE; nm.TextSize = 13; nm.TextColor3 = TEXTCOL
		nm.Text = info and info.name or id; nm.TextScaled = true; nm.ZIndex = 7; nm.Parent = tile
		local rr = Instance.new("TextLabel")
		rr.Position = UDim2.fromOffset(4, 64); rr.Size = UDim2.new(1, -8, 0, 16); rr.BackgroundTransparency = 1
		rr.FontFace = BODY_FACE; rr.TextSize = 11; rr.TextColor3 = col
		rr.Text = info and invData.catalog.rarities[info.rarity].name or ""; rr.TextScaled = true; rr.ZIndex = 7; rr.Parent = tile
	end

	reelTitle.Text = "OPENING " .. (disp and disp.name or "CASE"):upper()
	resultLabel.Text = ""
	reelBtn.Text = "SKIP"; reelBtn.BackgroundColor3 = CARD; reelBtn.TextColor3 = TEXTCOL
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
		local col = info and rarityColor(info.rarity) or TEXTCOL
		local gunName = info and info.name or wonId
		local copies = tonumber(res.copies) or 1
		if res.unlocked then
			resultLabel.TextColor3 = col
			resultLabel.Text = ("Unlocked %s!  (+%d copies)"):format(gunName, copies)
		elseif res.maxed then
			resultLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
			resultLabel.Text = ("+%d %s copies → 🪙 %d  (max level)"):format(copies, gunName, tonumber(res.coins) or 0)
		else
			resultLabel.TextColor3 = col
			resultLabel.Text = ("+%d %s copies"):format(copies, gunName)
		end
		reelBtn.Text = "CONTINUE"; reelBtn.BackgroundColor3 = ACCENT; reelBtn.TextColor3 = Color3.fromRGB(14, 22, 6)
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

-- Watchdog: `rolling` is set the moment an open is requested; if no CaseResult ever arrives (server
-- rejected silently, remote lost), unlock the UI instead of soft-locking the panels until rejoin.
armRollTimeout = function()
	rollToken += 1
	local myToken = rollToken
	task.delay(6, function()
		if rolling and myToken == rollToken and not reel.Visible then
			rolling = false
			renderActive()
		end
	end)
end

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
	rollToken += 1 -- a reply arrived; disarm the watchdog
	if typeof(res) ~= "table" or res.failed or not res.caseId then
		rolling = false
		if invPanel.Visible then
			renderActive() -- restore any "..." button state
		end
		return
	end
	if invPanel.Visible then
		showTab("cases") -- make sure we're on the cases view behind the reel
	end
	playReel(res.caseId, res.wonId, res)
end)

-- =====================================================================================================
-- ===== SHOP ===== single-column stock list (left) + a FEATURED detail pane (right) that defaults to
-- the Deal of the Rotation. Click any row to feature it; BUY / BUY & OPEN live on the pane.
-- =====================================================================================================
local ShopSync  = remotes:WaitForChild("ShopSync")
local ShopClose = remotes:WaitForChild("ShopClose")
local ShopBuy   = remotes:WaitForChild("ShopBuy")

local shopData = nil     -- latest ShopSync payload
local shopDeadline = 0   -- os.clock() when the current rotation restocks
local shopSelected = nil -- featured slot index (defaults to the deal)

local shopGui = Instance.new("ScreenGui")
shopGui.Name = "LobbyShop"; shopGui.ResetOnSpawn = false; shopGui.IgnoreGuiInset = true; shopGui.DisplayOrder = 10
shopGui.Parent = playerGui
lattach(shopGui)

local shopPanel = Instance.new("Frame")
shopPanel.AnchorPoint = Vector2.new(0.5, 0.5); shopPanel.Position = UDim2.fromScale(0.5, 0.5)
shopPanel.Size = UDim2.fromOffset(780, 500); shopPanel.BackgroundColor3 = PANEL
shopPanel.BorderSizePixel = 0; shopPanel.Visible = false; shopPanel.Parent = shopGui
corner(shopPanel, 8)
lstuds(shopPanel); ldepth(shopPanel); ledge(shopPanel, TBLACK, 3); ledge(shopPanel, GOLD, 1, 0.45)

local shopTitle = Instance.new("TextLabel")
shopTitle.Position = UDim2.fromOffset(18, 0); shopTitle.Size = UDim2.fromOffset(200, 46); shopTitle.BackgroundTransparency = 1
shopTitle.FontFace = TITLE_FACE; shopTitle.TextSize = 24; shopTitle.TextXAlignment = Enum.TextXAlignment.Left
shopTitle.TextColor3 = TEXTCOL; shopTitle.Text = "SHOP"; shopTitle.Parent = shopPanel

local shopRestock = Instance.new("TextLabel")
shopRestock.Position = UDim2.fromOffset(160, 0); shopRestock.Size = UDim2.fromOffset(280, 46); shopRestock.BackgroundTransparency = 1
shopRestock.FontFace = BODYB_FACE; shopRestock.TextSize = 13; shopRestock.TextXAlignment = Enum.TextXAlignment.Left
shopRestock.TextColor3 = DIMTEXT; shopRestock.Text = ""; shopRestock.Parent = shopPanel

local shopCoins = Instance.new("TextLabel")
shopCoins.AnchorPoint = Vector2.new(1, 0); shopCoins.Position = UDim2.new(1, -54, 0, 12); shopCoins.Size = UDim2.fromOffset(170, 24)
shopCoins.BackgroundTransparency = 1; shopCoins.FontFace = BODYB_FACE; shopCoins.TextSize = 16
shopCoins.TextXAlignment = Enum.TextXAlignment.Right; shopCoins.TextColor3 = GOLD; shopCoins.Text = ""; shopCoins.Parent = shopPanel

local shopX = Instance.new("TextButton")
shopX.AnchorPoint = Vector2.new(1, 0); shopX.Position = UDim2.new(1, -10, 0, 8); shopX.Size = UDim2.fromOffset(34, 34)
shopX.BackgroundColor3 = ORANGE; shopX.FontFace = BODYB_FACE; shopX.TextSize = 16
shopX.TextColor3 = Color3.fromRGB(255, 255, 255); shopX.Text = "✕"; shopX.Parent = shopPanel
corner(shopX, 6); ledge(shopX)

-- LEFT: the stock list (one column).
local shopList = Instance.new("ScrollingFrame")
shopList.Position = UDim2.fromOffset(14, 54); shopList.Size = UDim2.fromOffset(300, 500 - 54 - 14)
shopList.BackgroundTransparency = 1; shopList.BorderSizePixel = 0; shopList.ScrollBarThickness = 6
shopList.CanvasSize = UDim2.new(); shopList.AutomaticCanvasSize = Enum.AutomaticSize.Y; shopList.Parent = shopPanel
local shopListLayout = Instance.new("UIListLayout")
shopListLayout.Padding = UDim.new(0, 8); shopListLayout.SortOrder = Enum.SortOrder.LayoutOrder; shopListLayout.Parent = shopList

-- RIGHT: the featured pane.
local shopDetail = Instance.new("Frame")
shopDetail.AnchorPoint = Vector2.new(1, 0); shopDetail.Position = UDim2.new(1, -14, 0, 54)
shopDetail.Size = UDim2.fromOffset(780 - 300 - 14 * 2 - 10, 500 - 54 - 14)
shopDetail.BackgroundColor3 = PANEL2; shopDetail.BorderSizePixel = 0; shopDetail.Parent = shopPanel
corner(shopDetail, 6); lstuds(shopDetail, 42, 0.75); ledge(shopDetail, TBLACK, 2); ledge(shopDetail, GOLD, 1, 0.55)

-- Restock flash overlay (the "new stock just landed" blink).
local shopFlash = Instance.new("Frame")
shopFlash.Size = UDim2.fromScale(1, 1); shopFlash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
shopFlash.BackgroundTransparency = 1; shopFlash.BorderSizePixel = 0; shopFlash.ZIndex = 20; shopFlash.Parent = shopPanel
corner(shopFlash, 8)
local function flashShop()
	shopFlash.BackgroundTransparency = 0.8
	TweenService:Create(shopFlash, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
end

local function shopClear(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

local renderShop -- forward decl

-- One stock row: rarity edge, name, price (slash on the deal), stock chip. Click = feature it.
local function shopRow(i, slot)
	local col = rarityColor(slot.caseId)
	local soldOut = (slot.left or 0) < 1
	local isSel = (shopSelected == i)
	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, -6, 0, 58); row.BackgroundColor3 = soldOut and darker(PANEL2, 0.25) or col:Lerp(BLACK, 0.68)
	row.AutoButtonColor = true; row.Text = ""; row.BorderSizePixel = 0; row.LayoutOrder = i; row.Parent = shopList
	corner(row, 6); ledge(row, isSel and GOLD or TBLACK, 2)
	local edge = Instance.new("Frame")
	edge.Size = UDim2.new(0, 4, 1, 0); edge.BackgroundColor3 = soldOut and LINE or col; edge.BorderSizePixel = 0; edge.Parent = row
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(14, 7); nm.Size = UDim2.new(1, -80, 0, 20); nm.BackgroundTransparency = 1
	nm.FontFace = BODYB_FACE; nm.TextSize = 13; nm.TextXAlignment = Enum.TextXAlignment.Left
	nm.TextColor3 = soldOut and DIMTEXT or TEXTCOL; nm.Text = slot.name or "Case"; nm.Parent = row
	local price = Instance.new("TextLabel")
	price.Position = UDim2.fromOffset(14, 30); price.Size = UDim2.new(1, -80, 0, 18); price.BackgroundTransparency = 1
	price.FontFace = BODYB_FACE; price.TextSize = 12; price.TextXAlignment = Enum.TextXAlignment.Left
	price.TextColor3 = soldOut and DIMTEXT or GOLD
	if slot.basePrice and slot.basePrice ~= slot.price then
		price.RichText = true
		price.Text = ('<font color="#8a8f7c"><s>%s</s></font>  🪙 %s'):format(fmt(slot.basePrice), fmt(slot.price or 0))
	else
		price.Text = "🪙 " .. fmt(slot.price or 0)
	end
	price.Parent = row
	local chip = Instance.new("TextLabel")
	chip.AnchorPoint = Vector2.new(1, 0.5); chip.Position = UDim2.new(1, -10, 0.5, 0); chip.Size = UDim2.fromOffset(52, 20)
	chip.BackgroundColor3 = soldOut and TRACK or darker(col, 0.7); chip.BorderSizePixel = 0
	chip.FontFace = BODYB_FACE; chip.TextSize = 10
	chip.TextColor3 = soldOut and DIMTEXT or col
	chip.Text = soldOut and "OUT" or (slot.left .. " LEFT"); chip.Parent = row
	corner(chip, 4)
	if slot.dealPct then
		local badge = Instance.new("TextLabel")
		badge.AnchorPoint = Vector2.new(1, 0); badge.Position = UDim2.new(1, -8, 0, -6); badge.Size = UDim2.fromOffset(44, 16)
		badge.BackgroundColor3 = GOLD; badge.BorderSizePixel = 0; badge.ZIndex = 3
		badge.FontFace = TITLE_FACE; badge.TextSize = 10; badge.TextColor3 = Color3.fromRGB(34, 24, 6)
		badge.Text = ("-%d%%"):format(slot.dealPct); badge.Parent = row
		corner(badge, 4)
	end
	row.Activated:Connect(function()
		shopSelected = i
		renderShop()
	end)
end

-- The featured pane: preview well (PHOTO SLOT — set catalog image ids later and they show here), odds,
-- price, stock, and the two buy buttons.
local function renderShopDetail()
	shopClear(shopDetail)
	if not shopData or not shopSelected then
		return
	end
	local slot = shopData.slots[shopSelected]
	if not slot then
		return
	end
	local col = rarityColor(slot.caseId)
	local soldOut = (slot.left or 0) < 1
	local afford = (shopData.coins or 0) >= (slot.price or 0)

	-- Preview well: shows the case PHOTO when a catalog image id exists (future: model shots), else a
	-- rarity-tinted plate with the stencil name — the layout is already built for the photos.
	local well = Instance.new("Frame")
	well.Position = UDim2.fromOffset(14, 14); well.Size = UDim2.new(1, -28, 0, 120)
	well.BackgroundColor3 = col:Lerp(BLACK, 0.7); well.BorderSizePixel = 0; well.Parent = shopDetail
	corner(well, 6); ledge(well, TBLACK, 2)
	local caseInfo = invData and invData.catalog.cases[slot.caseId]
	local imageId = caseInfo and caseInfo.image
	if typeof(imageId) == "string" and imageId ~= "" then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1; img.Size = UDim2.fromScale(1, 1)
		img.Image = imageId; img.ScaleType = Enum.ScaleType.Fit; img.Parent = well
	else
		local plate = Instance.new("TextLabel")
		plate.Size = UDim2.fromScale(1, 1); plate.BackgroundTransparency = 1
		plate.FontFace = TITLE_FACE; plate.TextSize = 26; plate.TextColor3 = col
		plate.Text = "CASE"; plate.Parent = well
	end
	if slot.dealPct then
		local badge = Instance.new("TextLabel")
		badge.AnchorPoint = Vector2.new(1, 0); badge.Position = UDim2.new(1, -8, 0, 8); badge.Size = UDim2.fromOffset(72, 24)
		badge.BackgroundColor3 = GOLD; badge.BorderSizePixel = 0; badge.ZIndex = 3
		badge.FontFace = TITLE_FACE; badge.TextSize = 14; badge.TextColor3 = Color3.fromRGB(34, 24, 6)
		badge.Text = ("-%d%%"):format(slot.dealPct); badge.Parent = well
		corner(badge, 4)
	end

	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(14, 142); nm.Size = UDim2.new(1, -28, 0, 24); nm.BackgroundTransparency = 1
	nm.FontFace = TITLE_FACE; nm.TextSize = 19; nm.TextXAlignment = Enum.TextXAlignment.Left
	nm.TextColor3 = col; nm.Text = slot.name or "Case"; nm.Parent = shopDetail

	local price = Instance.new("TextLabel")
	price.Position = UDim2.fromOffset(14, 168); price.Size = UDim2.new(1, -28, 0, 22); price.BackgroundTransparency = 1
	price.FontFace = BODYB_FACE; price.TextSize = 16; price.TextXAlignment = Enum.TextXAlignment.Left
	price.TextColor3 = GOLD
	if slot.basePrice and slot.basePrice ~= slot.price then
		price.RichText = true
		price.Text = ('<font color="#8a8f7c"><s>%s</s></font>  🪙 %s'):format(fmt(slot.basePrice), fmt(slot.price or 0))
	else
		price.Text = "🪙 " .. fmt(slot.price or 0)
	end
	price.Parent = shopDetail

	local stockLbl = Instance.new("TextLabel")
	stockLbl.Position = UDim2.fromOffset(14, 192); stockLbl.Size = UDim2.new(1, -28, 0, 16); stockLbl.BackgroundTransparency = 1
	stockLbl.FontFace = BODY_FACE; stockLbl.TextSize = 11; stockLbl.TextXAlignment = Enum.TextXAlignment.Left
	stockLbl.TextColor3 = DIMTEXT
	stockLbl.Text = soldOut and "SOLD OUT — restocks next rotation" or ("%d of %d left for you"):format(slot.left or 0, slot.stock or 0)
	stockLbl.Parent = shopDetail

	-- Drop odds.
	local disp = invData and invData.catalog.cases[slot.caseId]
	local y = 214
	if disp and disp.odds then
		for _, o in disp.odds do
			local l = Instance.new("TextLabel")
			l.Position = UDim2.fromOffset(14, y); l.Size = UDim2.new(1, -28, 0, 15); l.BackgroundTransparency = 1
			l.FontFace = BODY_FACE; l.TextSize = 11; l.TextXAlignment = Enum.TextXAlignment.Left
			l.TextColor3 = rarityColor(o.rarity)
			l.Text = ("%s  %.1f%%"):format((invData.catalog.rarities[o.rarity] or {}).name or o.rarity, o.pct)
			l.Parent = shopDetail
			y += 16
		end
	end

	-- Buy buttons.
	local function buyBtn(textStr, primary)
		local b = Instance.new("TextButton")
		b.BorderSizePixel = 0; b.AutoButtonColor = true
		b.FontFace = TITLE_FACE; b.TextSize = 13; b.Parent = shopDetail
		corner(b, 5); ledge(b, TBLACK, 2)
		if soldOut or not afford then
			b.BackgroundColor3 = TRACK; b.TextColor3 = DIMTEXT; b.AutoButtonColor = false
		elseif primary then
			b.BackgroundColor3 = ACCENT; b.TextColor3 = Color3.fromRGB(14, 22, 6)
			local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(ACCENT, darker(ACCENT, 0.45)); g.Rotation = 90; g.Parent = b
		else
			b.BackgroundColor3 = PANEL2; b.TextColor3 = TEXTCOL
			ledge(b, ACCENT, 1, 0.5)
		end
		b.Text = textStr
		return b
	end
	local buy = buyBtn(soldOut and "SOLD OUT" or "BUY", true)
	buy.AnchorPoint = Vector2.new(0, 1); buy.Position = UDim2.new(0, 14, 1, -12); buy.Size = UDim2.new(0.5, -20, 0, 42)
	local buyOpen = buyBtn(soldOut and "—" or "BUY & OPEN", false)
	buyOpen.AnchorPoint = Vector2.new(1, 1); buyOpen.Position = UDim2.new(1, -14, 1, -12); buyOpen.Size = UDim2.new(0.5, -20, 0, 42)
	if not soldOut and afford then
		buy.Activated:Connect(function()
			ShopBuy:FireServer({ slot = shopSelected, open = false })
		end)
		buyOpen.Activated:Connect(function()
			if rolling then return end
			rolling = true
			armRollTimeout()
			ShopBuy:FireServer({ slot = shopSelected, open = true })
		end)
	end
end

renderShop = function()
	if not shopData then return end
	shopCoins.Text = "🪙 " .. fmt(shopData.coins or 0)
	shopClear(shopList)
	for i, slot in ipairs(shopData.slots) do
		shopRow(i, slot)
	end
	renderShopDetail()
end

-- Default feature = the Deal of the Rotation (else the first slot still in stock, else slot 1).
local function defaultShopSelection()
	for i, slot in ipairs(shopData.slots) do
		if slot.dealPct then return i end
	end
	for i, slot in ipairs(shopData.slots) do
		if (slot.left or 0) > 0 then return i end
	end
	return 1
end

-- Live countdown + the "RESTOCKING..." beat while we wait for the server's new-window push.
task.spawn(function()
	while true do
		task.wait(0.5)
		if shopPanel.Visible then
			local left = shopDeadline - os.clock()
			if left > 0 then
				shopRestock.Text = ("NEW STOCK IN %d:%02d"):format(math.floor(left / 60), math.floor(left) % 60)
			else
				shopRestock.Text = "RESTOCKING..."
			end
		end
	end
end)

ShopSync.OnClientEvent:Connect(function(p)
	if typeof(p) ~= "table" or typeof(p.slots) ~= "table" then return end
	local prevWindow = shopData and shopData.window
	local windowChanged = prevWindow and p.window and p.window ~= prevWindow
	shopData = p
	shopDeadline = os.clock() + (tonumber(p.endsIn) or 0)
	if windowChanged or not shopSelected or not shopData.slots[shopSelected] then
		shopSelected = defaultShopSelection()
	end
	if p.enter then
		shopPanel.Visible = true
	end
	if shopPanel.Visible then
		renderShop()
		if windowChanged then
			flashShop() -- instant swap: the rotation rolled over while browsing
		end
	end
end)

ShopClose.OnClientEvent:Connect(function()
	shopPanel.Visible = false
end)
shopX.Activated:Connect(function()
	shopPanel.Visible = false -- walk off + back on to reopen
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
		card.BackgroundColor3 = PANEL
		card.BackgroundTransparency = 0
		card.BorderSizePixel = 0
		card.Parent = gui
		corner(card, 6)
		lstuds(card); ldepth(card); ledge(card)
		local cStroke = Instance.new("UIStroke")
		cStroke.Color = isWin and ACCENT or ORANGE
		cStroke.Transparency = 0.35
		cStroke.Thickness = 1.5
		cStroke.Parent = card

		local cTitle = Instance.new("TextLabel")
		cTitle.Position = UDim2.fromOffset(0, 14)
		cTitle.Size = UDim2.new(1, 0, 0, 24)
		cTitle.BackgroundTransparency = 1
		cTitle.FontFace = TITLE_FACE
		cTitle.TextSize = 20
		cTitle.TextColor3 = isWin and ACCENT or ORANGE
		cTitle.Text = isWin and "VICTORY!" or "RUN OVER"
		cTitle.Parent = card

		local cLine = Instance.new("TextLabel")
		cLine.Position = UDim2.fromOffset(0, 44)
		cLine.Size = UDim2.new(1, 0, 0, 20)
		cLine.BackgroundTransparency = 1
		cLine.FontFace = BODYB_FACE
		cLine.TextSize = 15
		cLine.TextColor3 = TEXTCOL
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
		cHint.FontFace = BODY_FACE
		cHint.TextSize = 11
		cHint.TextColor3 = DIMTEXT
		cHint.Text = "Coins banked to your account"
		cHint.Parent = card

		local cClose = Instance.new("TextButton")
		cClose.AnchorPoint = Vector2.new(1, 0)
		cClose.Position = UDim2.new(1, -6, 0, 6)
		cClose.Size = UDim2.fromOffset(22, 22)
		cClose.BackgroundTransparency = 1
		cClose.FontFace = BODYB_FACE
		cClose.TextSize = 14
		cClose.TextColor3 = DIMTEXT
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
