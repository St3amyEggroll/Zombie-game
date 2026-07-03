--!nonstrict
-- GameInventoryController.lua — the IN-GAME inventory window, mirroring the LOBBY inventory's look:
-- left nav (Potions / Weapons / Cases), card grids with rarity color bars. Differences from the lobby:
--   * opens on the POTIONS tab — the only interactive one here (drink potions for TIMED buffs; the same
--     potion extends its timer, different tiers stack)
--   * Weapons shows your 2 equip slots + all owned guns, VIEW-ONLY (equip back in the lobby)
--   * Cases shows your case counts by rarity, VIEW-ONLY (open them back in the lobby)
-- Data comes from GameInventoryService via InvSnapshot; drop toasts ride PotionDropped/CaseDropped.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local GameInventoryController = {}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ===== STYLE (shared design system) =====
local ACCENT = Color3.fromRGB(87, 196, 116)
local CARD = Color3.fromRGB(31, 34, 42)
local DIM = Color3.fromRGB(64, 68, 80)
local BLACK = Color3.fromRGB(12, 13, 18)
local TEXT = Color3.fromRGB(238, 240, 245)
local TEXT_DIM = Color3.fromRGB(150, 156, 168)

local data = nil
local activeTab = "potions" -- potions FIRST: the one tab you can interact with in-run

local function corner(o, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = o
end

local function rarityColor(rarityId)
	local r = data and data.catalog.rarities[rarityId]
	return (r and r.color) or Color3.fromRGB(160, 160, 170)
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "GameInventory"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 8
gui.Parent = playerGui

-- (Opened via the INVENTORY button on the hotbar — HotbarController calls GameInventoryController.Toggle().)

-- Drop toast (potion/case pickups).
local toast = Instance.new("TextLabel")
toast.AnchorPoint = Vector2.new(0.5, 0); toast.Position = UDim2.new(0.5, 0, 0, 70); toast.Size = UDim2.fromOffset(340, 40)
toast.BackgroundColor3 = Color3.fromRGB(22, 24, 30); toast.BackgroundTransparency = 0.05; toast.BorderSizePixel = 0
toast.Font = Enum.Font.GothamBold; toast.TextSize = 16; toast.TextColor3 = Color3.fromRGB(235, 190, 85)
toast.Text = ""; toast.Visible = false; toast.Parent = gui; corner(toast, 8)

local toastToken = 0
local function showToast(text, color)
	toast.Text = text
	toast.TextColor3 = color or Color3.fromRGB(235, 190, 85)
	toast.Visible = true
	toastToken += 1
	local myToken = toastToken
	task.delay(3, function()
		if toastToken == myToken then
			toast.Visible = false
		end
	end)
end

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5); panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(760, 480); panel.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
panel.BackgroundTransparency = 0.03; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 16)
local pStroke = Instance.new("UIStroke"); pStroke.Color = ACCENT; pStroke.Thickness = 2; pStroke.Transparency = 0.5; pStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 12); title.Size = UDim2.new(1, 0, 0, 30); title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack; title.TextSize = 22; title.TextColor3 = TEXT
title.Text = "INVENTORY"; title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0); closeBtn.Position = UDim2.new(1, -12, 0, 12); closeBtn.Size = UDim2.fromOffset(32, 32)
closeBtn.BackgroundColor3 = Color3.fromRGB(224, 82, 82); closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 16
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255); closeBtn.Text = "✕"; closeBtn.Parent = panel; corner(closeBtn, 8)

local nav = Instance.new("Frame")
nav.Position = UDim2.fromOffset(16, 52); nav.Size = UDim2.fromOffset(150, 400); nav.BackgroundTransparency = 1; nav.Parent = panel
local navList = Instance.new("UIListLayout"); navList.Padding = UDim.new(0, 8); navList.Parent = nav
local navBtns = {}
local function navButton(id, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 44); b.BackgroundColor3 = CARD; b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold; b.TextSize = 16; b.TextColor3 = TEXT; b.Text = text; b.Parent = nav
	corner(b, 8); navBtns[id] = b
	return b
end
navButton("potions", "Potions")
navButton("weapons", "Weapons")
navButton("cases", "Cases")

local hint = Instance.new("TextLabel")
hint.AnchorPoint = Vector2.new(0.5, 1); hint.Position = UDim2.new(0.5, 78, 1, -8); hint.Size = UDim2.fromOffset(520, 18)
hint.BackgroundTransparency = 1; hint.Font = Enum.Font.Gotham; hint.TextSize = 12; hint.TextColor3 = TEXT_DIM
hint.Text = "Equip guns & open cases in the LOBBY. Potions are usable here."; hint.Parent = panel

local content = Instance.new("Frame")
content.Position = UDim2.fromOffset(178, 52); content.Size = UDim2.fromOffset(566, 400)
content.BackgroundColor3 = Color3.fromRGB(17, 19, 24); content.BackgroundTransparency = 0.2; content.BorderSizePixel = 0
content.Parent = panel; corner(content, 12)

