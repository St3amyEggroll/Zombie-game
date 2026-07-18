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

-- One-off screen shake for events (boss entrances etc.) — same Perlin rumble as gunfire, custom strength.
function CombatFeedbackController.ShakeOnce(magnitude: number, duration: number, frequency: number?, kick: number?)
	shakeElapsed = 0
	shakeDuration = math.max(duration or 0.4, 0)
	shakeMagnitude = math.max(magnitude or 0.8, 0)
	shakeFrequency = math.max(frequency or 18, 1)
	shakeSeed = (shakeSeed + 7.13) % 1000
	kickUp = math.min(2, kickUp + (kick or 0))
end

local function addShake(weaponId: string)
	local cfg = AnimationConfig.Shake
	if not cfg.Enabled or localPlayer:GetAttribute("ShakeOff") == true then
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
-- Where the bullet + muzzle flash come from. EXACT BARREL: add an Attachment named "Muzzle" to the gun
-- model, positioned at the tip of the barrel — both the tracer and the flash spawn there. Without one we
-- fall back to the gun's Handle (its center, in-hand) — NOT a forward projection, which on a big or
-- rotated gun threw the origin way out in front ("starts really far away"). Last resort: the right hand.
local function gunMuzzleCF(character: Model?): CFrame?
	local held = character and character:FindFirstChild("HeldWeapon")
	if held then
		local muzzle = held:FindFirstChild("Muzzle", true)
		if muzzle and muzzle:IsA("Attachment") then
			return muzzle.WorldCFrame
		end
		local handle = held:FindFirstChild("Handle") or held.PrimaryPart
		if handle and handle:IsA("BasePart") then
			return handle.CFrame
		end
	end
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	if hand and hand:IsA("BasePart") then
		return hand.CFrame
	end
	return nil
end

local function tracerCfgFor(weaponId: string?)
	local t = AnimationConfig.Tracer
	return (weaponId and t.PerWeapon[weaponId]) or t.Default
end

local function projectileCfgFor(weaponId: string?)
	local p = AnimationConfig.Projectile
	return (weaponId and p.PerWeapon[weaponId]) or p.Default
end

-- ===== MOVING PROJECTILE ===== a small neon bolt (with a trailing streak) that actually FLIES from the gun
-- barrel to where the shot landed, at cfg.Speed studs/sec, then fades. Updated every frame from `activeBolts`
-- (one Heartbeat connection for all bolts — cheap even with a horde firing). No dynamic light.
local activeBolts: { any } = {}

-- FLAMETHROWER: a REAL particle flame jet (the engine's own fire textures — no spheres). One pooled
-- invisible emitter part per client: each shot aims it down the barrel line and bursts fire + embers;
-- emitted particles live in world space, so back-to-back shots layer into a continuous rolling cone.
local jetPart, jetFire, jetEmber
local function ensureJet()
	if jetPart and jetPart.Parent then
		return
	end
	jetPart = Instance.new("Part")
	jetPart.Name = "FlameJet"
	jetPart.Anchored = true
	jetPart.CanCollide = false
	jetPart.CanQuery = false
	jetPart.CanTouch = false
	jetPart.Transparency = 1
	jetPart.Size = Vector3.new(0.6, 0.6, 0.6)
	jetPart.Parent = fxFolder

	jetFire = Instance.new("ParticleEmitter")
	jetFire.Texture = "rbxasset://textures/particles/fire_main.dds" -- the engine Fire look
	jetFire.EmissionDirection = Enum.NormalId.Front -- we aim the part's -Z down the shot line
	jetFire.Rate = 0 -- burst-only via :Emit()
	jetFire.Speed = NumberRange.new(55, 80)
	jetFire.Lifetime = NumberRange.new(0.28, 0.5)
	jetFire.Drag = 2.5 -- roars out fast, licks and slows at the tip
	jetFire.SpreadAngle = Vector2.new(7, 7)
	jetFire.Rotation = NumberRange.new(0, 360)
	jetFire.RotSpeed = NumberRange.new(-140, 140)
	jetFire.LightEmission = 1
	jetFire.LightInfluence = 0
	jetFire.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(0.45, 3.0),
		NumberSequenceKeypoint.new(1, 4.2),
	})
	jetFire.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.08),
		NumberSequenceKeypoint.new(0.7, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	jetFire.Color = ColorSequence.new({ -- white-hot core -> orange -> ember red as it flies
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 180)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 160, 40)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 34, 8)),
	})
	jetFire.Parent = jetPart

	jetEmber = Instance.new("ParticleEmitter") -- stray sparks tumbling off the stream
	jetEmber.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	jetEmber.EmissionDirection = Enum.NormalId.Front
	jetEmber.Rate = 0
	jetEmber.Speed = NumberRange.new(35, 70)
	jetEmber.Lifetime = NumberRange.new(0.4, 0.8)
	jetEmber.Drag = 1.5
	jetEmber.SpreadAngle = Vector2.new(14, 14)
	jetEmber.Acceleration = Vector3.new(0, 14, 0) -- embers drift upward as they die
	jetEmber.LightEmission = 1
	jetEmber.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	jetEmber.Color = ColorSequence.new(Color3.fromRGB(255, 190, 70), Color3.fromRGB(200, 60, 10))
	jetEmber.Parent = jetPart
