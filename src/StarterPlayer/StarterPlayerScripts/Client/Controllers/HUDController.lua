--!nonstrict
-- HUDController.lua — drives the on-screen readouts. **You style the UI; this code feeds it data.**
--
-- NAMED-INSTANCE CONTRACT: build your HUD ScreenGui however you like, and name the text elements:
--   AmmoLabel, HealthLabel, RoundLabel, PointsLabel
-- This controller finds them ANYWHERE under PlayerGui by name and sets their .Text. Missing elements
-- are simply skipped. If none exist and SHOW_DEBUG_HUD is on, a plain fallback HUD is created so the
-- Phase 1 acceptance check is observable — delete it (or set SHOW_DEBUG_HUD=false) once you style yours.
--
-- (Phase 3 expands this with the full points/round/team HUD via -- NEW: markers.)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local InputController = require(script.Parent.InputController)

local HUDController = {}

-- ===== TUNABLES =====
local SHOW_DEBUG_HUD = true   -- set false (or just delete the DebugHUD) once you build your own UI

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ===== ELEMENT LOOKUP (by name, anywhere under PlayerGui) =====
-- Cached lazily: steady-state cost is one .Parent check, not a full PlayerGui scan per update.
-- Re-resolves automatically if a cached label is destroyed/reparented (respawn, styled HUD swap).
local labelCache: { [string]: Instance? } = {}

local function findLabel(name: string)
	local cached = labelCache[name]
	if cached and cached.Parent then
		return cached
	end
	for _, d in playerGui:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Name == name then
			labelCache[name] = d
			return d
		end
	end
	labelCache[name] = nil
	return nil
end

local function setText(name: string, text: string)
	local label = findLabel(name)
	if label then
		label.Text = text
	end
end

-- ===== DEBUG FALLBACK HUD =====
local function buildDebugHud()
	if findLabel("AmmoLabel") or findLabel("HealthLabel") then
		return -- a styled HUD already exists; don't add the fallback
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "DebugHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local function makeLabel(name: string, posY: number, anchorRight: boolean)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.Size = UDim2.fromOffset(260, 34)
		l.Position = anchorRight and UDim2.new(1, -270, 1, posY) or UDim2.new(0, 10, 1, posY)
		l.BackgroundTransparency = 0.4
		l.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		l.TextColor3 = Color3.fromRGB(255, 255, 255)
		l.TextScaled = true
		l.Font = Enum.Font.GothamBold
		l.Text = name
		l.Parent = gui
		return l
	end

	makeLabel("HealthLabel", -90, false)
	makeLabel("AmmoLabel", -50, true)
	makeLabel("RoundLabel", -90, true)
	makeLabel("PointsLabel", -50, false)
end

-- ===== UPDATES =====
-- Always reflect the EQUIPPED weapon (ammo events for other owned weapons shouldn't change the display).
local function refreshAmmo()
	local id = InputController.GetEquipped()
	local a = InputController.GetAmmo(id)
	local weapon = WeaponConfig[id]
	local name = weapon and weapon.name or id
	setText("AmmoLabel", string.format("%s   %d / %d", name, a.mag, a.reserve))
end

-- ===== LIFECYCLE =====
function HUDController.Start()
	if SHOW_DEBUG_HUD then
		buildDebugHud()
	end

	-- Ammo (from the predicted mirror + server corrections); always shows the equipped weapon.
	InputController.AmmoUpdated:Connect(function()
		refreshAmmo()
	end)
	refreshAmmo()

	-- Health (server-authoritative).
	Remotes.Get("HealthChanged").OnClientEvent:Connect(function(health, maxHealth)
		setText("HealthLabel", string.format("HP  %d / %d", math.floor(health + 0.5), math.floor(maxHealth + 0.5)))
	end)

	-- Wave + cash.
	Remotes.Get("RoundChanged").OnClientEvent:Connect(function(round)
		setText("RoundLabel", "Wave " .. tostring(round))
	end)
	Remotes.Get("PointsChanged").OnClientEvent:Connect(function(points)
		setText("PointsLabel", "$" .. Util.FormatNumber(points))
	end)

	-- Seed initial text.
	setText("PointsLabel", "$" .. Util.FormatNumber(GameConfig.StartingPoints))
	setText("RoundLabel", "Wave 0")

	print("[HUDController] started" .. (SHOW_DEBUG_HUD and " (debug HUD on)" or ""))
end

return HUDController
