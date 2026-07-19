--!nonstrict
-- LockerController.lua — the IN-RUN LOCKER (owner call — the mid-run agency that replaced the Power
-- Draft): a dock button opens a lobby-chrome panel listing EVERY gun in the game. Guns your account
-- level has unlocked can be tapped mid-run — the server (CombatService.SwapLoadout) swaps the gun into
-- the hotbar slot you're currently holding and re-welds the in-hand model. Locked guns sit greyed with
-- their unlock level, doubling as the "what do I level up for?" catalog.
--
-- Server-authoritative: this panel only ASKS (SwapLoadout / EquipWeapon); CombatService re-validates
-- ownership + unlock level, so a forged tap on a locked gun does nothing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Modules.UITheme)
local Remotes = require(Shared.Modules.Remotes)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local UIFocus = require(Shared.Modules.UIFocus)
local LobbyLook = require(Shared.Modules.LobbyLook)

local LockerController = {}

-- ===== TUNABLES =====
local PANEL_W, PANEL_H = 560, 470
local COLS = 3
local TILE_W, TILE_H = 172, 84
local GAP = 10
local PAD = 14

local localPlayer = Players.LocalPlayer

local root, grid -- chrome root (visibility) + the scrolling tile grid
local myLevel = 1
local profileOwned = {}   -- [weaponId] = true — the PROFILE's owned list (level grants + packs)
local loadout = {}        -- the run's 2-slot loadout (LoadoutChanged)
local equippedId = nil

