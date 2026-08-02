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

-- ===== LIGHTNING BOLT (owner-approved rework) =====
-- Was a single straight neon rectangle — it read as a glowing pole, not lightning. Now: a JAGGED
-- multi-segment strike with forking branches, a white screen-flash, a ground burst that throws sparks,
-- a lingering scorch, and two fainter after-strikes. Drawn per-client (the server only says where), so
-- a dozen segments per strike costs zero replication.
local BOLT_TOP = 110      -- studs above the impact the bolt starts
local BOLT_SEGS = 9       -- segments per strike (more = more jagged)
local BOLT_JITTER = 7     -- studs of sideways wander per segment

-- One glowing segment between two points.
local function boltSegment(a: Vector3, b: Vector3, width: number, color: Color3, life: number)
	local d = (b - a).Magnitude
	if d < 0.05 then
		return
	end
	local seg = Instance.new("Part")
	seg.Anchored = true
	seg.CanCollide = false
	seg.CanQuery = false
	seg.CanTouch = false
	seg.CastShadow = false
	seg.Material = Enum.Material.Neon
	seg.Color = color
	seg.Transparency = 0.05
	seg.Size = Vector3.new(width, width, d)
	seg.CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -d * 0.5)
	seg.Parent = fxFolder
	TweenService:Create(seg, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 }):Play()
	Debris:AddItem(seg, life + 0.05)
end

