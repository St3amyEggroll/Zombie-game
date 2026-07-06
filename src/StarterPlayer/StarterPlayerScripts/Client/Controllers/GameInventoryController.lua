--!nonstrict
-- GameInventoryController.lua — the IN-GAME inventory: top tab strip (POTIONS / WEAPONS / CASES) over a
-- full-width card grid. Clicking a card slides in a DETAIL PANE on the right (40%) with the big info +
-- the action (USE for potions; weapons/cases are managed in the lobby). Click the card again — or the
-- pane's ✕ — and the grid takes the full width back.
-- Data comes from GameInventoryService via InvSnapshot; drop toasts ride PotionDropped/CaseDropped.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Remotes = require(Modules.Remotes)
local UITheme = require(Modules.UITheme)
local GunViewport = require(Modules.GunViewport)

local GameInventoryController = {}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ===== LAYOUT TUNABLES =====
local PANEL_W, PANEL_H = 780, 500
local DETAIL_W = 280 -- the click-to-reveal hero pane (≈40%)

local data = nil
local activeTab = "potions" -- potions FIRST: the one tab you can interact with in-run
local selected = nil        -- { kind = "potion"|"weapon"|"case", id = string } — drives the detail pane

local function rarityColor(rarityId)
	local r = data and data.catalog.rarities[rarityId]
	return (r and r.color) or Color3.fromRGB(160, 160, 170)
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "GameInventory"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 8
gui.Parent = playerGui
UITheme.Attach(gui)

-- Drop toast (potion/case pickups).
local toast = Instance.new("TextLabel")
toast.AnchorPoint = Vector2.new(0.5, 0); toast.Position = UDim2.new(0.5, 0, 0, 70); toast.Size = UDim2.fromOffset(340, 40)
toast.BackgroundColor3 = UITheme.PANEL; toast.BackgroundTransparency = 0.02; toast.BorderSizePixel = 0
toast.FontFace = UITheme.BodyBoldFace; toast.TextSize = 15; toast.TextColor3 = UITheme.GOLD
toast.Text = ""; toast.Visible = false; toast.Parent = gui
UITheme.Corner(toast, 6); UITheme.Edge(toast)

local toastToken = 0
local function showToast(text, color)
	toast.Text = text
	toast.TextColor3 = color or UITheme.GOLD
	toast.Visible = true
	toastToken += 1
	local myToken = toastToken
	task.delay(3, function()
		if toastToken == myToken then
			toast.Visible = false
		end
	end)
end

local panel = UITheme.Panel(gui, "InventoryPanel", { radius = 8, accent = UITheme.TOXIC, edgeThickness = 3 })
panel.AnchorPoint = Vector2.new(0.5, 0.5); panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H); panel.Visible = false

UITheme.Header(panel, "Inventory", 46)

-- Big naked red X (no button plate) — the game's close-anything glyph.
local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0); closeBtn.Position = UDim2.new(1, -6, 0, 2); closeBtn.Size = UDim2.fromOffset(46, 46)
closeBtn.BackgroundTransparency = 1; closeBtn.FontFace = UITheme.TitleFace; closeBtn.TextSize = 32
closeBtn.TextColor3 = Color3.fromRGB(235, 55, 45); closeBtn.Text = "✕"; closeBtn.Parent = panel
local cbStroke = Instance.new("UIStroke")
cbStroke.Color = UITheme.BLACK; cbStroke.Thickness = 1.6; cbStroke.Parent = closeBtn

-- Top tab strip: three wide tabs with a toxic underline on the active one.
local tabs = Instance.new("Frame")
tabs.Position = UDim2.fromOffset(14, 54); tabs.Size = UDim2.new(1, -28, 0, 38); tabs.BackgroundTransparency = 1; tabs.Parent = panel
local tabList = Instance.new("UIListLayout")
tabList.FillDirection = Enum.FillDirection.Horizontal; tabList.Padding = UDim.new(0, 8); tabList.Parent = tabs
local tabBtns = {}
local function tabButton(id, textStr)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(150, 38); b.BackgroundColor3 = UITheme.PANEL2; b.BorderSizePixel = 0
	b.FontFace = UITheme.TitleFace; b.TextSize = 15; b.TextColor3 = UITheme.DIM; b.Text = textStr; b.Parent = tabs
	UITheme.Corner(b, 5); UITheme.Edge(b, UITheme.BLACK, 2)
	local under = Instance.new("Frame")
	under.Name = "Under"
	under.AnchorPoint = Vector2.new(0.5, 1); under.Position = UDim2.new(0.5, 0, 1, -3)
	under.Size = UDim2.new(1, -16, 0, 3); under.BackgroundColor3 = UITheme.TOXIC; under.BorderSizePixel = 0
	under.Visible = false; under.Parent = b
	tabBtns[id] = b
	return b
