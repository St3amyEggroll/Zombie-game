--!nonstrict
-- WorldVFXController.lua — client renderer for the server's WorldVFX remote. The server can't Emit()
-- particles (method calls don't replicate), so it just announces ("boom", {pos=..., r=...}) and every
-- client renders the effect locally from POOLED emitter rigs (one invisible part + emitters per effect,
-- repositioned per call — emitted particles live in world space, so bursts layer and trail naturally).
-- All textures are engine built-ins: zero uploads. Distance-culled; short-lived tween parts only for
-- shockwave rings / core flashes.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)

local WorldVFXController = {}

-- ===== TUNABLES =====
local CULL_DISTANCE = 260 -- effects farther than this from the camera aren't rendered at all
local TX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

local fxFolder
local rigs = {} -- kind -> { part, emitters... }

local function mkRigPart(name: string): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.Parent = fxFolder
	return p
end

local function mkEmitter(parent, props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.LightInfluence = 0
	for k, v in props do
		e[k] = v
	end
	e.Parent = parent
	return e
end

local function seq(...)
	local pts, args = {}, { ... }
	for i = 1, #args, 2 do
		table.insert(pts, NumberSequenceKeypoint.new(args[i], args[i + 1]))
	end
	return NumberSequence.new(pts)
end

-- ===== RIG BUILDERS (lazy — built on first use) =====

local function boomRig()
	local r = rigs.boom
	if r then
		return r
	end
	local part = mkRigPart("VFX_Boom")
	r = {
		part = part,
		fire = mkEmitter(part, {
			Texture = TX_FIRE, Speed = NumberRange.new(18, 34), Lifetime = NumberRange.new(0.3, 0.6),
			SpreadAngle = Vector2.new(180, 180), Drag = 3, LightEmission = 1,
			Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-90, 90),
			Size = seq(0, 2.4, 0.5, 4.6, 1, 5.6), Transparency = seq(0, 0.05, 0.75, 0.35, 1, 1),
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 170)),
				ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 150, 40)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 30, 8)),
			}),
		}),
		smoke = mkEmitter(part, {
			Texture = TX_SMOKE, Speed = NumberRange.new(8, 16), Lifetime = NumberRange.new(0.9, 1.6),
			SpreadAngle = Vector2.new(180, 180), Drag = 1.5, Acceleration = Vector3.new(0, 6, 0),
			Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-30, 30),
			Size = seq(0, 3, 1, 7), Transparency = seq(0, 0.45, 1, 1),
			Color = ColorSequence.new(Color3.fromRGB(70, 62, 55), Color3.fromRGB(30, 28, 25)),
		}),
		sparks = mkEmitter(part, {
			Texture = TX_SPARK, Speed = NumberRange.new(40, 75), Lifetime = NumberRange.new(0.35, 0.7),
			SpreadAngle = Vector2.new(180, 180), Drag = 2, Acceleration = Vector3.new(0, -60, 0),
			LightEmission = 1, Size = seq(0, 0.5, 1, 0.1),
			Color = ColorSequence.new(Color3.fromRGB(255, 210, 110), Color3.fromRGB(255, 110, 30)),
		}),
	}
	rigs.boom = r
	return r
end

local function frostRig()
	local r = rigs.frost
	if r then
		return r
	end
	local part = mkRigPart("VFX_Frost")
	r = {
		part = part,
		shards = mkEmitter(part, {
			Texture = TX_SPARK, Speed = NumberRange.new(24, 45), Lifetime = NumberRange.new(0.35, 0.7),
			SpreadAngle = Vector2.new(180, 180), Drag = 2, Acceleration = Vector3.new(0, -50, 0),
			LightEmission = 0.8, Size = seq(0, 0.7, 1, 0.1),
			Color = ColorSequence.new(Color3.fromRGB(210, 245, 255), Color3.fromRGB(110, 190, 235)),
		}),
		mist = mkEmitter(part, {
			Texture = TX_SMOKE, Speed = NumberRange.new(6, 12), Lifetime = NumberRange.new(0.7, 1.2),
			SpreadAngle = Vector2.new(180, 180), Drag = 2, Acceleration = Vector3.new(0, -4, 0),
			Size = seq(0, 2.2, 1, 4.4), Transparency = seq(0, 0.5, 1, 1),
			Color = ColorSequence.new(Color3.fromRGB(200, 235, 250), Color3.fromRGB(150, 200, 230)),
		}),
	}
	rigs.frost = r
	return r