local potionsTab = Instance.new("Frame")
potionsTab.Size = UDim2.fromScale(1, 1); potionsTab.BackgroundTransparency = 1; potionsTab.Parent = content
local weaponsTab = Instance.new("Frame")
weaponsTab.Size = UDim2.fromScale(1, 1); weaponsTab.BackgroundTransparency = 1; weaponsTab.Visible = false; weaponsTab.Parent = content
local casesTab = Instance.new("Frame")
casesTab.Size = UDim2.fromScale(1, 1); casesTab.BackgroundTransparency = 1; casesTab.Visible = false; casesTab.Parent = content

local function tabHint(parent, text)
	local l = Instance.new("TextLabel")
	l.Position = UDim2.fromOffset(14, 10); l.Size = UDim2.new(1, -28, 0, 18); l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold; l.TextSize = 13; l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Color3.fromRGB(170, 180, 195); l.Text = text; l.Parent = parent
	return l
end

local function tabScroll(parent, y, cellW, cellH)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(14, y); scroll.Size = UDim2.new(1, -28, 1, -(y + 12))
	scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0; scroll.ScrollBarThickness = 6
	scroll.CanvasSize = UDim2.new(); scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; scroll.Parent = parent
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(cellW, cellH); grid.CellPadding = UDim2.fromOffset(10, 10); grid.Parent = scroll
	return scroll
end

local function clearScroll(scroll)
	for _, c in scroll:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

-- Rarity-bar card (same look as the lobby's weapon cards).
local function card(parent, name, subtitle, color, highlight)
	local f = Instance.new("TextButton")
	f.BackgroundColor3 = color:Lerp(BLACK, 0.55); f.AutoButtonColor = false; f.Text = ""
	f.BorderSizePixel = 0; f.Parent = parent
	corner(f, 8)
	local st = Instance.new("UIStroke"); st.Color = highlight and ACCENT or color
	st.Thickness = highlight and 2.5 or 1.2; st.Transparency = highlight and 0 or 0.35; st.Parent = f
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 4); bar.BackgroundColor3 = color; bar.BorderSizePixel = 0; bar.Parent = f
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(4, 22); nm.Size = UDim2.new(1, -8, 0, 24); nm.BackgroundTransparency = 1
	nm.Font = Enum.Font.GothamBold; nm.TextSize = 14; nm.TextColor3 = TEXT; nm.Text = name; nm.TextScaled = true; nm.Parent = f
	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(4, 52); sub.Size = UDim2.new(1, -8, 0, 16); sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Gotham; sub.TextSize = 12; sub.TextColor3 = color; sub.Text = subtitle or ""; sub.TextScaled = true; sub.Parent = f
	return f
end

-- ---------- POTIONS TAB (interactive) ----------
tabHint(potionsTab, "POTIONS — timed buffs that STACK: same potion extends its timer, tiers add together.")
local potionsScroll = tabScroll(potionsTab, 36, 160, 152)

-- Live "active buff" state: seeded by the snapshot, kept exact by PotionBuffsChanged pushes.
local activeUntil = {} -- [potionId] = os.clock() when that potion's own buff ends

local function idActive(potId)
	return potId and activeUntil[potId] ~= nil and activeUntil[potId] > os.clock()
end

local function renderPotions()
	clearScroll(potionsScroll)
	local any = false
	-- Rarity-major order (common → divine), damage before regen inside each tier.
	for _, rarity in data.catalog.rarityOrder do
		for _, ptype in { "damage", "regen" } do
			local potId = ptype .. "_" .. rarity
			local disp = data.catalog.potions[potId]
			local count = disp and (data.potions[potId] or 0) or 0
			if disp and count > 0 then
				any = true
				local col = rarityColor(disp.rarity)
				local f = card(potionsScroll, disp.name, "x" .. count, col, false)
				-- The effect line — what this potion actually gives you.
				local desc = Instance.new("TextLabel")
				desc.Position = UDim2.fromOffset(6, 72); desc.Size = UDim2.new(1, -12, 0, 30); desc.BackgroundTransparency = 1
				desc.Font = Enum.Font.Gotham; desc.TextSize = 12; desc.TextColor3 = Color3.fromRGB(190, 195, 210)
				desc.Text = disp.desc or ""; desc.TextWrapped = true; desc.Parent = f
				local use = Instance.new("TextButton")
				use.AnchorPoint = Vector2.new(0.5, 1); use.Position = UDim2.new(0.5, 0, 1, -8); use.Size = UDim2.new(1, -20, 0, 32)
				use.Font = Enum.Font.GothamBold; use.TextSize = 14; use.BorderSizePixel = 0; use.Parent = f; corner(use, 8)
				-- Always drinkable: a running one EXTENDS its own timer, other tiers stack on top.
				use.BackgroundColor3 = ACCENT; use.TextColor3 = Color3.fromRGB(15, 25, 15)
				use.Text = idActive(potId) and "EXTEND" or "USE"
				use.Activated:Connect(function()
					Remotes.Get("ConsumePotion"):FireServer(potId)
				end)
			end
		end
	end
	if not any then
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.fromOffset(520, 40); msg.BackgroundTransparency = 1; msg.Font = Enum.Font.GothamBold
		msg.TextSize = 15; msg.TextColor3 = TEXT_DIM
		msg.Text = "No potions yet — kill glowing ELITE zombies to earn them."; msg.Parent = potionsScroll
	end