end

local function spawnFlames(from: Vector3, to: Vector3)
	local delta = to - from
	if delta.Magnitude < 1 or delta.Magnitude ~= delta.Magnitude then
		return
	end
	ensureJet()
	jetPart.CFrame = CFrame.lookAt(from + delta.Unit * 1.5, to) -- start just past the barrel
	jetFire:Emit(9)
	jetEmber:Emit(3)
end

-- FREEZE RAY: the flamethrower's icy twin — a cold mist cone that sinks instead of rising, glittering
-- frost crystals in the stream, and a frost pop at whatever it touches.
local frostPart, frostMist, frostSpark
local function ensureFrost()
	if frostPart and frostPart.Parent then
		return
	end
	frostPart = Instance.new("Part")
	frostPart.Name = "FrostJet"
	frostPart.Anchored = true
	frostPart.CanCollide = false
	frostPart.CanQuery = false
	frostPart.CanTouch = false
	frostPart.Transparency = 1
	frostPart.Size = Vector3.new(0.6, 0.6, 0.6)
	frostPart.Parent = fxFolder
	frostMist = Instance.new("ParticleEmitter")
	frostMist.Texture = "rbxasset://textures/particles/smoke_main.dds"
	frostMist.EmissionDirection = Enum.NormalId.Front
	frostMist.Rate = 0
	frostMist.Speed = NumberRange.new(60, 85)
	frostMist.Lifetime = NumberRange.new(0.3, 0.5)
	frostMist.Drag = 3
	frostMist.SpreadAngle = Vector2.new(6, 6)
	frostMist.Acceleration = Vector3.new(0, -12, 0) -- cold sinks
	frostMist.LightEmission = 0.35
	frostMist.LightInfluence = 0
	frostMist.Rotation = NumberRange.new(0, 360)
	frostMist.RotSpeed = NumberRange.new(-60, 60)
	frostMist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.5, 2.4),
		NumberSequenceKeypoint.new(1, 3.4),
	})
	frostMist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(0.75, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	frostMist.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(235, 250, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 215, 245)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 160, 210)),
	})
	frostMist.Parent = frostPart
	frostSpark = Instance.new("ParticleEmitter")
	frostSpark.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	frostSpark.EmissionDirection = Enum.NormalId.Front
	frostSpark.Rate = 0
	frostSpark.Speed = NumberRange.new(50, 80)
	frostSpark.Lifetime = NumberRange.new(0.3, 0.55)
	frostSpark.Drag = 2.5
	frostSpark.SpreadAngle = Vector2.new(9, 9)
	frostSpark.LightEmission = 1
	frostSpark.LightInfluence = 0
	frostSpark.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0.08),
	})
	frostSpark.Color = ColorSequence.new(Color3.fromRGB(220, 245, 255), Color3.fromRGB(130, 200, 240))
	frostSpark.Parent = frostPart
end

local function spawnFrostJet(from: Vector3, to: Vector3)
	local delta = to - from
	if delta.Magnitude < 1 or delta.Magnitude ~= delta.Magnitude then
		return
	end
	ensureFrost()
	frostPart.CFrame = CFrame.lookAt(from + delta.Unit * 1.5, to)
	frostMist:Emit(7)
	frostSpark:Emit(4)
end