end

local function puffRig() -- shared dirt/water/dust burst (recolored per call)
	local r = rigs.puff
	if r then
		return r
	end
	local part = mkRigPart("VFX_Puff")
	r = {
		part = part,
		puff = mkEmitter(part, {
			Texture = TX_SMOKE, Speed = NumberRange.new(10, 22), Lifetime = NumberRange.new(0.5, 0.9),
			SpreadAngle = Vector2.new(70, 70), Drag = 2, EmissionDirection = Enum.NormalId.Top,
			Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-60, 60),
			Size = seq(0, 1.6, 1, 3.6), Transparency = seq(0, 0.35, 1, 1),
		}),
		bits = mkEmitter(part, {
			Texture = TX_SPARK, Speed = NumberRange.new(16, 34), Lifetime = NumberRange.new(0.35, 0.6),
			SpreadAngle = Vector2.new(60, 60), Drag = 1, EmissionDirection = Enum.NormalId.Top,
			Acceleration = Vector3.new(0, -70, 0), Size = seq(0, 0.35, 1, 0.05),
		}),
	}
	rigs.puff = r
	return r
end

local function goreRig()
	local r = rigs.gore
	if r then
		return r
	end
	local part = mkRigPart("VFX_Gore")
	r = {
		part = part,
		goo = mkEmitter(part, {
			Texture = TX_SMOKE, Speed = NumberRange.new(9, 20), Lifetime = NumberRange.new(0.4, 0.8),
			SpreadAngle = Vector2.new(180, 180), Drag = 1.5, Acceleration = Vector3.new(0, -30, 0),
			Rotation = NumberRange.new(0, 360),
			Size = seq(0, 1.3, 1, 2.8), Transparency = seq(0, 0.25, 1, 1),
			Color = ColorSequence.new(Color3.fromRGB(110, 175, 45), Color3.fromRGB(58, 96, 26)),
		}),
		drops = mkEmitter(part, {
			Texture = TX_SPARK, Speed = NumberRange.new(18, 38), Lifetime = NumberRange.new(0.3, 0.55),
			SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, -80, 0),
			Size = seq(0, 0.4, 1, 0.08),
			Color = ColorSequence.new(Color3.fromRGB(140, 210, 60), Color3.fromRGB(80, 130, 30)),
		}),
	}
	rigs.gore = r
	return r
end

local function coinRig()
	local r = rigs.coins
	if r then
		return r
	end
	local part = mkRigPart("VFX_Coins")
	r = {
		part = part,
		sparkle = mkEmitter(part, {
			Texture = TX_SPARK, Speed = NumberRange.new(22, 40), Lifetime = NumberRange.new(0.6, 1),
			SpreadAngle = Vector2.new(55, 55), Drag = 1, EmissionDirection = Enum.NormalId.Top,
			Acceleration = Vector3.new(0, -50, 0), LightEmission = 1,
			Size = seq(0, 0.6, 1, 0.12),
			Color = ColorSequence.new(Color3.fromRGB(255, 226, 120), Color3.fromRGB(230, 170, 40)),
		}),
	}
	rigs.coins = r
	return r
end