-- Every real gun def in WeaponConfig, sorted by unlock level then name (the level ladder reads top-down).
local function gunList()
	local out = {}
	for id, w in WeaponConfig do
		if typeof(w) == "table" and w.id == id and w.name then
			table.insert(out, w)
		end
	end
	table.sort(out, function(a, b)
		local ua, ub = a.unlock or 0, b.unlock or 0
		if ua ~= ub then
			return ua < ub
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

local function isUnlocked(w): boolean
	return profileOwned[w.id] == true or myLevel >= (w.unlock or 0)
end

local function slotOfEquipped(): number
	local idx = equippedId and table.find(loadout, equippedId)
	return (idx == 2) and 2 or 1
end

local function rebuild()
	if not grid then
		return
	end
	for _, child in grid:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local guns = gunList()
	for i, w in guns do
		local col = (i - 1) % COLS
		local row = math.floor((i - 1) / COLS)
		local unlocked = isUnlocked(w)
		local inLoadout = table.find(loadout, w.id) ~= nil
		local isHeld = equippedId == w.id

		local tile = Instance.new("TextButton")
		tile.Name = "Gun_" .. w.id
		tile.AutoButtonColor = unlocked
		tile.Text = ""
		tile.Position = UDim2.fromOffset(PAD + col * (TILE_W + GAP), PAD + row * (TILE_H + GAP))
		tile.Size = UDim2.fromOffset(TILE_W, TILE_H)
		tile.BackgroundColor3 = unlocked and LobbyLook.PANEL2 or LobbyLook.darker(LobbyLook.PANEL, 0.25)
		tile.BorderSizePixel = 0
		tile.Parent = grid
		LobbyLook.corner(tile, 12)
		LobbyLook.ledge(tile,
			isHeld and LobbyLook.ACCENT or (inLoadout and LobbyLook.GOLD or (unlocked and LobbyLook.TBLACK or LobbyLook.TBLACK)),
			isHeld and 3 or 2, unlocked and 0.15 or 0.55)
		if unlocked then
			LobbyLook.lstuds(tile, 42, 0.95)
		end

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(10, 8)
		name.Size = UDim2.new(1, -20, 0, 22)
		name.FontFace = LobbyLook.TITLE_FACE
		name.TextSize = 16
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.TextColor3 = unlocked and LobbyLook.TEXTCOL or LobbyLook.DIMTEXT
		name.Text = tostring(w.name):upper()
		name.Parent = tile

		local tier = Instance.new("TextLabel")
		tier.BackgroundTransparency = 1
		tier.Position = UDim2.fromOffset(10, 30)
		tier.Size = UDim2.new(1, -20, 0, 16)
		tier.FontFace = LobbyLook.BODY_FACE
		tier.TextSize = 12
		tier.TextXAlignment = Enum.TextXAlignment.Left
		tier.TextColor3 = LobbyLook.DIMTEXT
		tier.Text = ("TIER %d"):format(tonumber(w.tier) or 1)
		tier.Parent = tile

		local state = Instance.new("TextLabel")
		state.BackgroundTransparency = 1
		state.Position = UDim2.fromOffset(10, 54)
		state.Size = UDim2.new(1, -20, 0, 20)
		state.FontFace = LobbyLook.BODYB_FACE
		state.TextSize = 13
		state.TextXAlignment = Enum.TextXAlignment.Left
		state.Parent = tile
		if isHeld then
			state.TextColor3 = LobbyLook.ACCENT
			state.Text = "IN HAND"
		elseif inLoadout then
			state.TextColor3 = LobbyLook.GOLD
			state.Text = "IN LOADOUT — TAP TO HOLD"
		elseif unlocked then
			state.TextColor3 = LobbyLook.TEXTCOL
			state.Text = "TAP TO SWAP IN"
		else
			state.TextColor3 = LobbyLook.ORANGE
			state.Text = ("🔒 UNLOCKS AT LVL %d"):format(w.unlock or 0)
		end

		tile.Activated:Connect(function()
			if not isUnlocked(w) then
				return -- locked: the tile is the catalog, not a button
			end
			if table.find(loadout, w.id) then
				Remotes.Get("EquipWeapon"):FireServer(w.id) -- already carried: just switch hands
			else
				-- Swap it into the slot you're holding (the other slot stays untouched).
				Remotes.Get("SwapLoadout"):FireServer(slotOfEquipped(), w.id)
			end
		end)
	end
	local rows = math.ceil(#guns / COLS)
	grid.CanvasSize = UDim2.fromOffset(0, PAD * 2 + rows * (TILE_H + GAP) - GAP)
end

function LockerController.Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local modalGui = Instance.new("ScreenGui")
	modalGui.Name = "LockerModal"
	modalGui.ResetOnSpawn = false
	modalGui.IgnoreGuiInset = true
	modalGui.DisplayOrder = UITheme.Layer.SettingsModal
	modalGui.Parent = playerGui
	UITheme.Attach(modalGui, PANEL_W + 20, PANEL_H + 40) -- mobile: the locker fills the phone screen

	local chromeRoot, body, _, chromeX = LobbyLook.ChromePanel(modalGui, PANEL_W, PANEL_H - 48,
		UITheme.HeaderColors and UITheme.HeaderColors.guns or Color3.fromRGB(140, 32, 28), "LOCKER")
	root = chromeRoot

	grid = Instance.new("ScrollingFrame")
	grid.Name = "GunGrid"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Position = UDim2.fromOffset(0, 0)
	grid.Size = UDim2.new(1, 0, 1, 0)
	grid.ScrollBarThickness = 6
	grid.ScrollBarImageColor3 = LobbyLook.DIMTEXT
	grid.CanvasSize = UDim2.fromOffset(0, 0)
	grid.Parent = body

	local function toggle()
		root.Visible = not root.Visible
		if root.Visible then
			UIFocus.Open()
			rebuild()
		else
			UIFocus.Close()
		end
	end
	LockerController.Toggle = toggle
	chromeX.Activated:Connect(function()
		if root.Visible then
			UIFocus.Close()
		end
		root.Visible = false
	end)

	-- Live state: the run loadout + the profile's level/owned list (locked tiles unlock LIVE on level-up).
	Remotes.Get("LoadoutChanged").OnClientEvent:Connect(function(owned, equipped)
		loadout = typeof(owned) == "table" and owned or {}
		equippedId = equipped
		if root.Visible then
			rebuild()
		end
	end)
	Remotes.Get("ProgressChanged").OnClientEvent:Connect(function(_xp, level)
		myLevel = tonumber(level) or myLevel
		if root.Visible then
			rebuild()
		end
	end)
	task.spawn(function()
		local ok, data = pcall(function()
			return Remotes.Get("GetData"):InvokeServer()
		end)
		if ok and typeof(data) == "table" then
			myLevel = tonumber(data.level) or myLevel
			if typeof(data.ownedWeapons) == "table" then
				for _, id in data.ownedWeapons do
					profileOwned[id] = true
				end
			end
			if root.Visible then
				rebuild()
			end
		end
	end)

	print("[LockerController] started (mid-run gun swaps armed)")
end

return LockerController