end

-- ---------- WEAPONS TAB (view-only: 2 equip slots on top + owned guns below) ----------
tabHint(weaponsTab, "YOUR LOADOUT — change it in the lobby")
local slotsRow = Instance.new("Frame")
slotsRow.Position = UDim2.fromOffset(14, 34); slotsRow.Size = UDim2.new(1, -28, 0, 92); slotsRow.BackgroundTransparency = 1; slotsRow.Parent = weaponsTab
local slotsList = Instance.new("UIListLayout")
slotsList.FillDirection = Enum.FillDirection.Horizontal; slotsList.Padding = UDim.new(0, 10); slotsList.Parent = slotsRow
local ownedHintW = tabHint(weaponsTab, "ALL YOUR GUNS")
ownedHintW.Position = UDim2.fromOffset(14, 136)
local weaponsScroll = tabScroll(weaponsTab, 160, 122, 92)

local function weaponSub(id)
	local w = data.catalog.weapons[id]
	local r = data.catalog.rarities[w.rarity]
	local lv = (data.gunLevels or {})[id] or 1
	return ("Lv %d · %s"):format(lv, r and r.name or "")
end

local function renderWeapons()
	for _, c in slotsRow:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	clearScroll(weaponsScroll)

	for slot = 1, 2 do
		local id = data.loadout[slot]
		local w = id and data.catalog.weapons[id]
		local holder
		if w then
			holder = card(slotsRow, w.name, ("SLOT %d · Lv %d"):format(slot, (data.gunLevels or {})[id] or 1), rarityColor(w.rarity), true)
		else
			holder = card(slotsRow, "Empty", "SLOT " .. slot, Color3.fromRGB(90, 95, 108), false)
		end
		holder.Size = UDim2.fromOffset(150, 92)
		holder.LayoutOrder = slot
	end

	for _, id in data.owned do
		local w = data.catalog.weapons[id]
		if w then
			local inLoadout = (id == data.loadout[1]) or (id == data.loadout[2])
			card(weaponsScroll, w.name, inLoadout and "EQUIPPED" or weaponSub(id), rarityColor(w.rarity), inLoadout)
		end
	end
end

-- ---------- CASES TAB (view-only) ----------
tabHint(casesTab, "YOUR CASES — open them in the lobby. A case drops for everyone every 10 waves!")
local casesScroll = tabScroll(casesTab, 36, 160, 110)

local function renderCases()
	clearScroll(casesScroll)
	local any = false
	for _, rarity in data.catalog.rarityOrder do
		local disp = data.catalog.cases[rarity]
		local count = data.cases[rarity] or 0
		if disp and count > 0 then
			any = true
			card(casesScroll, disp.name, "x" .. count, rarityColor(rarity), false)
		end
	end
	if not any then
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.fromOffset(520, 40); msg.BackgroundTransparency = 1; msg.Font = Enum.Font.GothamBold
		msg.TextSize = 15; msg.TextColor3 = TEXT_DIM
		msg.Text = "No cases yet — clear wave 10 and beyond to earn them!"; msg.Parent = casesScroll
	end
end

-- ===== TABS =====
local function render()
	if not data then return end
	for id, b in navBtns do
		local on = (id == activeTab)
		b.BackgroundColor3 = on and ACCENT or CARD
		b.TextColor3 = on and Color3.fromRGB(15, 25, 15) or TEXT
	end
	potionsTab.Visible = (activeTab == "potions")
	weaponsTab.Visible = (activeTab == "weapons")
	casesTab.Visible = (activeTab == "cases")
	if activeTab == "potions" then renderPotions()
	elseif activeTab == "weapons" then renderWeapons()
	else renderCases() end
end

for id, b in navBtns do
	b.Activated:Connect(function()
		activeTab = id
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

-- Open/close the panel (called by the hotbar's INVENTORY button). Always lands on the Potions tab.
function GameInventoryController.Toggle()
	Remotes.Get("InvSnapshot"):FireServer() -- request a fresh snapshot
	activeTab = "potions"
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
	-- Live buff pushes: re-render the potions tab so USE/ACTIVE flips the moment a buff starts or ends.
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
		showToast("Wave reward: " .. (disp and disp.name or "a case") .. "!", rarityColor(rarity))
	end)
	Remotes.Get("InvSnapshot"):FireServer() -- ask for our snapshot on start
	print("[GameInventoryController] started (potions-first inventory)")
end

return GameInventoryController
