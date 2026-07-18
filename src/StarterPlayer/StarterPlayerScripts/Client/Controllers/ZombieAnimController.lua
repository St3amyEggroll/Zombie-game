--!nonstrict
-- ZombieAnimController.lua — PROCEDURAL zombie animation v2 (no uploaded animations needed). Each client
-- animates the rigs it can see via Motor6D.Transform (the same channel Animators use; ragdolls disable
-- the joints so death is untouched). Distance-culled + capped: a 200-zombie horde costs almost nothing.
-- A rig whose type has a REAL AnimationConfig walk id is stamped ZTrackAnim=true and skipped — uploads win.
--
-- STATES (per rig, per frame):
--   AIR    — launched (jump/leap/knockback): arms thrown high, legs tucked under.
--   ATTACK — within biting range of a player: fast alternating claw swipes.
--   WALK   — the shamble: alternating leg swings with a real lift on the passing leg, arms reaching
--            forward with a hungry counter-bob, cadence tied to the rig's ACTUAL speed.
--   IDLE   — slow hungry sway, arms drooping slightly.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ZombieAnimController = {}

-- ===== TUNABLES =====
local MAX_ANIMATED  = 30     -- most rigs animated per frame
local ANIM_DISTANCE = 90     -- rigs beyond this from the camera hold their pose
local ATTACK_RANGE  = 5      -- studs to a player character that reads as "biting"
local ARM_RAISE     = 78     -- degrees the arms reach forward while shambling
local ARM_BOB       = 12     -- degrees of hungry arm bob while walking
local LEG_SWING     = 34     -- degrees of leg swing at full stride
local LEG_LIFT      = 0.22   -- studs the passing leg lifts (sells the step; no knees on R6)
local STRIDE_FREQ   = 1.5    -- stride cycles/sec at ~12 studs/sec (scales with velocity)
local IDLE_SWAY     = 5      -- degrees of slow sway while standing
local AIR_VY        = 9      -- |vertical velocity| that reads as airborne

local rigs = {} -- [model] = { rs/ls/rh/lh, phase, r6 }

local function findMotor(model, names): Motor6D?
	for _, n in names do
		local j = model:FindFirstChild(n, true)
		if j and j:IsA("Motor6D") then
			return j
		end
	end
	return nil
end

local function register(model: Model)
	if rigs[model] then
		return
	end
	local entry = {
		r6 = model:GetAttribute("RigR6") == true,
		rs = findMotor(model, { "Right Shoulder", "RightShoulder" }),
		ls = findMotor(model, { "Left Shoulder", "LeftShoulder" }),
		rh = findMotor(model, { "Right Hip", "RightHip" }),
		lh = findMotor(model, { "Left Hip", "LeftHip" }),
		phase = math.random() * math.pi * 2, -- desync strides so the horde doesn't march in lockstep
	}
	if entry.rs or entry.rh then
		rigs[model] = entry
	end
end

-- Any player character root within biting range? (client-side inference — no remote needed)
local function nearPlayer(pos: Vector3): boolean
	for _, pl in Players:GetPlayers() do
		local char = pl.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - pos).Magnitude <= ATTACK_RANGE then
			return true
		end
	end
	return false
end

-- Apply limb transforms. R6 shoulder/hip motors are Y-rotated ±90° in C0, so joint-space Z = the
-- forward/back swing axis (mirrored between sides) and joint-space Y stays WORLD-UP (safe for lifts).
-- R15 joints are unrotated — X is the swing axis.
local function pose(e, armR, armL, legR, legL, liftR, liftL)
	if e.r6 then
		if e.rs then
			e.rs.Transform = CFrame.Angles(0, 0, armR)
		end
		if e.ls then
			e.ls.Transform = CFrame.Angles(0, 0, -armL)
		end
		if e.rh then
			e.rh.Transform = CFrame.new(0, liftR, 0) * CFrame.Angles(0, 0, legR)
		end
		if e.lh then
			e.lh.Transform = CFrame.new(0, liftL, 0) * CFrame.Angles(0, 0, legL)
		end
	else
		if e.rs then
			e.rs.Transform = CFrame.Angles(-armR, 0, 0)
		end
		if e.ls then
			e.ls.Transform = CFrame.Angles(-armL, 0, 0)
		end
		if e.rh then
			e.rh.Transform = CFrame.new(0, liftR, 0) * CFrame.Angles(legR, 0, 0)
		end
		if e.lh then
			e.lh.Transform = CFrame.new(0, liftL, 0) * CFrame.Angles(-legL, 0, 0)
		end
	end
end

local function step(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	local clock = os.clock()
	local animated = 0
	for model, e in rigs do
		if not model.Parent then
			rigs[model] = nil
			continue
		end
		if model:GetAttribute("ZTrackAnim") then
			continue
		end
		local root = model.PrimaryPart
		if not root then
			continue
		end
		if animated >= MAX_ANIMATED or (root.Position - camPos).Magnitude > ANIM_DISTANCE then
			continue
		end
		animated += 1

		local v = root.AssemblyLinearVelocity
		local speed = Vector3.new(v.X, 0, v.Z).Magnitude
		e.phase += dt * math.pi * 2 * STRIDE_FREQ * math.clamp(speed / 12, 0, 2.2)

		if math.abs(v.Y) > AIR_VY then
			-- AIR: arms thrown high, legs tucked (both hips swing forward)
			local flail = math.sin(clock * 9 + e.phase) * math.rad(10)
			pose(e, math.rad(120) + flail, math.rad(120) - flail, math.rad(45), -math.rad(45), 0, 0)
		elseif nearPlayer(root.Position) then
			-- ATTACK: fast alternating claw swipes
			local chop = math.sin(clock * 11 + e.phase) * math.rad(30)
			pose(e, math.rad(75) + chop, math.rad(75) - chop, 0, 0, 0, 0)
		elseif speed > 1 then
			-- WALK: the shamble. The passing (forward-swinging) leg lifts so steps read as steps.
			local swing = math.sin(e.phase)
			local legA = math.rad(LEG_SWING) * swing
			local liftR = math.max(0, swing) * LEG_LIFT
			local liftL = math.max(0, -swing) * LEG_LIFT
			local bob = math.rad(ARM_BOB)
			local armR = math.rad(ARM_RAISE) + bob * math.sin(e.phase + math.pi)
			local armL = math.rad(ARM_RAISE) + bob * math.sin(e.phase)
			pose(e, armR, armL, legA, legA, liftR, liftL) -- mirrored hip axes alternate the legs
		else
			-- IDLE: slow hungry sway, arms sagging a little
			local sway = math.sin(clock * 1.4 + e.phase) * math.rad(IDLE_SWAY)
			pose(e, math.rad(ARM_RAISE - 14) + sway, math.rad(ARM_RAISE - 14) - sway, 0, 0, 0, 0)
		end
	end
end

function ZombieAnimController.Start()
	local folder = Workspace:WaitForChild("Zombies", 30)
	if not folder then
		warn("[ZombieAnimController] no Zombies folder — procedural animation off")
		return
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") then
			register(m)
		end
	end
	folder.ChildAdded:Connect(function(m)
		if m:IsA("Model") then
			task.defer(register, m)
		end
	end)
	folder.ChildRemoved:Connect(function(m)
		rigs[m] = nil
	end)
	RunService.Heartbeat:Connect(step)
	print("[ZombieAnimController] started (procedural v2: walk/attack/air/idle)")
end

return ZombieAnimController
