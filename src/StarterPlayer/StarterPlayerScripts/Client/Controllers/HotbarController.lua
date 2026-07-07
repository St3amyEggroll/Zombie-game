--!nonstrict
-- HotbarController.lua — the bottom-center hotbar: two SQUARE gun slots + a square inventory button.
-- Big tap targets (mobile-first): each slot is an 84px square — key number in the corner, gun name at the
-- bottom, persistent level as a gold chip. The HELD slot pops with a toxic edge + slight lift.
-- Click to switch (1 / 2 keys also work via InputController); the third square opens the inventory.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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

-- ===== TUNABLES =====
local SLOT = 84      -- square slot size (px) — finger-sized on phones after the responsive scale
local GAP = 10
local CASES_ICON = "rbxassetid://83465359983310" -- owner-supplied CASES button image

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local owned: { string } = { "pistol" }
local equipped = "pistol"
local gunLevels: { [string]: number } = {} -- persistent levels (lobby-managed, from DataReady)

local slotButtons = {}

-- ===== RENDER =====
local function refresh()
	for i = 1, 2 do
		local b = slotButtons[i]
		local id = owned[i]
		local weapon = id and WeaponConfig[id]
		if weapon then
			b.frame.Visible = true
			b.name.Text = weapon.name
			b.level.Text = "" -- CHANGED: gun upgrading removed; the LV chip is retired
			local isHeld = (id == equipped)
			b.stroke.Color = isHeld and UITheme.TOXIC or UITheme.BLACK
			b.stroke.Thickness = isHeld and 3 or 2
			b.name.TextColor3 = isHeld and UITheme.TEXT or UITheme.DIM
			b.key.TextColor3 = isHeld and UITheme.TOXIC or UITheme.DIM
			-- held slot lifts slightly out of the row
			TweenService:Create(b.frame, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.fromOffset(b.baseX, isHeld and -8 or 0),
			}):Play()
		else
			b.frame.Visible = false
		end
	end
end

-- ===== BUILD =====
local function makeSquare(holder, x)
	local frame = Instance.new("TextButton")
	frame.Position = UDim2.fromOffset(x, 0)
	frame.Size = UDim2.fromOffset(SLOT, SLOT)
	frame.BackgroundColor3 = UITheme.PANEL
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Text = ""
	frame.AutoButtonColor = true
	frame.Parent = holder
	UITheme.Corner(frame, 8)
	UITheme.Studs(frame, 30)
	UITheme.Depth(frame)
	return frame
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HotbarHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- Row anchor (manual X offsets — the held slot animates upward, a list layout would fight it).
	local totalW = SLOT * 2 + GAP -- CHANGED: 2 gun slots; CASES moved to the left-center menu pair
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -14)
	holder.Size = UDim2.fromOffset(totalW, SLOT + 10)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	for i = 1, 2 do
		local x = (i - 1) * (SLOT + GAP)
		local frame = makeSquare(holder, x)
		frame.Name = "Slot" .. i
		local stroke = UITheme.Edge(frame, UITheme.BLACK, 2)

		local key = Instance.new("TextLabel") -- keybind number, top-left corner
		key.Position = UDim2.fromOffset(7, 4)
		key.Size = UDim2.fromOffset(20, 18)
		key.BackgroundTransparency = 1
		key.FontFace = UITheme.TitleFace
		key.TextSize = 15
		key.TextXAlignment = Enum.TextXAlignment.Left
		key.TextColor3 = UITheme.DIM
		key.Text = tostring(i)
		key.Parent = frame

		local level = Instance.new("TextLabel") -- gold level chip, top-right corner
		level.AnchorPoint = Vector2.new(1, 0)
		level.Position = UDim2.new(1, -6, 0, 5)
		level.Size = UDim2.fromOffset(36, 14)
		level.BackgroundColor3 = UITheme.Darker(UITheme.GOLD, 0.75)
		level.BorderSizePixel = 0
		level.FontFace = UITheme.BodyBoldFace
		level.TextSize = 9
		level.TextColor3 = UITheme.GOLD
		level.Text = ""
		level.Parent = frame
		UITheme.Corner(level, 3)

		local name = Instance.new("TextLabel") -- gun name along the bottom of the square
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.new(0.5, 0, 1, -6)
		name.Size = UDim2.new(1, -10, 0, 26)
		name.BackgroundTransparency = 1
		name.FontFace = UITheme.BodyBoldFace
		name.TextSize = 11
		name.TextWrapped = true
		name.TextColor3 = UITheme.TEXT
		name.Text = ""
		name.Parent = frame

		frame.Activated:Connect(function()
			local id = owned[i]
			if id and id ~= equipped then
				Remotes.Get("EquipWeapon"):FireServer(id)
			end
		end)

		slotButtons[i] = { frame = frame, name = name, level = level, key = key, stroke = stroke, baseX = x }
	end

	-- CASES button — a standalone square on the LEFT-CENTER edge, LOWER of the GUNS/CASES pair
	-- (GUNS is the upper square, built by GunShopController). Matches the lobby's menu pair.
	local invBtn = Instance.new("TextButton")
	invBtn.Name = "InventoryButton"
	invBtn.AnchorPoint = Vector2.new(0, 0)
	invBtn.Position = UDim2.new(0, 16, 0.5, 6)
	invBtn.Size = UDim2.fromOffset(64, 64)
	invBtn.BackgroundColor3 = UITheme.PANEL
	invBtn.BackgroundTransparency = 0.05
	invBtn.BorderSizePixel = 0
	invBtn.Text = ""
	invBtn.AutoButtonColor = true
	invBtn.Parent = gui
	UITheme.Corner(invBtn, 8)
	UITheme.Studs(invBtn, 30)
	UITheme.Depth(invBtn)
	UITheme.Edge(invBtn, UITheme.BLACK, 2)
	UITheme.Edge(invBtn, UITheme.TOXIC, 1, 0.4)
	UITheme.Icon(invBtn, CASES_ICON, { caption = "CASES", captionColor = UITheme.TOXIC })
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
	print("[HotbarController] started (square hotbar)")
end

return HotbarController
