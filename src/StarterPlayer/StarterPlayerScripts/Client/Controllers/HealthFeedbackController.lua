--!nonstrict
-- HealthFeedbackController.lua — "you're getting hurt" feedback:
--   • A red vignette around the screen edges that pulses like a heartbeat when your HP is low (the lower
--     your HP, the stronger + faster the pulse).
--   • A brief red flash on every hit, even at full HP.
--   • Directional hurt arrows that point toward whatever just bit you (from DamageTaken's source position).
-- All client-side and asset-free (gradients + a glyph arrow).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")
local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local HealthFeedbackController = {}

-- ===== TUNABLES =====
local MAX_VIGNETTE   = 0.7    -- peak opacity of the vignette at 0 HP
local FLASH_ON_HIT   = 0.45   -- vignette opacity spike when hit at any HP
local FLASH_DECAY    = 2.5    -- per-second decay of that hit flash
local ARROW_LIFE     = 1.0    -- seconds a directional hurt arrow lingers

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local healthFrac = 1   -- current HP / max HP, from HealthChanged
local flash = 0        -- transient hit flash, decays each frame
local vignette         -- CanvasGroup
local arrowGui         -- ScreenGui holding directional arrows

-- ===== BUILD =====
local function edgeFrame(parent: Instance, rotation: number)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.fromRGB(190, 0, 0)
	f.BorderSizePixel = 0
	f.Parent = parent
	local g = Instance.new("UIGradient")
	g.Rotation = rotation
	-- opaque at both edges, clear through the middle = an edge vignette
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	g.Parent = f
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HurtFeedback"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -1 -- sit under the HUD
	gui.Parent = playerGui

	vignette = Instance.new("CanvasGroup")
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundTransparency = 1
	vignette.GroupTransparency = 1 -- hidden until hurt
	vignette.Parent = gui
	edgeFrame(vignette, 90) -- top + bottom
	edgeFrame(vignette, 0)  -- left + right

	arrowGui = Instance.new("ScreenGui")
	arrowGui.Name = "HurtArrows"
	arrowGui.ResetOnSpawn = false
	arrowGui.IgnoreGuiInset = true
	arrowGui.Parent = playerGui
end

-- ===== HEARTBEAT VIGNETTE ===== (per-frame; RenderStepped passes dt)
local function update(dt: number)
	if not vignette then
		return
	end
	flash = math.max(0, flash - FLASH_DECAY * dt)

	-- Low-HP intensity: 0 above the threshold, ramping to 1 at 0 HP.
	local low = GameConfig.LowHealthPct
	local intensity = 0
	if healthFrac < low and low > 0 then
		intensity = math.clamp(1 - healthFrac / low, 0, 1)
	end

	-- Heartbeat pulse: faster + deeper the closer to death.
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * (6 + intensity * 8))
	local lowAlpha = intensity * MAX_VIGNETTE * (0.45 + 0.55 * pulse)

	local alpha = math.max(lowAlpha, flash)
	vignette.GroupTransparency = 1 - math.clamp(alpha, 0, 1)
end

-- ===== DIRECTIONAL HURT ARROW =====
local function spawnArrow(sourcePos: Vector3)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local camCF = camera.CFrame
	local to = sourcePos - camCF.Position
	to = Vector3.new(to.X, 0, to.Z)
	if to.Magnitude < 0.01 then
		return
	end
	-- Angle of the source relative to where we're looking: 0 = dead ahead (top of screen), +right / -left.
	local angle = math.atan2(camCF.RightVector:Dot(to), Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z):Dot(to))

	-- A square holder centered on screen, rotated by the angle; the arrow sits near its top and orbits.
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(340, 340)
	holder.BackgroundTransparency = 1
	holder.Rotation = math.deg(angle)
	holder.Parent = arrowGui

	local arrow = Instance.new("TextLabel")
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromScale(0.5, 0.03)
	arrow.Size = UDim2.fromOffset(54, 54)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.GothamBlack
	arrow.Text = "▲"
	arrow.TextScaled = true
	arrow.TextColor3 = Color3.fromRGB(255, 60, 60)
	arrow.TextStrokeTransparency = 0.3
	arrow.Parent = holder

	TweenService:Create(arrow, TweenInfo.new(ARROW_LIFE), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(holder, ARROW_LIFE + 0.1)
end

local function onDamageTaken(amount: number, sourcePos: Vector3?)
	flash = math.min(1, flash + FLASH_ON_HIT) -- red screen flash on any hit
	if typeof(sourcePos) == "Vector3" then
		spawnArrow(sourcePos)
	end
end

-- ===== LIFECYCLE =====
function HealthFeedbackController.Start()
	build()

	Remotes.Get("HealthChanged").OnClientEvent:Connect(function(health, maxHealth)
		healthFrac = (maxHealth and maxHealth > 0) and math.clamp(health / maxHealth, 0, 1) or 1
	end)
	Remotes.Get("DamageTaken").OnClientEvent:Connect(onDamageTaken)

	RunService.RenderStepped:Connect(update)
	print("[HealthFeedbackController] started")
end

return HealthFeedbackController
