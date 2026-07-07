--!nonstrict
-- GunShopController.lua — the MID-RUN gun shop: press B (or the SHOP button by the bottom-right corner)
-- to open a list of every gun. Buy with Coins at the same prices as the lobby; the purchase is permanent.
-- Reads names/prices/abilities straight from WeaponConfig; owned list + Coins come from GetData and stay
-- live via LoadoutChanged / LobbyMoneyChanged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConfig = require(Shared.Config.WeaponConfig)
local UITheme = require(Shared.Modules.UITheme)
local Remotes = require(Shared.Modules.Remotes)
local GunViewport = require(Shared.Modules.GunViewport)

local SoundController = require(script.Parent.SoundController)

local GunShopController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.B
local PANEL_W, PANEL_H = 560, 520
local ROW_H = 74

local localPlayer = Players.LocalPlayer

local panel = nil
local listFrame = nil
local coinsLabel = nil
local owned = {} -- [weaponId] = true
local coins = 0
local pendingBuy = nil -- weaponId waiting on the server (debounce)

function GunShopController.IsOpen(): boolean
	return panel ~= nil and panel.Visible
end

local function fmt(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local render -- forward decl

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

render = function()
	if not panel or not panel.Visible then
		return
	end
	coinsLabel.Text = "🪙 " .. fmt(coins)
	for _, c in listFrame:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for i, id in sortedGunIds() do
		local w = WeaponConfig[id]
		local isOwned = owned[id] == true
		local forSale = (tonumber(w.price) or 0) > 0

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, ROW_H)
		row.BackgroundColor3 = UITheme.PANEL2
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = listFrame
		UITheme.Corner(row, 6)
		UITheme.Edge(row, UITheme.BLACK, 2)

		local vp = GunViewport.Create(id, false)
		if vp then
			vp.Position = UDim2.fromOffset(6, 4)
			vp.Size = UDim2.fromOffset(92, ROW_H - 8)
			vp.Parent = row
		end

		local nm = UITheme.Label(row, nil, 16, UITheme.TEXT, true)
		nm.Position = UDim2.fromOffset(108, 8)
		nm.Size = UDim2.new(1, -260, 0, 20)
		nm.TextXAlignment = Enum.TextXAlignment.Left
		nm.Text = w.name

		local sub = UITheme.Label(row, nil, 12, UITheme.DIM)
		sub.Position = UDim2.fromOffset(108, 30)
		sub.Size = UDim2.new(1, -260, 0, 34)
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextYAlignment = Enum.TextYAlignment.Top
		sub.TextWrapped = true
		sub.Text = w.ability or ("DMG " .. tostring(w.damage) .. "  ·  " .. tostring(w.fireRate) .. "/s")

		if isOwned then
			local ownedLbl = UITheme.Label(row, nil, 14, UITheme.TOXIC, true)
			ownedLbl.AnchorPoint = Vector2.new(1, 0.5)
			ownedLbl.Position = UDim2.new(1, -16, 0.5, 0)
			ownedLbl.Size = UDim2.fromOffset(120, 20)
			ownedLbl.TextXAlignment = Enum.TextXAlignment.Right
			ownedLbl.Text = "OWNED"
		elseif not forSale then
			local starterLbl = UITheme.Label(row, nil, 14, UITheme.DIM, true)
			starterLbl.AnchorPoint = Vector2.new(1, 0.5)
			starterLbl.Position = UDim2.new(1, -16, 0.5, 0)
			starterLbl.Size = UDim2.fromOffset(120, 20)
			starterLbl.TextXAlignment = Enum.TextXAlignment.Right
			starterLbl.Text = "STARTER"
		else
			local canAfford = coins >= w.price and pendingBuy == nil
			local buy = UITheme.Button(row, "🪙 " .. fmt(w.price), canAfford and "gold" or "ghost")
			buy.AnchorPoint = Vector2.new(1, 0.5)
			buy.Position = UDim2.new(1, -12, 0.5, 0)
			buy.Size = UDim2.fromOffset(130, 44)
			if canAfford then
				buy.Activated:Connect(function()
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
				UITheme.SetButtonEnabled(buy, false, "🪙 " .. fmt(w.price))
			end
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
		SoundController.Play("UiOpen")
		refreshData()
		render()
	else
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

	-- SHOP button (mobile + mouse), left of the AUTOSHOOT pill in the bottom-right corner.
	local shopBtn = Instance.new("TextButton")
	shopBtn.AnchorPoint = Vector2.new(1, 1)
	shopBtn.Position = UDim2.new(1, -250, 1, -16)
	shopBtn.Size = UDim2.fromOffset(96, 38)
	shopBtn.BackgroundColor3 = UITheme.PANEL
	shopBtn.BorderSizePixel = 0
	shopBtn.FontFace = UITheme.TitleFace
	shopBtn.TextSize = 14
	shopBtn.TextColor3 = UITheme.GOLD
	shopBtn.Text = "SHOP [B]"
	shopBtn.Parent = gui
	UITheme.Corner(shopBtn, 6)
	UITheme.Edge(shopBtn)
	UITheme.Studs(shopBtn)

	-- Panel.
	panel = UITheme.Panel(gui, "GunShopPanel", { accent = UITheme.GOLD })
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.Visible = false
	UITheme.Header(panel, "GUN SHOP", 44, UITheme.GOLD)

	coinsLabel = UITheme.Label(panel, "Coins", 16, UITheme.GOLD, true)
	coinsLabel.AnchorPoint = Vector2.new(1, 0)
	coinsLabel.Position = UDim2.new(1, -64, 0, 12)
	coinsLabel.Size = UDim2.fromOffset(160, 24)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 6)
	closeBtn.Size = UDim2.fromOffset(40, 40)
	closeBtn.BackgroundColor3 = Color3.fromRGB(224, 34, 34)
	closeBtn.BorderSizePixel = 0
	closeBtn.FontFace = UITheme.TitleFace
	closeBtn.TextSize = 22
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Text = "✕"
	closeBtn.Parent = panel
	UITheme.Corner(closeBtn, 6)
	UITheme.Edge(closeBtn, UITheme.BLACK, 2.5)
	local xg = Instance.new("UIGradient")
	xg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(224, 34, 34)),
		ColorSequenceKeypoint.new(0.78, Color3.fromRGB(224, 34, 34)),
		ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 16, 16)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 16, 16)),
	})
	xg.Rotation = 90
	xg.Parent = closeBtn

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Position = UDim2.fromOffset(14, 56)
	listFrame.Size = UDim2.new(1, -28, 1, -70)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 6
	listFrame.CanvasSize = UDim2.new()
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = listFrame

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
