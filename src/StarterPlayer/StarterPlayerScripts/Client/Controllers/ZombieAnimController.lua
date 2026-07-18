--!nonstrict
-- ZombieAnimController.lua — PROCEDURAL zombie animation (no uploaded animations needed). Now that
-- zombies are custom entities (no Humanoid), each client animates the rigs it can see: the classic
-- arms-out zombie pose, legs swinging from the rig's ACTUAL velocity, and a slow idle sway when still.
-- Runs entirely client-side via Motor6D.Transform (the same channel Animators use — non-destructive,
-- ragdolls simply disable the joints and our writes stop mattering). Distance-culled + capped, so a
-- 200-zombie horde costs each client almost nothing. A rig whose type has a REAL AnimationConfig walk
-- id is stamped ZTrackAnim=true by the server and skipped here — uploaded animations always win.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ZombieAnimController = {}

-- ===== TUNABLES =====
local MAX_ANIMATED  = 30    -- most rigs animated per frame (nearest-first would cost sorting; first-N in range)
local ANIM_DISTANCE = 90    -- rigs beyond this from the camera hold their pose (no per-frame writes)
local ARM_RAISE     = 80    -- degrees the arms reach forward (the zombie pose)
local ARM_BOB       = 9     -- degrees of arm bob while walking
local LEG_SWING     = 32    -- degrees of leg swing at full stride
local STRIDE_FREQ   = 1.35  -- stride cycles per second at ~12 studs/sec of speed (scales with velocity)
local IDLE_SWAY     = 4     -- degrees of slow shoulder sway while standing still

local rigs = {} -- [model] = { joints..., phase, r6 }

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
	-- R6 joints live in the Torso with spaced names; R15 uses camelCase in the limbs. Grab whichever exists.
	local entry = {
		r6 = model:GetAttribute("RigR6") == true,
		rs = findMotor(model, { "Right Shoulder", "RightShoulder" }),
		ls = findMotor(model, { "Left Shoulder", "LeftShoulder" }),
		rh = findMotor(model, { "Right Hip", "RightHip" }),
		lh = findMotor(model, { "Left Hip", "LeftHip" }),
		phase = math.random() * math.pi * 2, -- desync strides so the horde doesn't march in lockstep
	}
	if entry.rs or entry.rh then -- something to animate
		rigs[model] = entry
	end
end

local function step(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	local animated = 0
	for model, e in rigs do
		if not model.Parent then
			rigs[model] = nil
			continue
		end
		if model:GetAttribute("ZTrackAnim") then
			continue -- a real uploaded animation owns this rig
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
		local walking = speed > 1

		-- R6 shoulder/hip motors are Y-rotated ±90° in their C0, so a joint-space Z rotation swings the
		-- limb FORWARD/BACK (mirrored between sides). R15 joints are unrotated — use X instead.
		local swing = math.sin(e.phase)
		local armA = math.rad(ARM_RAISE)
			+ (walking and math.rad(ARM_BOB) * math.sin(e.phase + math.pi) or 0)
			+ (not walking and math.rad(IDLE_SWAY) * math.sin(os.clock() * 1.6 + e.phase) or 0)
		local legA = walking and math.rad(LEG_SWING) * swing or 0
		if e.r6 then
			if e.rs then
				e.rs.Transform = CFrame.Angles(0, 0, armA)
			end
			if e.ls then
				e.ls.Transform = CFrame.Angles(0, 0, -armA)
			end
			if e.rh then
				e.rh.Transform = CFrame.Angles(0, 0, legA)
			end
			if e.lh then
				e.lh.Transform = CFrame.Angles(0, 0, legA) -- left hip's mirrored axis = opposite world swing
			end
		else
			if e.rs then
				e.rs.Transform = CFrame.Angles(-armA, 0, 0)
			end
			if e.ls then
				e.ls.Transform = CFrame.Angles(-armA, 0, 0)
			end
			if e.rh then
				e.rh.Transform = CFrame.Angles(legA, 0, 0)
			end
			if e.lh then
				e.lh.Transform = CFrame.Angles(-legA, 0, 0)
			end
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
			task.defer(register, m) -- joints replicate right after the model does
		end
	end)
	folder.ChildRemoved:Connect(function(m)
		rigs[m] = nil
	end)
	RunService.Heartbeat:Connect(step)
	print("[ZombieAnimController] started (procedural zombie animation)")
end

return ZombieAnimController
