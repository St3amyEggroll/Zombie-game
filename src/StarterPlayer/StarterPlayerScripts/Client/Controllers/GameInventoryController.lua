--!nonstrict
-- GameInventoryController.lua — the IN-GAME inventory window (view-only). Open it with the top-left button
-- to SEE your equipped weapons and the cases you own (you equip weapons + open cases back in the LOBBY),
-- and to USE potions you've collected. Potions are dropped by elite (yellow) zombies; using one currently
-- just consumes it (no effect yet). Data comes from GameInventoryService via the InvSnapshot remote.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local GameInventoryController = {}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local ACCENT = Color3.fromRGB(120, 220, 120)
local CARD = Color3.fromRGB(24, 24, 32)
local DIM = Color3.fromRGB(70, 70, 82)

local data = nil
local activeTab = "weapons"

local function corner(o, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = o
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "GameInventory"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 8
gui.Parent = playerGui

local openBtn = Instance.new("TextButton")
openBtn.Position = UDim2.fromOffset(16, 16); openBtn.Size = UDim2.fromOffset(150, 40)
openBtn.BackgroundColor3 = Color3.fromRGB(40, 44, 60); openBtn.BorderSizePixel = 0
openBtn.Font = Enum.Font.GothamBlack; openBtn.TextSize = 16; openBtn.TextColor3 = Color3.fromRGB(235, 235, 245)
openBtn.Text = "🎒 INVENTORY"; openBtn.Parent = gui; corner(openBtn, 10)
local obStroke = Instance.new("UIStroke"); obStroke.Color = ACCENT; obStroke.Thickness = 1.3; obStroke.Transparency = 0.4; obStroke.Parent = openBtn

-- Potion drop toast.
local toast = Instance.new("TextLabel")
toast.AnchorPoint = Vector2.new(0.5, 0); toast.Position = UDim2.new(0.5, 0, 0, 70); toast.Size = UDim2.fromOffset(320, 40)
toast.BackgroundColor3 = Color3.fromRGB(20, 22, 30); toast.BackgroundTransparency = 0.1; toast.BorderSizePixel = 0
toast.Font = Enum.Font.GothamBold; toast.TextSize = 16; toast.TextColor3 = Color3.fromRGB(255, 225, 120)
toast.Text = ""; toast.Visible = false; toast.Parent = gui; corner(toast, 8)

local toastToken = 0
local function showToast(text)
	toast.Text = text
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
panel.Size = UDim2.fromOffset(680, 440); panel.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
panel.BackgroundTransparency = 0.03; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 16)
local pStroke = Instance.new("UIStroke"); pStroke.Color = ACCENT; pStroke.Thickness = 2; pStroke.Transparency = 0.5; pStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 12); title.Size = UDim2.new(1, 0, 0, 30); title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack; title.TextSize = 22; title.TextColor3 = Color3.fromRGB(240, 240, 245)
title.Text = "INVENTORY"; title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0); closeBtn.Position = UDim2.new(1, -12, 0, 12); closeBtn.Size = UDim2.fromOffset(32, 32)
closeBtn.BackgroundColor3 = Color3.fromRGB(210, 70, 70); closeBtn.Font = Enum.Font.GothamBlack; closeBtn.TextSize = 20
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255); closeBtn.Text = "✕"; closeBtn.Parent = panel; corner(closeBtn, 8)

local nav = Instance.new("Frame")
nav.Position = UDim2.fromOffset(16, 52); nav.Size = UDim2.fromOffset(150, 372); nav.BackgroundTransparency = 1; nav.Parent = panel
local navList = Instance.new("UIListLayout"); navList.Padding = UDim.new(0, 8); navList.Parent = nav
local navBtns = {}
local function navButton(id, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 44); b.BackgroundColor3 = CARD; b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold; b.TextSize = 16; b.TextColor3 = Color3.fromRGB(235, 235, 245); b.Text = text; b.Parent = nav
	corner(b, 8); navBtns[id] = b
	return b
end
navButton("weapons", "🔫  Weapons")
navButton("cases", "📦  Cases")
navButton("potions", "🧪  Potions")

local hint = Instance.new("TextLabel")
hint.AnchorPoint = Vector2.new(0.5, 1); hint.Position = UDim2.new(0.5, 78, 1, -8); hint.Size = UDim2.fromOffset(480, 18)
hint.BackgroundTransparency = 1; hint.Font = Enum.Font.Gotham; hint.TextSize = 12; hint.TextColor3 = Color3.fromRGB(150, 155, 170)
hint.Text = "Equip weapons & open cases in the LOBBY. Potions are usable here."; hint.Parent = panel

local content = Instance.new("ScrollingFrame")
content.Position = UDim2.fromOffset(178, 52); content.Size = UDim2.fromOffset(486, 350)
content.BackgroundColor3 = Color3.fromRGB(12, 14, 22); content.BackgroundTransparency = 0.2; content.BorderSizePixel = 0
content.ScrollBarThickness = 6; content.CanvasSize = UDim2.new(); content.AutomaticCanvasSize = Enum.AutomaticSize.Y
content.Parent = panel; corner(content, 12)
local contentPad = Instance.new("UIPadding")
contentPad.PaddingTop = UDim.new(0, 10); contentPad.PaddingLeft = UDim.new(0, 10); contentPad.PaddingRight = UDim.new(0, 10); contentPad.Parent = content
local contentList = Instance.new("UIListLayout"); contentList.Padding = UDim.new(0, 8); contentList.Parent = content