-- Ring + core flash for booms (short-lived tween parts — the only non-particle pieces).
local function boomExtras(pos: Vector3, radius: number)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 190, 90)
	ring.Transparency = 0.35
	ring.Size = Vector3.new(0.3, 2, 2)
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = fxFolder
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, radius * 2.6, radius * 2.6),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.5)

	-- NEW (VFX revamp): the detonation reads as a real explosion instead of one ring.
	-- 1) A hard WHITE FLASH ball — the first two frames of any big blast are pure white.
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 252, 236)
	flash.Transparency = 0.05
	flash.Size = Vector3.new(radius * 0.5, radius * 0.5, radius * 0.5)
	flash.CFrame = CFrame.new(pos)
	flash.Parent = fxFolder
	TweenService:Create(flash, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 1.5, radius * 1.5, radius * 1.5),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.2)

	-- 2) The FIREBALL swelling out behind the flash — slower, orange, so you can read the real radius.
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = Color3.fromRGB(255, 146, 48)
	ball.Transparency = 0.25
	ball.Size = Vector3.new(radius * 0.35, radius * 0.35, radius * 0.35)
	ball.CFrame = CFrame.new(pos)
	ball.Parent = fxFolder
	TweenService:Create(ball, TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 1.9, radius * 1.9, radius * 1.9),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 0.5)

	-- 3) A SCORCH disc on the deck: the blast leaves a mark that lingers and fades, so the damage
	--    footprint is legible after the fire clears.
	local scorch = Instance.new("Part")
	scorch.Shape = Enum.PartType.Cylinder
	scorch.Anchored = true
	scorch.CanCollide = false
	scorch.CanQuery = false
	scorch.CanTouch = false
	scorch.CastShadow = false
	scorch.Material = Enum.Material.Slate
	scorch.Color = Color3.fromRGB(26, 22, 18)
	scorch.Transparency = 0.25
	scorch.Size = Vector3.new(0.2, radius * 1.7, radius * 1.7)
	scorch.CFrame = CFrame.new(pos - Vector3.new(0, 2.4, 0)) * CFrame.Angles(0, 0, math.rad(90))
	scorch.Parent = fxFolder
	TweenService:Create(scorch, TweenInfo.new(1.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 }):Play()
	Debris:AddItem(scorch, 1.9)

	-- 4) DEBRIS thrown outward — a handful of chunks arcing away and fading. Cheap (anchored, tweened,
	--    no physics) and it's what sells the force.
	local CHUNKS = 8
	for i = 1, CHUNKS do
		local ang = (math.pi * 2) * (i / CHUNKS) + math.random() * 0.5
		local out = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local chunk = Instance.new("Part")
		chunk.Anchored = true
		chunk.CanCollide = false
		chunk.CanQuery = false
		chunk.CanTouch = false
		chunk.CastShadow = false
		chunk.Material = Enum.Material.Slate
		chunk.Color = Color3.fromRGB(58, 50, 42)
		local s = 0.35 + math.random() * 0.5
		chunk.Size = Vector3.new(s, s, s)
		chunk.CFrame = CFrame.new(pos) * CFrame.Angles(math.random() * 6, math.random() * 6, 0)
		chunk.Parent = fxFolder
		local land = pos + out * (radius * (0.7 + math.random() * 0.6)) - Vector3.new(0, 2, 0)
		TweenService:Create(chunk, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(land) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
			Transparency = 1,
		}):Play()
		Debris:AddItem(chunk, 0.6)
	end

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 70)
	light.Range = math.min(40, radius * 3)
	light.Brightness = 3
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new(pos)
	holder.Parent = fxFolder
	light.Parent = holder
	TweenService:Create(light, TweenInfo.new(0.35), { Brightness = 0 }):Play()
	Debris:AddItem(holder, 0.4)
end

