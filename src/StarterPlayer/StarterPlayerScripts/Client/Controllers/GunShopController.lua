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
local GUN_ICON = "rbxassetid://107465960874017" -- owner-supplied GUNS button image
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

-- ===== NEW GUN UNLOCKED showcase ===== a top-center banner: spinning 3D gun (with a black outline
-- silhouette behind it) + name, on a soft plate that FADES OUT at the sides (no hard box).
local function showGunUnlock(id)
	local w = WeaponConfig[id]
	local template = ReplicatedStorage:FindFirstChild("GunDisplay")
	template = template and template:FindFirstChild(id)
	local host = localPlayer:WaitForChild("PlayerGui"):FindFirstChild("GunShop")
	if not host then
		return
	end

	local plate = Instance.new("Frame")
	plate.AnchorPoint = Vector2.new(0.5, 0)
	plate.Position = UDim2.new(0.5, 0, 0, 150)
	plate.Size = UDim2.fromOffset(520, 116)
	plate.BackgroundColor3 = UITheme.BLACK
	plate.BackgroundTransparency = 0.35
	plate.BorderSizePixel = 0
	plate.ZIndex = 5
	plate.Parent = host
	local fade = Instance.new("UIGradient") -- the plate dissolves at both sides instead of a hard outline
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.22, 0),
		NumberSequenceKeypoint.new(0.78, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = plate

	local cap = UITheme.Label(plate, nil, UITheme.Type.Caption, UITheme.GOLD, true)
	cap.AnchorPoint = Vector2.new(0.5, 0)
	cap.Position = UDim2.new(0.5, 60, 0, 22)
	cap.Size = UDim2.fromOffset(300, 16)
	cap.ZIndex = 6
	cap.Text = "NEW GUN UNLOCKED"

	local nm = UITheme.Title(plate, nil, UITheme.Type.Item, UITheme.TEXT)
	nm.AnchorPoint = Vector2.new(0.5, 0)
	nm.Position = UDim2.new(0.5, 60, 0, 44)
	nm.Size = UDim2.fromOffset(320, 30)
	nm.TextXAlignment = Enum.TextXAlignment.Center
	nm.ZIndex = 6
	nm.Text = string.upper((w and w.name) or id)

	-- Spinning 3D gun with an inflated black-silhouette clone behind it = the outline.
	local spinConn
	if template then
		local vp = Instance.new("ViewportFrame")
		vp.BackgroundTransparency = 1
		vp.AnchorPoint = Vector2.new(0.5, 0.5)
		vp.Position = UDim2.new(0.5, -170, 0.5, 0)
		vp.Size = UDim2.fromOffset(110, 110)
		vp.Ambient = Color3.fromRGB(170, 170, 170)
		vp.ZIndex = 6
		vp.Parent = plate
		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		cam.Parent = vp
		vp.CurrentCamera = cam

		local wrap = Instance.new("Model")
		local outline = template:Clone()
		for _, d in outline:GetDescendants() do
			if d:IsA("BasePart") then
				d.Size = d.Size * 1.1 -- inflated hull = the outline
				d.Color = Color3.new(0, 0, 0)
				d.Material = Enum.Material.SmoothPlastic
			elseif d:IsA("SpecialMesh") or d:IsA("Texture") or d:IsA("Decal") then
				d:Destroy()
			end
		end
		outline.Parent = wrap
		local body = template:Clone()
		body.Parent = wrap
		wrap.Parent = vp

		local cf, size = wrap:GetBoundingBox()
		wrap.WorldPivot = cf
		local dist = (size.Magnitude / 2) / math.tan(math.rad(15)) * 1.15 + 0.1
		cam.CFrame = CFrame.new(cf.Position + Vector3.new(0, dist * 0.18, dist), cf.Position)
		local ang = 0
		spinConn = game:GetService("RunService").RenderStepped:Connect(function(dt)
			ang += dt * math.rad(60)
			wrap:PivotTo(CFrame.new(cf.Position) * CFrame.Angles(0, ang, 0) * cf.Rotation)
		end)
	end

	SoundController.Play("GunBought")
	task.delay(4.5, function()
		if spinConn then
			spinConn:Disconnect()
		end
		plate:Destroy()
	end)
end

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

	local namePlate = Instance.new("Frame") -- dark strip so the name reads on ANY rarity color
	namePlate.AnchorPoint = Vector2.new(0, 1)
	namePlate.Position = UDim2.new(0, 0, 1, 0)
	namePlate.Size = UDim2.new(1, 0, 0, 26)
	namePlate.BackgroundColor3 = UITheme.BLACK
	namePlate.BackgroundTransparency = 0.35
	namePlate.BorderSizePixel = 0
	namePlate.ZIndex = 2
	namePlate.Parent = cell
	local nm = UITheme.Label(cell, nil, 14, UITheme.TEXT, true)
	nm.AnchorPoint = Vector2.new(0, 1)
	nm.Position = UDim2.new(0, 0, 1, -4)
	nm.Size = UDim2.new(1, 0, 0, 22)
	nm.ZIndex = 3
	nm.TextTruncate = Enum.TextTruncate.AtEnd
	nm.Text = w.name
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = UITheme.BLACK
	nmStroke.Thickness = 1.4
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nmStroke.Parent = nm

	local chip = UITheme.Label(cell, nil, UITheme.Type.Caption, isOwned and UITheme.TOXIC or UITheme.GOLD, true)
	chip.BackgroundColor3 = UITheme.BLACK
	chip.BackgroundTransparency = 0.4
	chip.Position = UDim2.fromOffset(6, 6)
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.fromOffset(0, 18)
	local chipPad = Instance.new("UIPadding")
	chipPad.PaddingLeft = UDim.new(0, 5); chipPad.PaddingRight = UDim.new(0, 5)
	chipPad.Parent = chip
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0, 5); chipCorner.Parent = chip
	chip.TextXAlignment = Enum.TextXAlignment.Left
	chip.ZIndex = 3
	chip.Text = isOwned and "OWNED" or ("LV " .. tostring(w.unlock or 0))
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
	local nm = UITheme.Title(detail, nil, UITheme.Type.Item, col)
	nm.Position = UDim2.fromOffset(14, 214)
	nm.Size = UDim2.new(1, -28, 0, 30)
	nm.Text = string.upper(w.name)

	local dps = (w.damage or 0) * (w.fireRate or 0) * (w.pellets or 1)
	local stats = centered(250, 66, UITheme.Type.Body, UITheme.TEXT)
	stats.Text = ("DMG %.0f%s\n%s shots/s   ·   RNG %s\nDPS ~%d"):format(
		w.damage or 0, w.pellets and w.pellets > 1 and (" ×" .. w.pellets) or "",
		tostring(w.fireRate or "?"), tostring(w.range or "?"), math.floor(dps + 0.5))

	if w.ability then
		local ab = centered(324, 70, UITheme.Type.Body, UITheme.TOXIC, true)
		ab.TextYAlignment = Enum.TextYAlignment.Top
		ab.Text = w.ability
	end

	-- ===== ACTIONS (right) =====
	local isOwned = owned[id] == true
	local forSale = (tonumber(w.price) or 0) > 0
	if isOwned then
		local b = UITheme.Button(acts, "OWNED", "ghost")
		b.Position = UDim2.new(0, 0, 0, 0)
		b.Size = UDim2.new(1, 0, 0, UITheme.Ctl.CTA)
		UITheme.SetButtonEnabled(b, false, "OWNED ✓")
	elseif not forSale then
		local b = UITheme.Button(acts, "STARTER GUN", "ghost")
		b.Position = UDim2.new(0, 0, 0, 0)
		b.Size = UDim2.new(1, 0, 0, UITheme.Ctl.CTA)
		UITheme.SetButtonEnabled(b, false, "STARTER GUN")
	else
		-- XP-only unlocks: no buying. Show how far up the ladder this gun sits.
		local myLevel = tonumber(localPlayer:GetAttribute("AccountLevel")) or 1
		local b = UITheme.Button(acts, ("UNLOCKS AT LV %d"):format(w.unlock or 0), "ghost")
		b.Position = UDim2.new(0, 0, 0, 0)
		b.Size = UDim2.new(1, 0, 0, UITheme.Ctl.CTA)
		do
			UITheme.SetButtonEnabled(b, false, ("🔒 UNLOCKS AT LV %d"):format(w.unlock or 0))
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
	gui.DisplayOrder = UITheme.Layer.ShopModal
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- SHOP button (mobile + mouse) — a square icon button, UPPER of the LEFT-CENTER GUNS/CASES pair.
	local shopBtn = Instance.new("TextButton")
	shopBtn.AnchorPoint = Vector2.new(0, 0)
	shopBtn.Position = UDim2.new(0, 16, 0.5, -(UITheme.Ctl.Launcher + 4)) -- upper of the GUNS/SKIN CRATES pair
	shopBtn.Size = UDim2.fromOffset(UITheme.Ctl.Launcher, UITheme.Ctl.Launcher)
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
	do -- match the LOBBY's rendered panel size (game UIScaleMult 1.5 vs lobby 1.2 -> 0.8 evens it out)
		local ps = Instance.new("UIScale")
		ps.Scale = 0.8
		ps.Parent = panel
	end
	UITheme.Header(panel, "GUNS", nil, UITheme.GOLD, UITheme.HeaderColors.guns)

	coinsLabel = UITheme.Label(panel, "Coins", UITheme.Type.Section, UITheme.GOLD, true)
	coinsLabel.AnchorPoint = Vector2.new(1, 0)
	coinsLabel.Position = UDim2.new(1, -(8 + UITheme.Ctl.Std + 12), 0, 0) -- clears the in-bar close button
	coinsLabel.Size = UDim2.fromOffset(180, UITheme.Space.Header)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right

	local closeBtn = UITheme.Close(panel)

	grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(16, 64)
	grid.Size = UDim2.fromOffset(346, PANEL_H - 80)
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
	detail.Position = UDim2.fromOffset(378, 64)
	detail.Size = UDim2.fromOffset(280, PANEL_H - 80)
	detail.BackgroundColor3 = UITheme.PANEL2
	detail.BorderSizePixel = 0
	detail.Parent = panel
	UITheme.Corner(detail, 6)
	UITheme.Edge(detail, UITheme.BLACK, 2)
	UITheme.Edge(detail, UITheme.GOLD, 1, 0.55)

	acts = Instance.new("Frame")
	acts.AnchorPoint = Vector2.new(1, 0)
	acts.Position = UDim2.new(1, -16, 0, 64)
	acts.Size = UDim2.fromOffset(250, PANEL_H - 80)
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
			local before = owned
			owned = {}
			for _, id in ownedList do
				owned[id] = true
			end
			-- A gun that wasn't owned a moment ago = fresh unlock -> showcase it (skip the initial sync).
			if next(before) ~= nil then
				for id in owned do
					if not before[id] then
						showGunUnlock(id)
						break
					end
				end
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
