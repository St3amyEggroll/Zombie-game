--!nonstrict
-- HotbarController.lua — the bottom-center 2-slot gun hotbar.
--   * Two buttons show your equipped guns (name + PERSISTENT gun level from the lobby's Clash-Royale
--     copies system). Click to switch; on PC the 1 / 2 keys also work (InputController handles the keys —
--     both paths just fire EquipWeapon).
--   * Third button opens the in-game inventory.
-- (The old in-run UPGRADE button is gone — guns level up in the LOBBY now, with case copies + Coins.)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local Remotes = require(Modules.Remotes)
local UITheme = require(Modules.UITheme)

-- The inventory panel (its INVENTORY button lives on this hotbar). GUARDED: a broken inventory
-- controller must never brick the hotbar.
local okInv, GameInventoryController = pcall(require, script.Parent.GameInventoryController)
if not okInv or type(GameInventoryController) ~= "table" then
	GameInventoryController = { Toggle = function() end }
end

local HotbarController = {}

-- ===== STYLE (UITheme — gritty apocalypse) =====
local COL_PANEL    = UITheme.PANEL
local COL_TEXT     = UITheme.TEXT
local COL_TEXT_DIM = UITheme.DIM
local COL_ACCENT   = UITheme.TOXIC
local COL_GOLD     = UITheme.GOLD

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local owned: { string } = { "pistol" }
local equipped = "pistol"
local gunLevels: { [string]: number } = {} -- persistent levels (lobby-managed, from DataReady)

local slotButtons = {}

local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function hairline(o)
	return UITheme.Edge(o, UITheme.BLACK, 2, 0)
end

-- ===== RENDER =====
local function refresh()
	for i = 1, 2 do
		local b = slotButtons[i]
		local id = owned[i]
		local weapon = id and WeaponConfig[id]
		if weapon then
			b.frame.Visible = true
			b.name.Text = weapon.name
			b.level.Text = "Lv " .. tostring(gunLevels[id] or 1)
			local isHeld = (id == equipped)
			b.stroke.Color = isHeld and COL_ACCENT or UITheme.BLACK
			b.stroke.Transparency = isHeld and 0 or 0
			b.name.TextColor3 = isHeld and COL_TEXT or COL_TEXT_DIM
		else
			b.frame.Visible = false
		end
	end
end

-- ===== BUILD =====
local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HotbarHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- The row holds slot 1, slot 2, and the INVENTORY button — all centered together.
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -14)
	holder.Size = UDim2.fromOffset(470, 54)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 10)
	list.Parent = holder

	for i = 1, 2 do
		local frame = Instance.new("TextButton")
		frame.Name = "Slot" .. i
		frame.Size = UDim2.fromOffset(160, 54)
		frame.BackgroundColor3 = COL_PANEL
		frame.BackgroundTransparency = 0.06
		frame.BorderSizePixel = 0
		frame.Text = ""
		frame.AutoButtonColor = true
		frame.LayoutOrder = i
		frame.Parent = holder
		corner(frame, 6)
		UITheme.Studs(frame)
		UITheme.Depth(frame)
		local stroke = hairline(frame)

		local key = Instance.new("TextLabel")
		key.Position = UDim2.fromOffset(10, 0)
		key.Size = UDim2.fromOffset(16, 54)
		key.BackgroundTransparency = 1
		key.FontFace = UITheme.TitleFace
		key.TextSize = 14
		key.TextColor3 = COL_TEXT_DIM
		key.Text = tostring(i)
		key.Parent = frame

		local name = Instance.new("TextLabel")
		name.Position = UDim2.fromOffset(32, 9)
		name.Size = UDim2.new(1, -42, 0, 18)
		name.BackgroundTransparency = 1
		name.FontFace = UITheme.BodyBoldFace
		name.TextSize = 14
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = COL_TEXT
		name.Text = ""
		name.Parent = frame

		local level = Instance.new("TextLabel")
		level.Position = UDim2.fromOffset(32, 29)
		level.Size = UDim2.new(1, -42, 0, 14)
		level.BackgroundTransparency = 1
		level.FontFace = UITheme.BodyBoldFace
		level.TextSize = 12
		level.TextXAlignment = Enum.TextXAlignment.Left
		level.TextColor3 = COL_GOLD
		level.Text = ""
		level.Parent = frame

		frame.Activated:Connect(function()
			local id = owned[i]
			if id and id ~= equipped then
				Remotes.Get("EquipWeapon"):FireServer(id)
			end
		end)

		slotButtons[i] = { frame = frame, name = name, level = level, stroke = stroke }
	end

	-- INVENTORY button (third in the row, right of the gun slots).
	local invBtn = Instance.new("TextButton")
	invBtn.Name = "InventoryButton"
	invBtn.Size = UDim2.fromOffset(120, 54)
	invBtn.BackgroundColor3 = COL_PANEL
	invBtn.BackgroundTransparency = 0.06
	invBtn.BorderSizePixel = 0
	invBtn.FontFace = UITheme.TitleFace
	invBtn.TextSize = 14
	invBtn.TextColor3 = COL_TEXT
	invBtn.Text = "INVENTORY"
	invBtn.AutoButtonColor = true
	invBtn.LayoutOrder = 3
	invBtn.Parent = holder
	corner(invBtn, 6)
	UITheme.Studs(invBtn)
	UITheme.Depth(invBtn)
	hairline(invBtn)
	UITheme.Edge(invBtn, COL_ACCENT, 1, 0.35)
	invBtn.Activated:Connect(function()
		GameInventoryController.Toggle()
	end)
end

-- ===== LIFECYCLE =====
function HotbarController.Start()
	build()

	Remotes.Get("LoadoutChanged").OnClientEvent:Connect(function(list, eq)
		if type(list) == "table" then
			owned = list
		end
		if type(eq) == "string" then
			equipped = eq
		end
		refresh()
	end)

	-- Persistent gun levels ride in with the profile snapshot (they can't change mid-run).
	Remotes.Get("DataReady").OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.gunLevels) == "table" then
			gunLevels = data.gunLevels
			refresh()
		end
	end)
	-- DataReady can fire before this controller was listening (it's a one-shot at profile load) —
	-- pull the snapshot too so the level badges are right from the first frame.
	task.spawn(function()
		local ok, data = pcall(function()
			return Remotes.Get("GetData"):InvokeServer()
		end)
		if ok and type(data) == "table" and type(data.gunLevels) == "table" then
			gunLevels = data.gunLevels
			refresh()
		end
	end)

	-- The server's spawn-time loadout push can fire before this controller was listening (fresh teleport
	-- in) — request a re-send so BOTH slots show immediately, not just after the first weapon switch.
	Remotes.Get("LoadoutChanged"):FireServer()

	refresh()
	print("[HotbarController] started (2-slot hotbar)")
end

return HotbarController