end
tabButton("potions", "POTIONS")
tabButton("weapons", "WEAPONS")
tabButton("cases", "CASES")

-- Grid (full width; shrinks when the detail pane is open) + the detail pane itself.
local CONTENT_Y = 100
local grid = Instance.new("ScrollingFrame")
grid.Position = UDim2.fromOffset(14, CONTENT_Y); grid.Size = UDim2.new(1, -28, 1, -(CONTENT_Y + 14))
grid.BackgroundTransparency = 1; grid.BorderSizePixel = 0; grid.ScrollBarThickness = 6
grid.CanvasSize = UDim2.new(); grid.AutomaticCanvasSize = Enum.AutomaticSize.Y; grid.Parent = panel
local gridLayout = Instance.new("UIGridLayout")
gridLayout.CellSize = UDim2.fromOffset(112, 104); gridLayout.CellPadding = UDim2.fromOffset(10, 10); gridLayout.Parent = grid

local detail = UITheme.Panel(panel, "Detail", { color = UITheme.PANEL2, radius = 6, studsAlpha = 0.75 })
detail.AnchorPoint = Vector2.new(1, 0)
detail.Position = UDim2.new(1, -14, 0, CONTENT_Y)
detail.Size = UDim2.fromOffset(DETAIL_W, PANEL_H - CONTENT_Y - 14)
detail.Visible = false

local function layoutContent()
	if selected then
		grid.Size = UDim2.new(1, -(28 + DETAIL_W + 10), 1, -(CONTENT_Y + 14))
		detail.Visible = true
	else
		grid.Size = UDim2.new(1, -28, 1, -(CONTENT_Y + 14))
		detail.Visible = false
	end
end

-- ===== LIVE POTION-BUFF STATE =====
local activeUntil = {} -- [potionId] = os.clock() when that potion's own buff ends
local function idActive(potId)
	return potId and activeUntil[potId] ~= nil and activeUntil[potId] > os.clock()
end

