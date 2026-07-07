--!nonstrict
-- GunShopController.lua — the MID-RUN gun shop, laid out like the crate shop the owner approved:
-- gun GRID (left) | FEATURED gun (middle, spinning render + stats + ability) | BUY stack (right).
-- Open with B or the SHOP button (bottom-right). Buys use persistent Coins at WeaponConfig.price;
-- purchases are permanent (server: GunShopService). Owned list + Coins stay live via
-- LoadoutChanged / LobbyMoneyChanged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConfig = require(Shared.Config.WeaponConfig)
local UITheme = require(Shared.Modules.UITheme)
local Remotes = require(Shared.Modules.Remotes)
local GunViewport = require(Shared.Modules.GunViewport)
local UIFocus = require(Shared.Modules.UIFocus)

local SoundController = require(script.Parent.SoundController)

local GunShopController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.B
local GUN_ICON = "rbxassetid://107968878322175" -- owner-supplied GUNS button image
local PANEL_W, PANEL_H = 940, 560
local RARITY_COLORS = {
	common = Color3.fromRGB(176, 190, 197), uncommon = Color3.fromRGB(102, 187, 106),
	rare = Color3.fromRGB(66, 165, 245), epic = Color3.fromRGB(171, 71, 188),
	legendary = Color3.fromRGB(255, 167, 38), mythic = Color3.fromRGB(239, 83, 80),
	divine = Color3.fromRGB(255, 213, 79),
}
local WEAPON_RARITY = {
	pistol = "common", revolver = "uncommon", shotgun = "uncommon", ak47 = "rare",
	crossbow = "rare", minigun = "epic", freezeray = "epic", raygun = "legendary",
}

local localPlayer = Players.LocalPlayer

local panel, grid, detail, acts, coinsLabel
local owned = {}   -- [weaponId] = true
local coins = 0
local selectedId = nil
local pendingBuy = nil

function GunShopController.IsOpen(): boolean
	return panel ~= nil and panel.Visible
end

local function fmt(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function gunColor(id)
	return RARITY_COLORS[WEAPON_RARITY[id] or "common"] or RARITY_COLORS.common
end

local function sortedGunIds()
	local ids = {}
	for id in WeaponConfig do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local wa, wb = WeaponConfig[a], WeaponConfig[b]
		if (wa.tier or 0) ~= (wb.tier or 0) then
			return (wa.tier or 0) < (wb.tier or 0)
		end
		return a < b
	end)
	return ids
end

