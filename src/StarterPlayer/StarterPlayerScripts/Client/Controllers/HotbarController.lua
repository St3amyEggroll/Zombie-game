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
local GunViewport = require(Modules.GunViewport)

local HotbarController = {}

-- ===== TUNABLES =====
local SLOT = 84      -- square slot size (px) — finger-sized on phones after the responsive scale
local GAP = 10

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
			-- 3D spinning model of the gun in this slot (rebuilt only when the slot's gun changes). Falls
			-- back to just the name if no model is published in ReplicatedStorage.GunDisplay yet.
			if b.vpId ~= id then
				if b.vp then
					b.vp:Destroy()
					b.vp = nil
				end
				local vp = GunViewport.Create(id, false) -- STILL (no spin) — just the gun, posed side-on + tilted
				if vp then
					vp.AnchorPoint = Vector2.new(0.5, 0)
					vp.Position = UDim2.new(0.5, 0, 0, 2)
					vp.Size = UDim2.new(1, -8, 1, -36) -- fill, leaving the full name strip clear (30 + margins)
					vp.ZIndex = 2
					vp.Parent = b.frame
					b.vp = vp
				end
				b.vpId = id
			end
			b.name.Text = weapon.name
			local isHeld = (id == equipped)
			b.stroke.Color = isHeld and UITheme.TOXIC or UITheme.BLACK
			b.stroke.Thickness = isHeld and 4 or 2 -- held = glow ring, not a hairline
			b.name.TextColor3 = isHeld and UITheme.TEXT or UITheme.DIM
			b.key.TextColor3 = isHeld and UITheme.TOXIC or UITheme.DIM
			-- held slot lifts slightly out of the row
			TweenService:Create(b.frame, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.fromOffset(b.baseX, isHeld and -8 or 0),
			}):Play()
		else
			b.frame.Visible = false
			if b.vp then
				b.vp:Destroy()
				b.vp = nil
				b.vpId = nil
			end
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
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 8) -- crisp rectangle slots (raw 8px, not the chunky curve)
	fc.Parent = frame
	UITheme.Studs(frame, 30)
	UITheme.Depth(frame)
	return frame
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HotbarHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.Hotbar
	gui.Parent = playerGui
	UITheme.Attach(gui, nil, nil, "hud") -- phones: match the HUD scale (guns ride above the dock)

	-- Row anchor (manual X offsets — the held slot animates upward, a list layout would fight it).
	local totalW = SLOT * 2 + GAP -- CHANGED: 2 gun slots; CASES moved to the left-center menu pair
	local holder = Instance.new("Frame")
	holder.Name = "Slots" -- SpectateController hides this (keeps the CASES button, which is a sibling)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	-- CHANGED (HUD renovation): the guns ride ABOVE the lobby-style dock now — lifted so the dock row
	-- (56px circles + labels) seats underneath them, mirroring the lobby's "PLAY above the dock" stack.
	holder.Position = UDim2.new(0.5, 0, 1, -94)
	holder.Size = UDim2.fromOffset(totalW, SLOT + 10)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	for i = 1, 2 do
		local x = (i - 1) * (SLOT + GAP)
		local frame = makeSquare(holder, x)
		frame.Name = "Slot" .. i
		local stroke = UITheme.Edge(frame, UITheme.BLACK, 2)

		local key = Instance.new("TextLabel") -- keybind number, top-left corner (a HINT: never above the name)
		key.Position = UDim2.fromOffset(7, 4)
		key.Size = UDim2.fromOffset(20, 16)
		key.ZIndex = 3 -- above the 3D gun viewport
		key.BackgroundTransparency = 1
		key.FontFace = UITheme.TitleFace
		key.TextSize = UITheme.Type.Caption
		key.TextXAlignment = Enum.TextXAlignment.Left
		key.TextColor3 = UITheme.DIM
		key.Text = tostring(i)
		key.Parent = frame

		-- (The gold level chip is DELETED — gun upgrading was removed; it rendered as a permanently
		-- empty rectangle buried under the viewport.)

		local name = Instance.new("TextLabel") -- gun name on a dark strip (reads over the 3D render)
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.new(0.5, 0, 1, -4)
		name.Size = UDim2.new(1, -10, 0, 30)
		name.ZIndex = 3 -- above the 3D gun viewport
		name.BackgroundColor3 = Color3.fromRGB(5, 10, 3)
		name.BackgroundTransparency = 0.45
		local nameCorner = Instance.new("UICorner")
		nameCorner.CornerRadius = UDim.new(0, 6)
		nameCorner.Parent = name
		name.FontFace = UITheme.BodyBoldFace
		name.TextSize = UITheme.Type.Body
		name.TextWrapped = true
		name.TextScaled = true
		name.TextColor3 = UITheme.TEXT
		name.Text = ""
		name.Parent = frame
		local nc = Instance.new("UITextSizeConstraint")
		nc.MaxTextSize = UITheme.Type.Body
		nc.Parent = name

		frame.Activated:Connect(function()
			local id = owned[i]
			if id and id ~= equipped then
				Remotes.Get("EquipWeapon"):FireServer(id)
			end
		end)

		slotButtons[i] = { frame = frame, name = name, key = key, stroke = stroke, baseX = x }
	end

	-- (The GUNS / SKIN CRATES launchers are DELETED — weapons and crates live in the LOBBY now.)
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