-- ===== CARDS =====
local function clearChildren(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

local render -- forward decl

local function select(kind, id)
	if selected and selected.kind == kind and selected.id == id then
		selected = nil -- clicking the selected card closes the pane
	else
		selected = { kind = kind, id = id }
	end
	render()
end

-- A compact square card: rarity bar, name, corner count/level chip. Click = select.
local function card(parent, opts)
	local col = opts.color
	local isSel = selected and selected.kind == opts.kind and selected.id == opts.id
	local f = Instance.new("TextButton")
	f.BackgroundColor3 = col:Lerp(UITheme.BG, 0.62); f.AutoButtonColor = true; f.Text = ""
	f.BorderSizePixel = 0; f.LayoutOrder = opts.order or 0; f.Parent = parent
	UITheme.Corner(f, 6)
	UITheme.Edge(f, isSel and UITheme.TOXIC or UITheme.BLACK, 2)
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 4); bar.BackgroundColor3 = col; bar.BorderSizePixel = 0; bar.Parent = f
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(6, 14); nm.Size = UDim2.new(1, -12, 0, 40); nm.BackgroundTransparency = 1
	nm.FontFace = UITheme.BodyBoldFace; nm.TextSize = 12; nm.TextWrapped = true
	nm.TextColor3 = UITheme.TEXT; nm.Text = opts.name; nm.Parent = f
	local nmStroke = Instance.new("UIStroke") -- keeps the name readable over the art
	nmStroke.Color = UITheme.BLACK; nmStroke.Thickness = 1.4; nmStroke.Parent = nm
	-- 3D SLOT: the spinning model IS the card art — fills the whole card, text floats above (ZIndex 0).
	-- Weapons pull from GunDisplay; cases from CrateDisplay (Assets models named "<Rarity>Crate").
	local showedModel = false
	if opts.kind == "weapon" or opts.kind == "case" then
		local vp = GunViewport.Create(opts.id, true, opts.kind == "case" and "CrateDisplay" or nil)
		if vp then
			vp.ZIndex = 0
			vp.Position = UDim2.new(0, 0, 0, 0); vp.Size = UDim2.new(1, 0, 1, 0)
			vp.Parent = f
			showedModel = true
		end
	end
	-- PHOTO SLOT: full-card photo when there's no model.
	if not showedModel and typeof(opts.image) == "string" and opts.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.ZIndex = 0
		img.Position = UDim2.new(0, 0, 0, 0); img.Size = UDim2.new(1, 0, 1, 0)
		img.BackgroundTransparency = 1
		img.Image = opts.image; img.ScaleType = Enum.ScaleType.Fit; img.Parent = f
	end
	if opts.chip then
		local chip = Instance.new("TextLabel")
		chip.AnchorPoint = Vector2.new(1, 1); chip.Position = UDim2.new(1, -6, 1, -6)
		chip.Size = UDim2.fromOffset(44, 16); chip.BackgroundColor3 = UITheme.Darker(col, 0.7); chip.BorderSizePixel = 0
		chip.FontFace = UITheme.BodyBoldFace; chip.TextSize = 10; chip.TextColor3 = col; chip.Text = opts.chip; chip.Parent = f
		UITheme.Corner(chip, 3)
	end
	if opts.tag then -- e.g. EQUIPPED
		local tag = Instance.new("TextLabel")
		tag.Position = UDim2.fromOffset(6, 58); tag.Size = UDim2.new(1, -12, 0, 14); tag.BackgroundTransparency = 1
		tag.FontFace = UITheme.TitleFace; tag.TextSize = 10; tag.TextXAlignment = Enum.TextXAlignment.Left
		tag.TextColor3 = UITheme.TOXIC; tag.Text = opts.tag; tag.Parent = f
	end
	f.Activated:Connect(function()
		select(opts.kind, opts.id)
	end)
	return f
end

local function emptyNote(textStr)
	local msg = Instance.new("TextLabel")
	msg.Size = UDim2.fromOffset(480, 40); msg.BackgroundTransparency = 1; msg.FontFace = UITheme.BodyBoldFace
	msg.TextSize = 14; msg.TextColor3 = UITheme.DIM
	msg.Text = textStr; msg.Parent = grid
end