local function clearChildren(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local render -- forward decl

-- One gun cell in the grid: static render fills it, name strip at the bottom, price/OWNED chip.
local function gunCell(i, id)
	local w = WeaponConfig[id]
	local col = gunColor(id)
	local isOwned = owned[id] == true
	local isSel = selectedId == id

	local cell = Instance.new("TextButton")
	cell.BackgroundColor3 = col:Lerp(UITheme.BG, isOwned and 0.62 or 0.8)
	cell.AutoButtonColor = true
	cell.Text = ""
	cell.BorderSizePixel = 0
	cell.LayoutOrder = i
	cell.Parent = grid
	UITheme.Corner(cell, 7)
	UITheme.Edge(cell, isSel and UITheme.GOLD or UITheme.BLACK, isSel and 3 or 2.5)
	UITheme.CardShade(cell)

	local vp = GunViewport.Create(id, false)
	if vp then
		vp.Size = UDim2.new(1, 0, 1, -26)
		vp.ImageTransparency = isOwned and 0 or 0.35
		vp.Parent = cell
	end

	local nm = UITheme.Label(cell, nil, 14, UITheme.TEXT, true)
	nm.AnchorPoint = Vector2.new(0, 1)
	nm.Position = UDim2.new(0, 0, 1, -4)
	nm.Size = UDim2.new(1, 0, 0, 22)
	nm.Text = w.name
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = UITheme.BLACK
	nmStroke.Thickness = 1.4
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nmStroke.Parent = nm

	local chip = UITheme.Label(cell, nil, 12, isOwned and UITheme.TOXIC or UITheme.GOLD, true)
	chip.Position = UDim2.fromOffset(6, 6)
	chip.Size = UDim2.fromOffset(110, 18)
	chip.TextXAlignment = Enum.TextXAlignment.Left
	chip.ZIndex = 3
	chip.Text = isOwned and "OWNED" or ((tonumber(w.price) or 0) > 0 and ("🪙 " .. fmt(w.price)) or "STARTER")
	local cStroke = Instance.new("UIStroke")
	cStroke.Color = UITheme.BLACK
	cStroke.Thickness = 1.3
	cStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	cStroke.Parent = chip

	cell.Activated:Connect(function()
		selectedId = id
		render()
	end)
end

render = function()
	if not panel or not panel.Visible then
		return
	end
	coinsLabel.Text = "🪙 " .. fmt(coins)
	local ids = sortedGunIds()
	if not selectedId or not WeaponConfig[selectedId] then
		selectedId = ids[1]
	end
	clearChildren(grid)
	for i, id in ids do
		gunCell(i, id)
	end

	-- ===== FEATURED (middle) =====
	clearChildren(detail)
	clearChildren(acts)
	local id = selectedId
	local w = WeaponConfig[id]
	if not w then
		return
	end
	local col = gunColor(id)

	local well = Instance.new("Frame")
	well.Position = UDim2.fromOffset(14, 14)
	well.Size = UDim2.new(1, -28, 0, 190)
	well.BackgroundColor3 = col:Lerp(UITheme.BG, 0.7)
	well.BorderSizePixel = 0
	well.Parent = detail
	UITheme.Corner(well, 6)
	UITheme.Edge(well, UITheme.BLACK, 2)
	local wellVp = GunViewport.Create(id, true)
	if wellVp then
		wellVp.Size = UDim2.fromScale(1, 1)
		wellVp.Parent = well
	end

	local function centered(y, h, size, colr, bold)
		local l = UITheme.Label(detail, nil, size, colr, bold)
		l.Position = UDim2.fromOffset(14, y)
		l.Size = UDim2.new(1, -28, 0, h)
		l.TextWrapped = true
		return l
	end
	local nm = UITheme.Title(detail, nil, 21, col)
	nm.Position = UDim2.fromOffset(14, 214)
	nm.Size = UDim2.new(1, -28, 0, 30)
	nm.Text = string.upper(w.name)

	local dps = (w.damage or 0) * (w.fireRate or 0) * (w.pellets or 1)
	local stats = centered(250, 66, 14, UITheme.TEXT)
	stats.Text = ("DMG %.0f%s\n%s shots/s   ·   RNG %s\nDPS ~%d"):format(
		w.damage or 0, w.pellets and w.pellets > 1 and (" ×" .. w.pellets) or "",
		tostring(w.fireRate or "?"), tostring(w.range or "?"), math.floor(dps + 0.5))

	if w.ability then
		local ab = centered(324, 70, 13, UITheme.TOXIC, true)
		ab.TextYAlignment = Enum.TextYAlignment.Top
		ab.Text = w.ability
	end

	-- ===== ACTIONS (right) =====
	local isOwned = owned[id] == true
	local forSale = (tonumber(w.price) or 0) > 0
	if isOwned then
		local b = UITheme.Button(acts, "OWNED", "ghost")
		b.Position = UDim2.new(0, 0, 0, 0)
		b.Size = UDim2.new(1, 0, 0, 60)
		UITheme.SetButtonEnabled(b, false, "OWNED ✓")
	elseif not forSale then
		local b = UITheme.Button(acts, "STARTER GUN", "ghost")
		b.Position = UDim2.new(0, 0, 0, 0)
		b.Size = UDim2.new(1, 0, 0, 60)
		UITheme.SetButtonEnabled(b, false, "STARTER GUN")
	else
		local canAfford = coins >= w.price and pendingBuy == nil
		local b = UITheme.Button(acts, ("BUY  ·  🪙 %s"):format(fmt(w.price)), "gold")
		b.Position = UDim2.new(0, 0, 0, 0)
		b.Size = UDim2.new(1, 0, 0, 60)
		if canAfford then
			b.Activated:Connect(function()
				if pendingBuy then
					return
				end
				pendingBuy = id
				SoundController.Play("GunBought")
				Remotes.Get("BuyGun"):FireServer({ weaponId = id })
				task.delay(3, function() -- watchdog: unlock if no reply ever lands
					if pendingBuy == id then
						pendingBuy = nil
						render()
					end
				end)
			end)
		else
			UITheme.SetButtonEnabled(b, false, ("NEED 🪙 %s"):format(fmt(w.price)))
		end
	end
end

local function refreshData()
	task.spawn(function()
		local ok, data = pcall(function()
			return Remotes.Get("GetData"):InvokeServer()
		end)
		if ok and typeof(data) == "table" then
			owned = {}
			for _, id in (typeof(data.ownedWeapons) == "table" and data.ownedWeapons or {}) do
				owned[id] = true
			end
			coins = tonumber(data.lobbyMoney) or 0
			render()
		end
	end)
end

local function setOpen(open)
	if not panel then
		return
	end
	panel.Visible = open
	if open then
		UIFocus.Open()
		SoundController.Play("UiOpen")
		refreshData()
		render()
	else
		UIFocus.Close()
		SoundController.Play("UiClose")
	end
end

function GunShopController.Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "GunShop"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 22
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- SHOP button (mobile + mouse) — a square icon button, left of the AUTOSHOOT pill (bottom-right).
	local shopBtn = Instance.new("TextButton")
	shopBtn.AnchorPoint = Vector2.new(1, 1)
	shopBtn.Position = UDim2.new(1, -250, 1, -16)
	shopBtn.Size = UDim2.fromOffset(64, 64)
	shopBtn.BackgroundColor3 = UITheme.PANEL
	shopBtn.BorderSizePixel = 0
	shopBtn.AutoButtonColor = true
	shopBtn.Text = ""
	shopBtn.Parent = gui
	UITheme.Corner(shopBtn, 8)
	UITheme.Edge(shopBtn)
	UITheme.Studs(shopBtn)
	UITheme.Icon(shopBtn, GUN_ICON, { caption = "GUNS", captionColor = UITheme.GOLD, badge = "B", badgeColor = UITheme.GOLD })

	-- Panel: grid | featured | buy stack (same skeleton as the lobby's crate shop).
	panel = UITheme.Panel(gui, "GunShopPanel", { accent = UITheme.HeaderColors.guns })
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.Visible = false
	UITheme.Header(panel, "GUNS", 44, UITheme.GOLD, UITheme.HeaderColors.guns)

	coinsLabel = UITheme.Label(panel, "Coins", 18, UITheme.GOLD, true)
	coinsLabel.AnchorPoint = Vector2.new(1, 0)
	coinsLabel.Position = UDim2.new(1, -66, 0, 12)
	coinsLabel.Size = UDim2.fromOffset(180, 26)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 6)
	closeBtn.Size = UDim2.fromOffset(46, 46)
	closeBtn.BackgroundColor3 = Color3.fromRGB(224, 34, 34)
	closeBtn.BorderSizePixel = 0
	closeBtn.FontFace = UITheme.TitleFace
	closeBtn.TextSize = 26
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Text = "✕"
	closeBtn.Parent = panel
	UITheme.Corner(closeBtn, 7)
	UITheme.Edge(closeBtn, UITheme.BLACK, 2.5)
	UITheme.WhiteX(closeBtn)
	local xg = Instance.new("UIGradient")
	xg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(224, 34, 34)),
		ColorSequenceKeypoint.new(0.78, Color3.fromRGB(224, 34, 34)),
		ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 16, 16)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 16, 16)),
	})
	xg.Rotation = 90
	xg.Parent = closeBtn

	grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(16, 60)
	grid.Size = UDim2.fromOffset(346, PANEL_H - 76)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.Parent = panel
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(160, 148)
	gl.CellPadding = UDim2.fromOffset(12, 12)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid

	detail = Instance.new("Frame")
	detail.Position = UDim2.fromOffset(378, 60)
	detail.Size = UDim2.fromOffset(280, PANEL_H - 76)
	detail.BackgroundColor3 = UITheme.PANEL2
	detail.BorderSizePixel = 0
	detail.Parent = panel
	UITheme.Corner(detail, 6)
	UITheme.Edge(detail, UITheme.BLACK, 2)
	UITheme.Edge(detail, UITheme.GOLD, 1, 0.55)

	acts = Instance.new("Frame")
	acts.AnchorPoint = Vector2.new(1, 0)
	acts.Position = UDim2.new(1, -16, 0, 60)
	acts.Size = UDim2.fromOffset(250, PANEL_H - 76)
	acts.BackgroundTransparency = 1
	acts.Parent = panel

	shopBtn.Activated:Connect(function()
		setOpen(not panel.Visible)
	end)
	closeBtn.Activated:Connect(function()
		setOpen(false)
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			setOpen(not panel.Visible)
		end
	end)

	-- Live updates: a purchase answers with LoadoutChanged (owned list) + LobbyMoneyChanged (coins).
	Remotes.Get("LoadoutChanged").OnClientEvent:Connect(function(ownedList)
		if typeof(ownedList) == "table" then
			owned = {}
			for _, id in ownedList do
				owned[id] = true
			end
		end
		pendingBuy = nil
		render()
	end)
	Remotes.Get("LobbyMoneyChanged").OnClientEvent:Connect(function(total)
		coins = tonumber(total) or coins
		render()
	end)

	print("[GunShopController] started")
end

return GunShopController