-- WEAPON IMPACT POPS (plasma splash / ray-gun pop / crossbow splinters): one pooled sparkle emitter,
-- recolored per weapon, burst at the bolt's landing point. Plasma adds an expanding ion ring.
local popPart, popEmit
local function impactPop(pos: Vector3, weaponId: string)
	if not popPart or not popPart.Parent then
		popPart = Instance.new("Part")
		popPart.Name = "ImpactPop"
		popPart.Anchored = true
		popPart.CanCollide = false
		popPart.CanQuery = false
		popPart.CanTouch = false
		popPart.Transparency = 1
		popPart.Size = Vector3.new(0.6, 0.6, 0.6)
		popPart.Parent = fxFolder
		popEmit = Instance.new("ParticleEmitter")
		popEmit.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		popEmit.Rate = 0
		popEmit.Speed = NumberRange.new(14, 30)
		popEmit.Lifetime = NumberRange.new(0.25, 0.5)
		popEmit.SpreadAngle = Vector2.new(180, 180)
		popEmit.Drag = 2
		popEmit.LightEmission = 1
		popEmit.LightInfluence = 0
		popEmit.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 0.08),
		})
		popEmit.Parent = popPart
	end
	popPart.CFrame = CFrame.new(pos)
	if weaponId == "plasma" then
		popEmit.Color = ColorSequence.new(Color3.fromRGB(140, 235, 255), Color3.fromRGB(40, 150, 220))
		popEmit.Acceleration = Vector3.new(0, 0, 0)
		popEmit:Emit(12)
		local ring = Instance.new("Part") -- the ionized shock ring
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = Color3.fromRGB(90, 200, 255)
		ring.Transparency = 0.3
		ring.Size = Vector3.new(0.2, 1, 1)
		ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = fxFolder
		TweenService:Create(ring, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.1, 9, 9), Transparency = 1 }):Play()
		Debris:AddItem(ring, 0.35)
	elseif weaponId == "raygun" then
		popEmit.Color = ColorSequence.new(Color3.fromRGB(170, 255, 120), Color3.fromRGB(60, 200, 60))
		popEmit.Acceleration = Vector3.new(0, 8, 0) -- the sickly energy floats
		popEmit:Emit(14)
	elseif weaponId == "crossbow" then
		popEmit.Color = ColorSequence.new(Color3.fromRGB(150, 118, 70), Color3.fromRGB(92, 70, 42))
		popEmit.Acceleration = Vector3.new(0, -70, 0) -- splinters fall
		popEmit:Emit(9)
	end
end

local function spawnProjectile(from: Vector3, to: Vector3, weaponId: string?)
	if weaponId == "flamethrower" then
		return spawnFlames(from, to) -- fire is not a bullet
	end
	if weaponId == "freezeray" then
		return spawnFrostJet(from, to) -- cold is not a bullet either
	end
	if not AnimationConfig.Projectile.Enabled then
		-- Fallback to the legacy instant line if projectiles are disabled.
		if AnimationConfig.Tracer.Enabled then
			local cfg = tracerCfgFor(weaponId)
			local d = (to - from).Magnitude
			if d < 1 or d ~= d then return end
			local beam = Instance.new("Part")
			beam.Anchored = true; beam.CanCollide = false; beam.CanQuery = false; beam.CanTouch = false
			beam.CastShadow = false; beam.Material = Enum.Material.Neon; beam.Color = cfg.Color
			beam.Transparency = 0.1; beam.Size = Vector3.new(cfg.Width, cfg.Width, d)
			beam.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -d * 0.5)
			beam.Parent = fxFolder
			TweenService:Create(beam, TweenInfo.new(cfg.Life), { Transparency = 1 }):Play()
			Debris:AddItem(beam, cfg.Life + 0.05)
		end
		return
	end

	local cfg = projectileCfgFor(weaponId)
	if #activeBolts >= 40 then
		return -- FX budget: minigun spam + a full party can't flood the client with parts/trails
	end
	local delta = to - from
	local dist = delta.Magnitude
	if dist < 0.5 or dist ~= dist then
		return
	end
	local dir = delta.Unit

	-- THIN BOLT: a skinny streak. Neon laser by default; cfg.Material makes it a solid physical
	-- projectile instead (the crossbow's wooden shaft).
	local isSolid = cfg.Material ~= nil and cfg.Material ~= "Neon"
	local bolt = Instance.new("Part")
	bolt.Anchored = true
	bolt.CanCollide = false
	bolt.CanQuery = false
	bolt.CanTouch = false
	bolt.CastShadow = false
	bolt.Material = Enum.Material[cfg.Material or "Neon"]
	bolt.Color = cfg.Color
	bolt.Size = Vector3.new(cfg.Width, cfg.Width, math.min(cfg.Length, dist))
	bolt.CFrame = CFrame.lookAt(from, from + dir)

	-- Short fading tail. The trail's ribbon width = the distance between its two attachments, so they
	-- sit across the bolt's THICKNESS (not its length — that made a 2-3 stud wide ribbon, the old
	-- "super thick" look). Result: a tail exactly as skinny as the bolt.
	local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(0, cfg.Width * 0.5, 0); a0.Parent = bolt
	local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0, -cfg.Width * 0.5, 0); a1.Parent = bolt
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(cfg.Color)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, isSolid and 0.6 or 0.35), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime = cfg.Trail or 0.07
	trail.FaceCamera = true
	trail.LightEmission = isSolid and 0.15 or 1 -- solid bolts leave a faint wake, not a glow ribbon
	trail.WidthScale = NumberSequence.new(1, 0.2)
	trail.Parent = bolt

	bolt.Parent = fxFolder
	table.insert(activeBolts, {
		part = bolt, from = from, dir = dir, dist = dist,
		speed = cfg.Speed, life = cfg.Life or 0.05, t = 0,
		weaponId = weaponId, -- ability guns pop their own colors on arrival (impactPop)
		burstColor = cfg.BurstColor, -- optional colored pop where the bolt lands
	})