-- ===== RENDER =====
local function clearContent()
	for _, c in content:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

local function rowCard(height)
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, height); f.BackgroundColor3 = Color3.fromRGB(26, 28, 40); f.BorderSizePixel = 0; f.Parent = content
	corner(f, 8)
	return f
end

local function label(parent, x, w, text, color, size, font)
	local l = Instance.new("TextLabel")
	l.Position = UDim2.fromOffset(x, 0); l.Size = UDim2.new(0, w, 1, 0); l.BackgroundTransparency = 1
	l.Font = font or Enum.Font.GothamBold; l.TextSize = size or 15; l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = color or Color3.fromRGB(235, 235, 245); l.Text = text; l.Parent = parent
	return l
end

local function renderWeapons()
	local cat = data.catalog.weapons
	for slot = 1, 5 do
		local id = data.tierLoadout[slot]
		local card = rowCard(52)
		label(card, 12, 60, "Tier " .. slot, Color3.fromRGB(150, 160, 175), 13)
		if id and id ~= "" and cat[id] then
			local w = cat[id]
			label(card, 78, 160, "🔫 " .. w.name, Color3.fromRGB(240, 240, 245), 16)
			local dps = (w.damage or 0) * (w.fireRate or 0) * (w.pellets or 1)
			label(card, 250, 230, ("DMG %s  ·  %s/s  ·  ~%d DPS"):format(tostring(w.damage), tostring(w.fireRate), math.floor(dps + 0.5)),
				Color3.fromRGB(170, 190, 175), 13, Enum.Font.Gotham)
		else
			label(card, 78, 200, "— empty —", Color3.fromRGB(120, 125, 140), 15, Enum.Font.Gotham)
		end
	end
end

local function renderCases()
	local any = false
	for caseId, disp in data.catalog.cases do
		local count = data.cases[caseId] or 0
		if count > 0 then any = true end
		local card = rowCard(48)
		label(card, 12, 260, "📦 " .. disp.name, Color3.fromRGB(240, 240, 245), 16)
		label(card, 300, 160, "Owned: " .. count, Color3.fromRGB(180, 190, 205), 14, Enum.Font.Gotham)
	end
	if not any then
		label(rowCard(40), 12, 440, "No cases — open them in the lobby to unlock weapons.", Color3.fromRGB(150, 155, 170), 14, Enum.Font.Gotham)
	end
end

local function renderPotions()
	local any = false
	for potId, disp in data.catalog.potions do
		local count = data.potions[potId] or 0
		if count > 0 then
			any = true
			local card = rowCard(54)
			label(card, 12, 200, "🧪 " .. disp.name, Color3.fromRGB(240, 240, 245), 16)
			label(card, 12, 440, disp.desc, Color3.fromRGB(160, 170, 185), 11, Enum.Font.Gotham).Position = UDim2.fromOffset(12, 30)
			label(card, 220, 90, "x" .. count, Color3.fromRGB(200, 210, 225), 15)
			local use = Instance.new("TextButton")
			use.AnchorPoint = Vector2.new(1, 0.5); use.Position = UDim2.new(1, -12, 0.5, 0); use.Size = UDim2.fromOffset(90, 34)
			use.BackgroundColor3 = ACCENT; use.TextColor3 = Color3.fromRGB(15, 25, 15); use.Font = Enum.Font.GothamBold
			use.TextSize = 15; use.Text = "USE"; use.BorderSizePixel = 0; use.Parent = card; corner(use, 8)
			use.Activated:Connect(function()
				Remotes.Get("ConsumePotion"):FireServer(potId)
				local fx = (potId == "xp" and "2× run XP this run!")
					or (potId == "luck" and "better buff odds this run!")
					or "used!"
				showToast("🧪 " .. disp.name .. " — " .. fx)
			end)
		end
	end
	if not any then
		label(rowCard(40), 12, 440, "No potions yet — kill YELLOW elite zombies to get them.", Color3.fromRGB(150, 155, 170), 14, Enum.Font.Gotham)
	end
end

local function render()
	if not data then return end
	for id, b in navBtns do
		local on = (id == activeTab)
		b.BackgroundColor3 = on and ACCENT or CARD
		b.TextColor3 = on and Color3.fromRGB(15, 25, 15) or Color3.fromRGB(235, 235, 245)
	end
	clearContent()
	if activeTab == "weapons" then renderWeapons()
	elseif activeTab == "cases" then renderCases()
	else renderPotions() end
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
openBtn.Activated:Connect(function()
	Remotes.Get("InvSnapshot"):FireServer() -- request a fresh snapshot
	panel.Visible = not panel.Visible
	if panel.Visible then render() end
end)

-- ===== EVENTS =====
function GameInventoryController.Start()
	Remotes.Get("InvSnapshot").OnClientEvent:Connect(function(snap)
		if typeof(snap) == "table" then
			data = snap
			if panel.Visible then render() end
		end
	end)
	Remotes.Get("PotionDropped").OnClientEvent:Connect(function(potionId)
		local name = data and data.catalog and data.catalog.potions[potionId] and data.catalog.potions[potionId].name or "a potion"
		showToast("🧪 Elite drop: " .. name .. "!")
	end)
	Remotes.Get("InvSnapshot"):FireServer() -- ask for our snapshot on start
	print("[GameInventoryController] started")
end

return GameInventoryController
