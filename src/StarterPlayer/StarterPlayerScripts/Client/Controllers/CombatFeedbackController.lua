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
local RunService = game:GetService("RunService")
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

-- ===== SCREEN SHAKE / KICK (Perlin-noise shake; applied via Humanoid.CameraOffset each frame) =====
-- We track the exact offset we last applied and subtract it before applying the new one, so this shake
-- only ever adds/removes ITS OWN contribution to CameraOffset (anything else writing CameraOffset is left
-- intact). A fresh shot restarts the shake; rapid fire keeps it alive = a rumble.
local shakeElapsed = math.huge -- >= duration means "no active shake"
local shakeDuration = 0
local shakeMagnitude = 0
local shakeFrequency = 20
local shakeSeed = 0            -- varies the noise sample per shot so repeats don't look identical
local kickUp = 0              -- transient upward camera nudge, recovers each frame
local lastOffset = Vector3.zero
local lastHumanoid: Humanoid? = nil

local function addShake(weaponId: string)
	local cfg = AnimationConfig.Shake
	if not cfg.Enabled then
		return
	end
	local w = cfg.PerWeapon[weaponId] or cfg.Default
	shakeElapsed = 0
	shakeDuration = math.max(w.Duration, 0)
	shakeMagnitude = math.max(w.Magnitude, 0)
	shakeFrequency = math.max(w.Frequency, 1)
	shakeSeed = (shakeSeed + 7.13) % 1000 -- walk the noise field so each shot samples a new spot
	kickUp = math.min(2, kickUp + w.Kick)
end

local function updateShake(dt: number)
	local cfg = AnimationConfig.Shake
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= lastHumanoid then
		lastOffset = Vector3.zero -- respawned: our old offset belongs to a gone humanoid; start clean
		lastHumanoid = humanoid
	end
	if not cfg.Enabled or not humanoid then
		return
	end

	local offset = Vector3.zero
	shakeElapsed += dt
	if shakeDuration > 0 and shakeElapsed < shakeDuration then
		local strength = shakeMagnitude * (1 - shakeElapsed / shakeDuration)
		local t = shakeElapsed * shakeFrequency
		offset = Vector3.new(
			math.noise(t, 0, shakeSeed),
			math.noise(0, t, shakeSeed),
			0
		) * strength
	end

	kickUp = math.max(0, kickUp - kickUp * math.clamp(cfg.KickRecover * dt, 0, 1))
	local total = offset + Vector3.new(0, kickUp, 0)
	humanoid.CameraOffset = humanoid.CameraOffset - lastOffset + total
	lastOffset = total
end

-- ===== EFFECT PARTS =====
-- The muzzle world CFrame of a given character's held weapon (a "Muzzle" attachment if present, else the
-- front of the Handle).
local function muzzleCFrameOf(character: Model?): CFrame?
	local held = character and character:FindFirstChild("HeldWeapon")
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
-- Local shot: instant muzzle flash (the tracer is drawn from the authoritative ShotFired below, so it
-- always goes to the exact zombie the server hit).
local function onLocalFired(weaponId: string)
	addShake(weaponId) -- screen shake + camera kick, scaled per weapon
	local muzzleCF = muzzleCFrameOf(localPlayer.Character)
	if muzzleCF then
		muzzleFlash(muzzleCF)
	end
end

-- Every shot (incl. our own): draw the bullet tracer from the shooter's gun muzzle to where it landed.
local function onShotFired(shooterUserId: number, origin: Vector3, endpoint: Vector3)
	local shooter = Players:GetPlayerByUserId(shooterUserId)
	local muzzleCF = muzzleCFrameOf(shooter and shooter.Character)
	local from = muzzleCF and muzzleCF.Position or origin
	if shooterUserId ~= localPlayer.UserId and muzzleCF then
		muzzleFlash(muzzleCF) -- others' muzzle flash (the local player already flashed on fire)
	end
	drawTracer(from, endpoint)
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

	RunService.RenderStepped:Connect(updateShake) -- decays trauma + applies the camera shake/kick each frame

	print("[CombatFeedbackController] started")
end

return CombatFeedbackController