-- A jagged path from `top` down to `ground`, drawn as segments; returns the points so branches can
-- fork off it.
local function drawBolt(ground: Vector3, top: Vector3, width: number, color: Color3, life: number)
	local pts = { top }
	for i = 1, BOLT_SEGS - 1 do
		local f = i / BOLT_SEGS
		local mid = top:Lerp(ground, f)
		pts[#pts + 1] = mid + Vector3.new(
			(math.random() - 0.5) * BOLT_JITTER * 2,
			0,
			(math.random() - 0.5) * BOLT_JITTER * 2)
	end
	pts[#pts + 1] = ground
	for i = 1, #pts - 1 do
		boltSegment(pts[i], pts[i + 1], width, color, life)
	end
	return pts
end

local function lightningStrike(ground: Vector3, radius: number)
	local COL = Color3.fromRGB(226, 246, 255)
	local top = ground + Vector3.new((math.random() - 0.5) * 20, BOLT_TOP, (math.random() - 0.5) * 20)

	-- The main strike: a wide soft core + a thin white filament down the same path.
	local pts = drawBolt(ground, top, 1.5, Color3.fromRGB(150, 215, 255), 0.34)
	for i = 1, #pts - 1 do
		boltSegment(pts[i], pts[i + 1], 0.45, COL, 0.3)
	end

	-- 2 forks peeling off mid-air and dying in the sky.
	for _ = 1, 2 do
		local from = pts[math.random(2, math.max(2, #pts - 3))]
		local away = from + Vector3.new((math.random() - 0.5) * 46, -math.random(8, 20), (math.random() - 0.5) * 46)
		local bp = { from }
		for i = 1, 3 do
			bp[#bp + 1] = from:Lerp(away, i / 3) + Vector3.new((math.random() - 0.5) * 6, 0, (math.random() - 0.5) * 6)
		end
		for i = 1, #bp - 1 do
			boltSegment(bp[i], bp[i + 1], 0.32, COL, 0.24)
		end
	end

	-- The white flash: a big soft ball at the impact, gone in a few frames.
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(240, 250, 255)
	flash.Transparency = 0.1
	flash.Size = Vector3.new(radius, radius, radius)
	flash.CFrame = CFrame.new(ground)
	flash.Parent = fxFolder
	local fl = Instance.new("PointLight")
	fl.Color = Color3.fromRGB(190, 230, 255)
	fl.Range = 46
	fl.Brightness = 6
	fl.Parent = flash
	TweenService:Create(flash, TweenInfo.new(0.18), {
		Size = Vector3.new(radius * 2.2, radius * 2.2, radius * 2.2),
		Transparency = 1,
	}):Play()
	TweenService:Create(fl, TweenInfo.new(0.18), { Brightness = 0 }):Play()
	Debris:AddItem(flash, 0.24)

	-- Ground burst ring + a scorch that lingers.
	boomExtras(ground, radius * 0.75)

	-- Sparks thrown off the impact.
	for i = 1, 12 do
		local ang = (math.pi * 2) * (i / 12) + math.random() * 0.5
		local out = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local sp = Instance.new("Part")
		sp.Anchored = true
		sp.CanCollide = false
		sp.CanQuery = false
		sp.CanTouch = false
		sp.CastShadow = false
		sp.Material = Enum.Material.Neon
		sp.Color = COL
		sp.Size = Vector3.new(0.14, 0.14, 1.1)
		sp.CFrame = CFrame.new(ground)
		sp.Parent = fxFolder
		local land = ground + out * (radius * (0.7 + math.random() * 0.7)) + Vector3.new(0, math.random() * 3, 0)
		TweenService:Create(sp, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.lookAt(land, land + out),
			Transparency = 1,
		}):Play()
		Debris:AddItem(sp, 0.34)
	end

	-- AFTER-STRIKES: real lightning flickers. Two fainter bolts down a slightly different path.
	task.delay(0.13, function()
		drawBolt(ground, top + Vector3.new(6, 0, -4), 0.7, COL, 0.2)
	end)
	task.delay(0.26, function()
		drawBolt(ground, top + Vector3.new(-7, 0, 5), 0.5, COL, 0.16)
	end)
end

-- ===== ACID PUDDLE LIFE (owner-approved rework) =====
-- The server owns the puddle disc + its damage; this adds the things that make it read as CAUSTIC:
-- a splash burst on landing, blobs that rise and pop on the surface, and green vapour drifting up.
-- Client-side so a wave full of puddles costs no replication.
local function acidPuddle(pos: Vector3, radius: number, secs: number)
	-- The landing splash: droplets thrown out of the impact.
	for i = 1, 10 do
		local ang = (math.pi * 2) * (i / 10) + math.random() * 0.6
		local out = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local d = Instance.new("Part")
		d.Shape = Enum.PartType.Ball
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.CastShadow = false
		d.Material = Enum.Material.Neon
		d.Color = Color3.fromRGB(141, 255, 94)
		d.Size = Vector3.new(0.5, 0.5, 0.5)
		d.CFrame = CFrame.new(pos + Vector3.new(0, 0.5, 0))
		d.Parent = fxFolder
		local land = pos + out * (radius * (0.5 + math.random() * 0.8))
		TweenService:Create(d, TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(land),
			Size = Vector3.new(0.1, 0.1, 0.1),
			Transparency = 1,
		}):Play()
		Debris:AddItem(d, 0.4)
	end

	-- BUBBLES + VAPOUR for the puddle's life. One loop, tapering off as the puddle dies so the visual
	-- agrees with the server's shrink.
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < secs do
			local left = secs - (os.clock() - t0)
			local health = math.clamp(left / math.max(0.001, secs), 0, 1)
			local rr = radius * (0.45 + 0.55 * math.min(1, left / 2))
			-- a bubble swelling on the surface, then popping
			local ang = math.random() * math.pi * 2
			local at = pos + Vector3.new(math.cos(ang), 0, math.sin(ang)) * (math.random() * rr * 0.85)
			local b = Instance.new("Part")
			b.Shape = Enum.PartType.Ball
			b.Anchored = true
			b.CanCollide = false
			b.CanQuery = false
			b.CanTouch = false
			b.CastShadow = false
			b.Material = Enum.Material.Neon
			b.Color = Color3.fromRGB(176, 255, 130)
			b.Transparency = 0.25
			b.Size = Vector3.new(0.2, 0.2, 0.2)
			b.CFrame = CFrame.new(at + Vector3.new(0, 0.2, 0))
			b.Parent = fxFolder
			local big = 0.7 + math.random() * 0.9
			TweenService:Create(b, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(big, big, big),
				Transparency = 1,
			}):Play()
			Debris:AddItem(b, 0.45)
			-- vapour drifting off the surface
			if math.random() < 0.6 then
				local v = Instance.new("Part")
				v.Shape = Enum.PartType.Ball
				v.Anchored = true
				v.CanCollide = false
				v.CanQuery = false
				v.CanTouch = false
				v.CastShadow = false
				v.Material = Enum.Material.SmoothPlastic
				v.Color = Color3.fromRGB(150, 230, 110)
				v.Transparency = 0.72
				v.Size = Vector3.new(1.2, 1.2, 1.2)
				v.CFrame = CFrame.new(at)
				v.Parent = fxFolder
				TweenService:Create(v, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					CFrame = CFrame.new(at + Vector3.new((math.random() - 0.5) * 3, 4.5, (math.random() - 0.5) * 3)),
					Size = Vector3.new(3, 3, 3),
					Transparency = 1,
				}):Play()
				Debris:AddItem(v, 1.2)
			end
			task.wait(0.16 + (1 - health) * 0.25) -- bubbling calms as the puddle dies
		end
	end)
end

-- ===== THE HANDLER =====
local function handle(kind: string, p)
	p = typeof(p) == "table" and p or {}
	local cam = Workspace.CurrentCamera
	local pos = typeof(p.pos) == "Vector3" and p.pos or nil
	if pos and cam and (cam.CFrame.Position - pos).Magnitude > CULL_DISTANCE then
		return
	end
	if kind == "bolt" and pos then
		lightningStrike(pos, math.clamp(tonumber(p.r) or 10, 4, 30))
		return
	end
	if kind == "acid" and pos then
		acidPuddle(pos, math.clamp(tonumber(p.r) or 6, 2, 20), math.clamp(tonumber(p.secs) or 8, 1, 30))
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