-- ===== DETAIL PANE =====
local function renderDetail()
	clearChildren(detail)
	if not selected or not data then
		return
	end
	local kind, id = selected.kind, selected.id

	local dClose = Instance.new("TextButton")
	dClose.AnchorPoint = Vector2.new(1, 0); dClose.Position = UDim2.new(1, -4, 0, 2); dClose.Size = UDim2.fromOffset(36, 36)
	dClose.BackgroundTransparency = 1; dClose.FontFace = UITheme.TitleFace; dClose.TextSize = 24
	dClose.TextColor3 = Color3.fromRGB(235, 55, 45); dClose.Text = "✕"; dClose.Parent = detail
	dClose.Activated:Connect(function()
		selected = nil
		render()
	end)

	-- Spinning 3D hero for weapons + cases: fills the whole pane as a backdrop, info floats above it.
	if kind == "weapon" or kind == "case" then
		local vp = GunViewport.Create(id, true, kind == "case" and "CrateDisplay" or nil)
		if vp then
			vp.ZIndex = 0
			vp.Position = UDim2.new(0, 0, 0, 0)
			vp.Size = UDim2.new(1, 0, 1, 0)
			vp.ImageTransparency = 0.1
			vp.Parent = detail
		end
	end

	local function bigTitle(textStr, col)
		local t = Instance.new("TextLabel")
		t.Position = UDim2.fromOffset(14, 14); t.Size = UDim2.new(1, -44, 0, 44); t.BackgroundTransparency = 1
		t.FontFace = UITheme.TitleFace; t.TextSize = 19; t.TextWrapped = true
		t.TextXAlignment = Enum.TextXAlignment.Left; t.TextColor3 = col or UITheme.TEXT; t.Text = textStr; t.Parent = detail
		return t
	end
	local function line(y, textStr, col, size)
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromOffset(14, y); l.Size = UDim2.new(1, -28, 0, 40); l.BackgroundTransparency = 1
		l.FontFace = UITheme.BodyFace; l.TextSize = size or 12; l.TextWrapped = true
		l.TextXAlignment = Enum.TextXAlignment.Left; l.TextYAlignment = Enum.TextYAlignment.Top
		l.TextColor3 = col or UITheme.TEXT; l.Text = textStr; l.Parent = detail
		return l
	end

	if kind == "potion" then
		local disp = data.catalog.potions[id]
		if not disp then return end
		local col = rarityColor(disp.rarity)
		bigTitle(disp.name, col)
		line(62, disp.desc or "", UITheme.TEXT, 13)
		line(108, ("You have: x%d"):format(data.potions[id] or 0), UITheme.DIM)
		line(134, "Same potion again = EXTENDS its timer.\nOther tiers stack on top.", UITheme.DIM, 11)
		local use = UITheme.Button(detail, idActive(id) and "EXTEND" or "USE", "primary")
		use.AnchorPoint = Vector2.new(0.5, 1); use.Position = UDim2.new(0.5, 0, 1, -12); use.Size = UDim2.new(1, -28, 0, 40)
		use.Activated:Connect(function()
			Remotes.Get("ConsumePotion"):FireServer(id)
		end)
	elseif kind == "weapon" then
		local w = data.catalog.weapons[id]
		if not w then return end
		local col = rarityColor(w.rarity)
		local lv = (data.gunLevels or {})[id] or 1
		bigTitle(w.name, col)
		line(62, ((data.catalog.rarities[w.rarity] or {}).name or "") .. "  ·  LV " .. lv, col, 13)
		line(88, ("Damage %s%s\nFire rate %s/s\nRange %s"):format(
			tostring(w.damage or "?"), w.pellets and (" ×" .. w.pellets) or "",
			tostring(w.fireRate or "?"), tostring(w.range or "?")), UITheme.TEXT, 12)
		local inLoadout = (id == data.loadout[1]) or (id == data.loadout[2])
		if inLoadout then
			line(150, "EQUIPPED", UITheme.TOXIC, 13)
		end
		local note = UITheme.Button(detail, "EQUIP + UPGRADE IN LOBBY", "ghost")
		note.AnchorPoint = Vector2.new(0.5, 1); note.Position = UDim2.new(0.5, 0, 1, -12); note.Size = UDim2.new(1, -28, 0, 36)
		note.AutoButtonColor = false
		note.TextSize = 11
	elseif kind == "case" then
		local disp = data.catalog.cases[id]
		if not disp then return end
		local col = rarityColor(id)
		bigTitle(disp.name, col)
		line(62, ("You have: x%d"):format(data.cases[id] or 0), UITheme.TEXT, 13)
		line(90, "Cases hold GUN COPIES — stack copies to\nlevel your guns up.", UITheme.DIM, 11)
		local note = UITheme.Button(detail, "OPEN IN THE LOBBY", "ghost")
		note.AnchorPoint = Vector2.new(0.5, 1); note.Position = UDim2.new(0.5, 0, 1, -12); note.Size = UDim2.new(1, -28, 0, 36)
		note.AutoButtonColor = false
		note.TextSize = 11
	end
end

-- ===== GRID RENDERS =====
local function renderPotions()
	local any = false
	local order = 0
	for _, rarity in data.catalog.rarityOrder do
		for _, ptype in { "damage", "regen" } do
			local potId = ptype .. "_" .. rarity
			local disp = data.catalog.potions[potId]
			local count = disp and (data.potions[potId] or 0) or 0
			if disp and count > 0 then
				any = true
				order += 1
				card(grid, {
					kind = "potion", id = potId, name = disp.name, color = rarityColor(disp.rarity),
					chip = "x" .. count, order = order,
					tag = idActive(potId) and "ACTIVE" or nil, image = disp.image,
				})
			end
		end
	end
	if not any then
		emptyNote("No potions yet — kill glowing ELITE zombies to earn them.")
	end