end

-- Advance every in-flight bolt; when one reaches its impact point, fade it out (over its cfg.Life) and
-- drop it from the list.
local function updateBolts(dt: number)
	for i = #activeBolts, 1, -1 do
		local b = activeBolts[i]
		if not b.part.Parent then
			table.remove(activeBolts, i)
		else
			b.t += dt
			local traveled = b.speed * b.t
			if traveled >= b.dist then
				local pos = b.from + b.dir * b.dist
				b.part.CFrame = CFrame.lookAt(pos, pos + b.dir)
				TweenService:Create(b.part, TweenInfo.new(b.life), { Transparency = 1 }):Play()
				Debris:AddItem(b.part, b.life + 0.08) -- + a beat for the tail to finish fading
				if b.burstColor then -- landing pop (the freeze ray's frost puff)
					local puff = Instance.new("Part")
					puff.Shape = Enum.PartType.Ball
					puff.Size = Vector3.new(0.7, 0.7, 0.7)
					puff.Anchored = true
					puff.CanCollide = false
					puff.CanQuery = false
					puff.CanTouch = false
					puff.CastShadow = false
					puff.Material = Enum.Material.Neon
					puff.Color = b.burstColor
					puff.Transparency = 0.15
					puff.CFrame = CFrame.new(pos)
					puff.Parent = fxFolder
					TweenService:Create(puff, TweenInfo.new(0.22), { Transparency = 1, Size = Vector3.new(2.2, 2.2, 2.2) }):Play()
					Debris:AddItem(puff, 0.25)
				end
				if b.weaponId == "plasma" or b.weaponId == "raygun" or b.weaponId == "crossbow" then
					impactPop(pos, b.weaponId) -- ability-gun landing signature
				end
				table.remove(activeBolts, i)
			else
				local pos = b.from + b.dir * traveled
				b.part.CFrame = CFrame.lookAt(pos, pos + b.dir)
			end
		end
	end
end

local function muzzleFlash(cf: CFrame, weaponId: string?)
	local cfg = AnimationConfig.MuzzleFlash
	if not cfg.Enabled then
		return
	end
	local ov = weaponId and cfg.PerWeapon and cfg.PerWeapon[weaponId]
	if ov and ov.Enabled == false then
		return -- e.g. the crossbow: no gunpowder, no flash
	end
	local flashColor = (ov and ov.Color) or cfg.Color
	-- Just the small neon flash — NO PointLight (the per-shot light burst on the player was distracting).
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(0.5, 0.5, 0.5)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = flashColor
	ball.CFrame = cf
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
	-- Inset NOT ignored: WorldToScreenPoint returns inset-relative coordinates, so the X lands exactly
	-- on the hit point.
	hitmarkerGui.IgnoreGuiInset = false
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

local function showHitmarker(killed: boolean, headshot: boolean, position: Vector3?)
	local cfg = AnimationConfig.Hitmarker
	if not cfg.Enabled or not hitmarkerGui then
		return
	end
	-- Pop the X where the shot actually LANDED (screen-projected); center only as the off-screen fallback.
	local holderPos = UDim2.fromScale(0.5, 0.5)
	if position then
		local cam = Workspace.CurrentCamera
		if cam then
			local sp, onScreen = cam:WorldToScreenPoint(position)
			if onScreen then
				holderPos = UDim2.fromOffset(sp.X, sp.Y)
			end
		end
	end
	hitmarkerGui.Holder.Position = holderPos
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
	local muzzleCF = gunMuzzleCF(localPlayer.Character)
	if muzzleCF then
		muzzleFlash(muzzleCF, weaponId)
	end
end

-- Every shot (incl. our own): draw the bullet from the shooter's gun muzzle to where it landed.
-- `pellets` (shotguns) fans that many bolts with a little scatter around the endpoint, so a shell visibly
-- sprays instead of drawing one line.
local MAX_VISUAL_PELLETS = 6
local function onShotFired(shooterUserId: number, origin: Vector3, endpoint: Vector3, weaponId: string?, pellets: number?)
	local shooter = Players:GetPlayerByUserId(shooterUserId)
	local character = shooter and shooter.Character
	local muzzleCF = gunMuzzleCF(character)
	-- Bolts + flash both start at the gun barrel (the "Muzzle" attachment, or the gun in-hand).
	local from = muzzleCF and muzzleCF.Position or origin
	-- FX budget: OTHER players' shots beyond ~140 studs of the camera skip their tracer + flash
	-- entirely (you can't see them anyway; your own shots always draw).
	if shooterUserId ~= localPlayer.UserId then
		local cam = Workspace.CurrentCamera
		if cam and (from - cam.CFrame.Position).Magnitude > 140 then
			return
		end
	end
	if shooterUserId ~= localPlayer.UserId and muzzleCF then
		muzzleFlash(muzzleCF, weaponId) -- others' muzzle flash (the local player already flashed on fire)
	end

	local count = math.clamp(tonumber(pellets) or 1, 1, MAX_VISUAL_PELLETS)
	if count <= 1 then
		spawnProjectile(from, endpoint, weaponId)
		return
	end
	local dir = endpoint - from
	local dist = dir.Magnitude
	if dist < 1 then
		spawnProjectile(from, endpoint, weaponId)
		return
	end
	dir = dir.Unit
	-- Scatter endpoints in a disc perpendicular to the travel direction (~9° spread — a visible fan).
	local up = (math.abs(dir.Y) > 0.99) and Vector3.xAxis or Vector3.yAxis
	local right = dir:Cross(up).Unit
	local upP = dir:Cross(right).Unit
	local radius = dist * 0.16
	for i = 1, count do
		local ang = math.random() * math.pi * 2
		local r = math.sqrt(math.random()) * radius
		local target = endpoint + (right * math.cos(ang) + upP * math.sin(ang)) * r
		spawnProjectile(from, target, weaponId)
	end
end

local function onHitConfirmed(position: Vector3, isHeadshot: boolean, hitHumanoid: boolean, killed: boolean)
	if hitHumanoid then
		showHitmarker(killed, isHeadshot, position) -- the X pops right where the zombie was hit
	else
		impact(position, false) -- world/miss impact only
	end
end

-- ===== LIFECYCLE =====
function CombatFeedbackController.Start()
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "CombatFX"
	fxFolder.Parent = Workspace.CurrentCamera -- client-only, never replicated

	-- Only build the hitmarker GUI when the feature is actually on — it was constructing a disabled
	-- ScreenGui + frames every session for nothing.
	if AnimationConfig.Hitmarker.Enabled then
		buildHitmarker()
	end

	InputController.Fired:Connect(onLocalFired)
	Remotes.Get("ShotFired").OnClientEvent:Connect(onShotFired)
	Remotes.Get("HitConfirmed").OnClientEvent:Connect(onHitConfirmed)

	RunService.RenderStepped:Connect(updateShake) -- decays trauma + applies the camera shake/kick each frame
	RunService.Heartbeat:Connect(updateBolts)     -- flies every in-flight projectile toward its impact

	print("[CombatFeedbackController] started")
end

return CombatFeedbackController
