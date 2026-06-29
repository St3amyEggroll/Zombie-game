--!nonstrict
-- CombatFeedbackController.lua — the procedural "juice": bullet tracers, muzzle flash, impact effects, and
-- a hitmarker. All client-side and immediate (no uploaded animations needed). Your own shots are predicted
-- instantly; other players' shots are drawn from the server's ShotFired broadcast.
--
-- Optional: add an Attachment named "Muzzle" to your gun model for a precise tracer/flash origin
-- (otherwise the front of the Handle is used).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local AnimationConfig = require(Config.AnimationConfig)
local Remotes = require(Modules.Remotes)

local InputController = require(script.Parent.InputController)
local CameraController = require(script.Parent.CameraController)

local CombatFeedbackController = {}

local localPlayer = Players.LocalPlayer
local fxFolder -- holds client-only effect parts

-- ===== EFFECT PARTS =====
local function muzzleCFrame(): CFrame?
	local char = localPlayer.Character
	local held = char and char:FindFirstChild("HeldWeapon")
	if not held then
		return nil
	end
	local muzzle = held:FindFirstChild("Muzzle", true)
	if muzzle and muzzle:IsA("Attachment") then
		return muzzle.WorldCFrame
	end
	local handle = held:FindFirstChild("Handle") or held.PrimaryPart
	if handle and handle:IsA("BasePart") then
		return handle.CFrame * CFrame.new(0, 0, -handle.Size.Z * 0.5)
	end
	return nil
end

local function drawTracer(from: Vector3, to: Vector3)
	local cfg = AnimationConfig.Tracer
	if not cfg.Enabled then
		return
	end
	local dist = (to - from).Magnitude
	if dist < 1 or dist ~= dist then
		return
	end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = cfg.Color
	part.Size = Vector3.new(cfg.Width, cfg.Width, dist)
	part.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -dist * 0.5)
	part.Parent = fxFolder
	TweenService:Create(part, TweenInfo.new(cfg.Life), { Transparency = 1 }):Play()
	Debris:AddItem(part, cfg.Life)
end

local function muzzleFlash(cf: CFrame)
	local cfg = AnimationConfig.MuzzleFlash
	if not cfg.Enabled then
		return
	end
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(0.5, 0.5, 0.5)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = cfg.Color
	ball.CFrame = cf
	local light = Instance.new("PointLight")
	light.Color = cfg.Color
	light.Brightness = cfg.Brightness
	light.Range = cfg.Range
	light.Parent = ball
	ball.Parent = fxFolder
	TweenService:Create(ball, TweenInfo.new(cfg.Life), { Transparency = 1, Size = Vector3.new(0.1, 0.1, 0.1) }):Play()
	Debris:AddItem(ball, cfg.Life)
end

local function impact(pos: Vector3, onZombie: boolean)
	local cfg = AnimationConfig.Impact
	if not cfg.Enabled then
		return
	end
	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.new(0.6, 0.6, 0.6)
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = onZombie and cfg.Color or cfg.WorldColor
	burst.CFrame = CFrame.new(pos)
	burst.Parent = fxFolder
	TweenService:Create(burst, TweenInfo.new(cfg.Life), { Transparency = 1, Size = Vector3.new(1.6, 1.6, 1.6) }):Play()
	Debris:AddItem(burst, cfg.Life)
end

-- ===== HITMARKER (UI) =====
local hitmarkerGui
local function buildHitmarker()
	local cfg = AnimationConfig.Hitmarker
	hitmarkerGui = Instance.new("ScreenGui")
	hitmarkerGui.Name = "Hitmarker"
	hitmarkerGui.ResetOnSpawn = false
	hitmarkerGui.IgnoreGuiInset = true
	hitmarkerGui.Enabled = false
	hitmarkerGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Four little dashes around the center forming a hitmarker.
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(cfg.Size, cfg.Size)
	holder.BackgroundTransparency = 1
	holder.Name = "Holder"
	holder.Parent = hitmarkerGui

	local function dash(rot: number)
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = UDim2.fromScale(0.5, 0.5)
		d.Size = UDim2.fromOffset(cfg.Size, 3)
		d.Rotation = rot
		d.BorderSizePixel = 0
		d.BackgroundColor3 = cfg.Color
		d.Name = "Dash"
		d.Parent = holder
	end
	dash(45)
	dash(-45)
end

local function showHitmarker(killed: boolean, headshot: boolean)
	local cfg = AnimationConfig.Hitmarker
	if not cfg.Enabled or not hitmarkerGui then
		return
	end
	local color = killed and cfg.KillColor or cfg.Color
	for _, d in hitmarkerGui.Holder:GetChildren() do
		if d:IsA("Frame") then
			d.BackgroundColor3 = color
			d.BackgroundTransparency = 0
		end
	end
	hitmarkerGui.Holder.Size = UDim2.fromOffset(headshot and cfg.Size * 1.4 or cfg.Size, headshot and cfg.Size * 1.4 or cfg.Size)
	hitmarkerGui.Enabled = true
	task.delay(cfg.Life, function()
		if hitmarkerGui then
			hitmarkerGui.Enabled = false
		end
	end)
end

-- ===== EVENT HOOKS =====
local function onLocalFired(_weaponId: string)
	local muzzleCF = muzzleCFrame()
	local origin, direction = CameraController.GetAim()
	if not origin or not direction then
		return
	end
	local from = muzzleCF and muzzleCF.Position or origin
	-- Predict the endpoint with a client raycast (server is authoritative for damage).
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { localPlayer.Character, fxFolder }
	params.IgnoreWater = true
	local result = Workspace:Raycast(origin, direction * 1000, params)
	local to = result and result.Position or (origin + direction * 300)

	if muzzleCF then
		muzzleFlash(muzzleCF)
	end
	drawTracer(from, to)
end

local function onShotFired(shooterUserId: number, origin: Vector3, endpoint: Vector3)
	if shooterUserId == localPlayer.UserId then
		return -- our own shot is already drawn locally (predicted)
	end
	drawTracer(origin, endpoint)
end

local function onHitConfirmed(position: Vector3, isHeadshot: boolean, hitHumanoid: boolean, killed: boolean)
	impact(position, hitHumanoid)
	if hitHumanoid then
		showHitmarker(killed, isHeadshot)
	end
end

-- ===== LIFECYCLE =====
function CombatFeedbackController.Start()
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "CombatFX"
	fxFolder.Parent = Workspace.CurrentCamera -- client-only, never replicated

	buildHitmarker()

	InputController.Fired:Connect(onLocalFired)
	Remotes.Get("ShotFired").OnClientEvent:Connect(onShotFired)
	Remotes.Get("HitConfirmed").OnClientEvent:Connect(onHitConfirmed)

	print("[CombatFeedbackController] started")
end

return CombatFeedbackController