-- ===== THE HANDLER =====
local function handle(kind: string, p)
	p = typeof(p) == "table" and p or {}
	local cam = Workspace.CurrentCamera
	local pos = typeof(p.pos) == "Vector3" and p.pos or nil
	if pos and cam and (cam.CFrame.Position - pos).Magnitude > CULL_DISTANCE then
		return
	end
	if kind == "boom" and pos then
		local radius = math.clamp(tonumber(p.r) or 10, 4, 30)
		local r = boomRig()
		r.part.CFrame = CFrame.new(pos)
		r.fire:Emit(math.floor(8 + radius))
		r.smoke:Emit(math.floor(4 + radius * 0.5))
		r.sparks:Emit(math.floor(6 + radius * 0.8))
		boomExtras(pos, radius)
	elseif kind == "shatter" and pos then
		local r = frostRig()
		r.part.CFrame = CFrame.new(pos)
		r.shards:Emit(16)
		r.mist:Emit(7)
	elseif kind == "dig" and pos then
		local r = puffRig()
		r.part.CFrame = CFrame.new(pos)
		r.puff.Color = ColorSequence.new(Color3.fromRGB(110, 86, 56), Color3.fromRGB(64, 50, 34))
		r.bits.Color = ColorSequence.new(Color3.fromRGB(120, 95, 60))
		r.puff:Emit(7)
		r.bits:Emit(8)
	elseif kind == "splash" and pos then
		local r = puffRig()
		r.part.CFrame = CFrame.new(pos)
		r.puff.Color = ColorSequence.new(Color3.fromRGB(200, 230, 245), Color3.fromRGB(120, 170, 210))
		r.bits.Color = ColorSequence.new(Color3.fromRGB(225, 245, 255))
		r.puff:Emit(8)
		r.bits:Emit(10)
	elseif kind == "dust" and pos then
		local r = puffRig()
		r.part.CFrame = CFrame.new(pos)
		r.puff.Color = ColorSequence.new(Color3.fromRGB(150, 132, 96), Color3.fromRGB(90, 80, 60))
		r.bits.Color = ColorSequence.new(Color3.fromRGB(160, 140, 100))
		r.puff:Emit(10)
		r.bits:Emit(6)
	elseif kind == "coins" and pos then
		local r = coinRig()
		r.part.CFrame = CFrame.new(pos)
		r.sparkle:Emit(24)
	elseif kind == "gore" and pos then
		local r = goreRig()
		r.part.CFrame = CFrame.new(pos)
		local big = p.big == true
		r.goo:Emit(big and 12 or 6)
		r.drops:Emit(big and 14 or 7)
	elseif kind == "bossgore" and pos then
		local r = goreRig()
		r.part.CFrame = CFrame.new(pos)
		r.goo:Emit(26)
		r.drops:Emit(30)
		boomExtras(pos, 12)
	elseif kind == "trail" and typeof(p.part) == "Instance" and p.part:IsA("BasePart") then
		-- Rate-driven trail riding a replicated server part (meteor rocks): dies with the part.
		if not p.part:FindFirstChild("VFXTrailFire") then
			local tf = Instance.new("ParticleEmitter")
			tf.Name = "VFXTrailFire"
			tf.Texture = TX_FIRE
			tf.Rate = 24
			tf.Speed = NumberRange.new(2, 5)
			tf.Lifetime = NumberRange.new(0.3, 0.55)
			tf.SpreadAngle = Vector2.new(30, 30)
			tf.LightEmission = 1
			tf.LightInfluence = 0
			tf.Size = seq(0, 1.8, 1, 3.4)
			tf.Transparency = seq(0, 0.1, 1, 1)
			tf.Color = ColorSequence.new(Color3.fromRGB(255, 200, 90), Color3.fromRGB(160, 40, 10))
			tf.Parent = p.part
			local ts = Instance.new("ParticleEmitter")
			ts.Name = "VFXTrailSmoke"
			ts.Texture = TX_SMOKE
			ts.Rate = 12
			ts.Speed = NumberRange.new(1, 3)
			ts.Lifetime = NumberRange.new(0.7, 1.2)
			ts.LightInfluence = 0
			ts.Size = seq(0, 2, 1, 4.5)
			ts.Transparency = seq(0, 0.5, 1, 1)
			ts.Color = ColorSequence.new(Color3.fromRGB(60, 55, 50))
			ts.Parent = p.part
		end
	end
end

function WorldVFXController.Start()
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "WorldVFX"
	fxFolder.Parent = Workspace.CurrentCamera -- local-only: never replicates back
	Remotes.Get("WorldVFX").OnClientEvent:Connect(handle)
	print("[WorldVFXController] started (client-side world particles)")
end

return WorldVFXController