end

local function renderWeapons()
	local order = 0
	for _, id in data.owned do
		local w = data.catalog.weapons[id]
		if w then
			order += 1
			local inLoadout = (id == data.loadout[1]) or (id == data.loadout[2])
			card(grid, {
				kind = "weapon", id = id, name = w.name, color = rarityColor(w.rarity),
				chip = "LV " .. ((data.gunLevels or {})[id] or 1), order = order,
				tag = inLoadout and "EQUIPPED" or nil, image = w.image,
			})
		end
	end
end

local function renderCases()
	local any = false
	local order = 0
	for _, rarity in data.catalog.rarityOrder do
		local disp = data.catalog.cases[rarity]
		local count = data.cases[rarity] or 0
		if disp and count > 0 then
			any = true
			order += 1
			card(grid, { kind = "case", id = rarity, name = disp.name, color = rarityColor(rarity), chip = "x" .. count, order = order, image = disp.image })
		end
	end
	if not any then
		emptyNote("No cases yet — kill BOSSES (every 10th wave) to earn them!")
	end
end

-- ===== RENDER =====
render = function()
	if not data then return end
	for id, b in tabBtns do
		local on = (id == activeTab)
		b.TextColor3 = on and UITheme.TEXT or UITheme.DIM
		b.Under.Visible = on
	end
	clearChildren(grid)
	layoutContent()
	if activeTab == "potions" then renderPotions()
	elseif activeTab == "weapons" then renderWeapons()
	else renderCases() end
	renderDetail()
end

for id, b in tabBtns do
	b.Activated:Connect(function()
		activeTab = id
		selected = nil -- switching tabs closes the pane
		render()
	end)
end

closeBtn.Activated:Connect(function()
	panel.Visible = false
end)

-- Is the inventory panel currently open? (CrosshairController frees the mouse while any UI is up.)
function GameInventoryController.IsOpen(): boolean
	return panel.Visible
end

-- Open/close the panel (called by the hotbar's ITEMS button). Always lands on the Potions tab.
function GameInventoryController.Toggle()
	Remotes.Get("InvSnapshot"):FireServer() -- request a fresh snapshot
	activeTab = "potions"
	selected = nil
	panel.Visible = not panel.Visible
	if panel.Visible then
		render()
	end
end

-- ===== LIFECYCLE =====
function GameInventoryController.Start()
	Remotes.Get("InvSnapshot").OnClientEvent:Connect(function(snap)
		if typeof(snap) == "table" then
			data = snap
			-- Seed the active-buff clocks from the snapshot (PotionBuffsChanged keeps them exact after).
			activeUntil = {}
			if typeof(snap.active) == "table" then
				for potId, remaining in snap.active do
					activeUntil[potId] = os.clock() + (tonumber(remaining) or 0)
				end
			end
			if panel.Visible then render() end
		end
	end)
	-- Live buff pushes: re-render so USE/EXTEND and the ACTIVE tags flip the moment a buff starts or ends.
	Remotes.Get("PotionBuffsChanged").OnClientEvent:Connect(function(list)
		activeUntil = {}
		if typeof(list) == "table" then
			for _, b in list do
				if typeof(b) == "table" and b.id then
					activeUntil[b.id] = os.clock() + (tonumber(b.remaining) or 0)
				end
			end
		end
		if panel.Visible and activeTab == "potions" and data then
			render()
		end
	end)
	Remotes.Get("PotionDropped").OnClientEvent:Connect(function(potionId)
		local disp = data and data.catalog.potions[potionId]
		showToast("Elite drop: " .. (disp and disp.name or "a potion") .. "!", disp and rarityColor(disp.rarity) or nil)
	end)
	Remotes.Get("CaseDropped").OnClientEvent:Connect(function(rarity)
		local disp = data and data.catalog.cases[rarity]
		showToast("Boss reward: " .. (disp and disp.name or "a case") .. "!", rarityColor(rarity))
	end)
	Remotes.Get("InvSnapshot"):FireServer() -- ask for our snapshot on start
	print("[GameInventoryController] started (tabbed inventory + detail pane)")
end

return GameInventoryController
