--!nonstrict
-- ZombieService.lua — spawn, AI, scaling, pooling, and performance for the horde (CLAUDE.md §13).
--
-- PERFORMANCE DESIGN (this is the whole challenge):
--   • HARD CAP at GameConfig.MaxAliveZombies — the round "owes" more, but they only spawn as others die.
--   • STAGGERED AI — each zombie thinks on its own timer (~ZombieAITickRate), not every zombie every frame.
--   • SPARSE PATHFINDING — recompute a path every ~PathRecompute seconds (async, off the heartbeat) and
--     STEER between waypoints in between, instead of full pathfinding per frame.
--   • POOLING — zombie models are reused, not created/destroyed every spawn.
--
-- MODEL CONTRACT (when you build zombie models): put a Model at
--   ReplicatedStorage > Assets > Zombies > <typeId>   (or a single "Default" model used for all types)
-- with a Humanoid, a HumanoidRootPart (PrimaryPart), and a part named "Head" (for headshots).
-- No model? A tinted placeholder rig is built so the horde works immediately.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local ZombieConfig = require(Config.ZombieConfig)
local AnimationConfig = require(Config.AnimationConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local PlayerStateService = require(script.Parent.PlayerStateService)

local ZombieService = {}

-- ===== TUNABLES (most live in GameConfig; these are local feel knobs) =====
local SPAWN_INTERVAL   = 0.6    -- seconds between spawns while a round still owes zombies
local ATTACK_RANGE     = 4.5    -- studs within which a zombie can hit a player
local ATTACK_COOLDOWN  = 1.0    -- seconds between a zombie's attacks
local WAYPOINT_REACH   = 4      -- studs to consider a path waypoint reached
local DEATH_FLASH_TIME = 0.12   -- seconds a zombie flashes red on death (same quick flash as a hit, NOT permanent)
local RAGDOLL_TIME     = 1.4    -- seconds the limp body flops/settles after death
local SURFACE_HOLD     = 1.0    -- extra seconds the body lies still ON the surface before it starts sinking
local SINK_TIME        = 3.2    -- seconds the corpse SLOWLY sinks into the ground (bigger = slower/eerier)
local SINK_DEPTH       = 4      -- studs the corpse sinks before it's pooled
local RAGDOLL_LIMB_ANGLE = 40   -- BallSocket cone limit (deg); too BIG = limbs splay/dislocate, too small = stiff
local STUCK_DIST       = 2      -- studs of movement counted as "making progress"
local STUCK_TIMEOUT    = 8      -- seconds wedged-with-a-target before a zombie force-kills itself
local PATH_RETRY       = 0.5    -- seconds to wait before retrying a FAILED path (vs PathRecompute on success)
local JUMP_CHECK_RATE  = 0.25   -- seconds between a zombie's "should I jump this obstacle?" probes
local OBSTACLE_AHEAD   = 3      -- studs ahead the zombie probes for a ledge/obstacle to jump
local STUCK_REPLAN     = 0.9    -- seconds of no progress before a direct-chaser switches to pathfinding
local MAX_LIFETIME     = 120    -- backstop: a zombie alive this long is force-killed (anti soft-lock).
                               -- High so big hordes don't get culled mid-chase; STUCK_TIMEOUT handles real wedges.
local SPAWN_HEIGHT     = 3      -- studs above a spawn point to drop a zombie
local GRAVE_STAND_HEIGHT = 3.5 -- studs the zombie's root sits above the ground when fully risen (feet land
                               -- just above ground so it settles cleanly instead of toppling)
local MIN_SPAWN_DIST   = 10    -- min studs between a new spawn and any active grave (no stacking spawns)
local EMERGE_DEPTH     = 5      -- studs below ground a zombie starts buried (then rises out)
local EMERGE_TIME      = 1.6    -- seconds a zombie takes to claw its way up out of the ground (slow, but
                               -- still FASTER than the death sink SINK_TIME so it reads as "rising out")
local GRAVE_LINGER     = 4      -- seconds the grave headstone stays after the zombie is out
local GRAVE_SINK_TIME  = 1.5    -- seconds the grave then takes to sink away and despawn
local BIG_GRAVE_TYPES  = { tank = true, boss = true } -- these enemies rise from a "Big" grave instead
local HIT_KNOCKBACK    = 18     -- studs/sec shove away from the shooter on a non-lethal hit
local HIT_FLASH_TIME   = 0.12   -- seconds a zombie flashes white when hit
local FLASH_COLOR      = Color3.fromRGB(255, 255, 255)
local DEATH_COLOR      = Color3.fromRGB(170, 30, 30)
local DEBUG            = false  -- set true to print a live zombie's state every 2s (diagnose "not moving")

-- ===== STATE =====
local active: { [Model]: any } = {}   -- model -> record
local aliveCount = 0
local remaining = 0                   -- zombies still owed this round
local currentRound = 0
local roundToken = 0                  -- bumped to cancel in-flight spawn loops / rounds
local bossRecord: any = nil           -- the one live boss, if any (drives the boss health bar)

local pool: { [string]: { Model } } = {}  -- typeId -> reusable models
local graveTemplates: { Model } = {}      -- regular Grave models from Assets/Graves (normal enemies)
local bigGraveTemplates: { Model } = {}   -- "Big*" graves (e.g. BigGrave1/2) for tank + boss
local zombieFolder: Folder
local poolFolder: Folder
local graveFolder: Folder

-- Owner-supplied zombie models, registered by tagging a Model "ZombieTemplate" (anywhere in the place).
-- A template named after a zombie typeId is used for that type; otherwise it's the default for all types.
local templates: { [string]: Model } = {}
local defaultTemplate: Model? = nil
local templatesFolder: Folder

-- The spawnable archetypes (ZombieConfig also holds non-type scalars like BossInterval — filter them out).
local ZOMBIE_TYPES: { [string]: any } = {}
local ALL_WEIGHTS: { [string]: number } = {}
for id, t in ZombieConfig do
	if type(t) == "table" and t.id then
		ZOMBIE_TYPES[id] = t
		ALL_WEIGHTS[id] = t.spawnWeight
	end
end

-- ===== SCALING (CLAUDE.md §8) =====
local function scaledHealth(round: number, t): number
	return math.floor(GameConfig.ZombieBaseHealth * (GameConfig.ZombieHealthGrowth ^ (round - 1)) * t.healthMult)
end

local function scaledSpeed(round: number, t): number
	local s = (GameConfig.ZombieBaseSpeed + GameConfig.ZombieSpeedPerRound * (round - 1)) * t.speedMult
	return math.min(GameConfig.ZombieMaxSpeed, s)
end


-- ===== MODEL BUILD / POOL =====
-- Shared humanoid setup (no joint-snap on death, auto-jump small ledges, an Animator for poses).
local function configureHumanoid(hum: Humanoid)
	hum.BreakJointsOnDeath = false
	hum.AutoJumpEnabled = true       -- auto-hop small ledges while walking
	hum.UseJumpPower = true
	hum.JumpPower = 55               -- a bit higher than default so it can climb onto stuff (~8 studs)
	if not hum:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = hum
	end
end

local function buildPlaceholder(t): Model
	local model = Instance.new("Model")
	model.Name = "Zombie"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = true
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = t.tint
	torso.Material = Enum.Material.SmoothPlastic
	torso.CanCollide = false
	torso.CFrame = root.CFrame
	torso.Parent = model
	local w1 = Instance.new("WeldConstraint")
	w1.Part0 = root
	w1.Part1 = torso
	w1.Parent = root

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.Color = t.tint
	head.Material = Enum.Material.SmoothPlastic
	head.CanCollide = false
	head.CFrame = root.CFrame * CFrame.new(0, 1.6, 0)
	head.Parent = model
	local w2 = Instance.new("WeldConstraint")
	w2.Part0 = root
	w2.Part1 = head
	w2.Parent = root

	local hum = Instance.new("Humanoid")
	hum.HipHeight = 0
	hum.Parent = model
	configureHumanoid(hum)

	model.PrimaryPart = root
	return model
end

-- Case-INSENSITIVE child lookup (Roblox's FindFirstChild is case-sensitive; map builders aren't).
local function ciFind(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	local exact = parent:FindFirstChild(name)
	if exact then
		return exact
	end
	local lname = name:lower()
	for _, c in parent:GetChildren() do
		if c.Name:lower() == lname then
			return c
		end
	end
	return nil
end

-- Resolve an instance to a usable Model (the thing itself, or a Model nested one level inside it).
local function asModel(inst: Instance?): Model?
	if not inst then
		return nil
	end
	if inst:IsA("Model") then
		return inst
	end
	return inst:FindFirstChildWhichIsA("Model")
end

local function findAsset(typeId: string): Model?
	-- 1) a tagged "ZombieTemplate" matching this type, else the default tagged template
	if templates[typeId] then
		return templates[typeId]
	end
	if defaultTemplate then
		return defaultTemplate
	end
	-- 2) a model in an "Assets" folder (case-insensitive) in ReplicatedStorage OR ServerStorage. Any of:
	--    Assets/Zombies/{typeId|Default}, or Assets/{typeId|Zombie|Default}.
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		if assets then
			local zf = ciFind(assets, "Zombies")
			local candidates = {
				zf and ciFind(zf, typeId) or nil,
				zf and ciFind(zf, "Default") or nil,
				ciFind(assets, typeId),
				ciFind(assets, "Zombie"),
				ciFind(assets, "Default"),
			}
			for _, c in candidates do
				local m = asModel(c)
				if m then
					return m
				end
			end
		end
	end
	return nil
end

local function prepModel(model: Model)
	-- A Humanoid only walks if it has a part named exactly "HumanoidRootPart" to use as its root.
	-- If the owner's model doesn't have one, promote a suitable part so the rig can actually move.
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		root = model.PrimaryPart or model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
			or model:FindFirstChildWhichIsA("BasePart")
		if root and root:IsA("BasePart") then
			root.Name = "HumanoidRootPart"
		end
	end
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
	end
	-- A walking rig must be unanchored; also remember each part's base color for hit/death recolors.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			if d:GetAttribute("ZBaseColor") == nil then
				d:SetAttribute("ZBaseColor", d.Color)
			end
			-- Remember each part's pose RELATIVE to the root in the standing rig. After a ragdoll we snap the
			-- rig back together from this (no reliance on physics resolving while pooled in ServerStorage).
			if root and root:IsA("BasePart") and d ~= root and d:GetAttribute("ZRel") == nil then
				d:SetAttribute("ZRel", root.CFrame:ToObjectSpace(d.CFrame))
			end
		end
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		configureHumanoid(hum)
	end
end

-- Pull a tagged "ZombieTemplate" model out of the live world and store it as a spawn template.
local function registerTemplate(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	if templatesFolder and inst:IsDescendantOf(templatesFolder) then
		return -- already registered
	end
	inst.Parent = templatesFolder
	prepModel(inst)
	templates[inst.Name] = inst
	if not defaultTemplate then
		defaultTemplate = inst
	end
	print(("[ZombieService] registered zombie template '%s'"):format(inst.Name))
end

local function loadTaggedTemplates()
	for _, inst in CollectionService:GetTagged("ZombieTemplate") do
		registerTemplate(inst)
	end
end

local loggedModel = false
local function buildZombie(typeId: string, t): Model
	local asset = findAsset(typeId)
	if not loggedModel then
		loggedModel = true
		if asset then
			print(("[ZombieService] using zombie model '%s'"):format(asset:GetFullName()))
		else
			warn("[ZombieService] no zombie model found — using the grey placeholder. Put your model at "
				.. "ReplicatedStorage > Assets > Zombies > Default (any capitalization), or tag it 'ZombieTemplate'.")
		end
	end
	local model = asset and asset:Clone() or buildPlaceholder(t)
	prepModel(model)
	return model
end

local function acquire(typeId: string, t): Model
	local list = pool[typeId]
	if list and #list > 0 then
		return table.remove(list) :: Model
	end
	return buildZombie(typeId, t)
end

-- ===== HIT / DEATH FEEDBACK =====
local function recolor(model: Model, color: Color3)
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p.Transparency < 1 then
			p.Color = color
		end
	end
end

local function restoreColors(model: Model)
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local base = p:GetAttribute("ZBaseColor")
			if typeof(base) == "Color3" then
				p.Color = base
			end
		end
	end
end

-- Flash a zombie white briefly on a non-lethal hit, then back to its base color.
local function flashWhite(record)
	if record.dead then
		return
	end
	recolor(record.model, FLASH_COLOR)
	task.delay(HIT_FLASH_TIME, function()
		if not record.dead and record.model.Parent then
			restoreColors(record.model)
		end
	end)
end

local clearRagdoll -- forward declaration (defined in the DEATH section; used here to un-ragdoll on reuse)

local function release(record)
	local model = record.model
	if record.diedConn then
		record.diedConn:Disconnect()
		record.diedConn = nil
	end

	-- Undo the ragdoll: re-enable the rig's joints, remove ragdoll constraints, restore collisions.
	if clearRagdoll then
		clearRagdoll(model)
	end

	-- A Humanoid that reached 0 HP is permanently Dead — raising Health does NOT revive it and
	-- MoveTo() is a no-op on it. Replace it with a fresh Humanoid for reuse, carrying over the rig's
	-- HipHeight/RigType so user-built models keep standing correctly.
	local oldHum = model:FindFirstChildOfClass("Humanoid")
	local hipHeight = oldHum and oldHum.HipHeight or 0
	local rigType = oldHum and oldHum.RigType or Enum.HumanoidRigType.R6
	if oldHum then
		oldHum:Destroy()
	end
	local hum = Instance.new("Humanoid")
	hum.HipHeight = hipHeight
	hum.RigType = rigType
	hum.WalkSpeed = 0
	hum.Parent = model
	configureHumanoid(hum)

	-- Free the cap slot only now (the corpse occupied a real Workspace instance until this moment).
	aliveCount = math.max(0, aliveCount - 1)

	-- Reset visuals/physics so the pooled model comes back clean (upright, base color, no velocity).
	restoreColors(model)
	-- Un-anchor every part (the death sink anchored them) so the rig can walk again on reuse.
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end
	-- Snap the rig back to its standing pose (each part relative to the root) so a ragdolled corpse pools
	-- cleanly instead of being reused as a scattered/limp mess.
	local rootPart = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if rootPart then
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") and p ~= rootPart then
				local rel = p:GetAttribute("ZRel")
				if typeof(rel) == "CFrame" then
					p.CFrame = rootPart.CFrame * rel
				end
			end
		end
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end
	-- Now that the rig is back in its standing pose, re-enable any WeldConstraints we disabled (they
	-- freeze the current relative transform, so they must be turned on AFTER the parts are repositioned).
	for _, d in model:GetDescendants() do
		if d:IsA("WeldConstraint") then
			d.Enabled = true
		end
	end

	model.Parent = poolFolder
	local list = pool[record.typeId]
	if not list then
		list = {}
		pool[record.typeId] = list
	end
	table.insert(list, model)
end

-- ===== TARGETING =====
local function nearestAlivePlayer(fromPos: Vector3): (Player?, BasePart?)
	local bestPlayer, bestRoot, bestDist = nil, nil, math.huge
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if hum and root and hum.Health > 0 then
			local d = (root.Position - fromPos).Magnitude
			if d < bestDist then
				bestDist, bestPlayer, bestRoot = d, player, root
			end
		end
	end
	return bestPlayer, bestRoot
end

-- ===== PATHFINDING (async, off the heartbeat) =====
local function recomputePath(record, targetPos: Vector3)
	record.computing = true
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentMaxSlope = 45,
	})
	local ok = pcall(function()
		path:ComputeAsync(record.root.Position, targetPos)
	end)
	if not record.dead and ok and path.Status == Enum.PathStatus.Success then
		local wps = path:GetWaypoints()
		record.waypoints = wps
		record.waypointIndex = math.min(2, #wps) -- skip the start point
		record.pathFailed = false
	else
		record.waypoints = nil
		record.pathFailed = true -- triggers a faster retry (PATH_RETRY) next think
	end
	record.computing = false
end

-- ===== RAGDOLL =====
-- Make a rigged Humanoid model go limp by turning the joints that hold it together into floppy
-- BallSocketConstraints. R6 rigs (Head/Torso/Arms/Legs as separate parts) use the KNOWN R6 joint
-- positions — that's the only way to pin the shoulder/hip at the right spot so arms don't dislocate.
-- Anything else falls back to a generic pass over its actual joints.

-- Create a ball-socket between two parts, with each side's attachment at the given LOCAL CFrame.
local function attachBall(part0: BasePart, part1: BasePart, cf0: CFrame, cf1: CFrame)
	local a0 = Instance.new("Attachment")
	a0.Name = "RagdollAtt"
	a0.CFrame = cf0
	a0.Parent = part0
	local a1 = Instance.new("Attachment")
	a1.Name = "RagdollAtt"
	a1.CFrame = cf1
	a1.Parent = part1

	local bsc = Instance.new("BallSocketConstraint")
	bsc.Name = "RagdollBSC"
	bsc.Attachment0 = a0
	bsc.Attachment1 = a1
	bsc.LimitsEnabled = true
	bsc.UpperAngle = RAGDOLL_LIMB_ANGLE
	bsc.TwistLimitsEnabled = true
	bsc.TwistLowerAngle = -RAGDOLL_LIMB_ANGLE
	bsc.TwistUpperAngle = RAGDOLL_LIMB_ANGLE
	bsc.Parent = part1
end

-- Disable whatever rigid joint(s) currently connect parts a and b (Motor6D/Weld/Snap/WeldConstraint).
local function disableJointsBetween(model: Model, a: BasePart, b: BasePart)
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			local p0, p1 = d.Part0, d.Part1
			if (p0 == a and p1 == b) or (p0 == b and p1 == a) then
				d.Enabled = false
			end
		end
	end
end

-- The standard R6 joint locations: { limb name, attachment on Torso, attachment on the limb }. These put
-- each ball-socket exactly at the shoulder / hip / neck so limbs hang naturally instead of dislocating.
local R6_JOINTS = {
	{ limb = "Head",      c0 = CFrame.new(0, 1, 0),    c1 = CFrame.new(0, -0.5, 0) },
	{ limb = "Right Arm", c0 = CFrame.new(1, 0.5, 0),  c1 = CFrame.new(-0.5, 0.5, 0) },
	{ limb = "Left Arm",  c0 = CFrame.new(-1, 0.5, 0), c1 = CFrame.new(0.5, 0.5, 0) },
	{ limb = "Right Leg", c0 = CFrame.new(1, -1, 0),   c1 = CFrame.new(0.5, 1, 0) },
	{ limb = "Left Leg",  c0 = CFrame.new(-1, -1, 0),  c1 = CFrame.new(-0.5, 1, 0) },
}

local function setupR6Ragdoll(model: Model): boolean
	local torso = model:FindFirstChild("Torso")
	if not (torso and torso:IsA("BasePart")) then
		return false
	end
	local made = false
	for _, j in R6_JOINTS do
		local limb = model:FindFirstChild(j.limb)
		if limb and limb:IsA("BasePart") then
			disableJointsBetween(model, torso, limb) -- unlock the rigid arm/leg/head connection
			attachBall(torso, limb, j.c0, j.c1)      -- hang it from the proper R6 joint
			made = true
		end
	end
	return made
end

-- Fallback for R15 / custom rigs: ragdoll every actual joint (C0/C1 from JointInstances; for a
-- WeldConstraint, pivot where the limb's surface is nearest the other part).
local function setupGenericRagdoll(model: Model): boolean
	local jis, wcs = {}, {}
	for _, m in model:GetDescendants() do
		if m:IsA("JointInstance") and m.Part0 and m.Part1 then
			table.insert(jis, m)
		elseif m:IsA("WeldConstraint") and m.Part0 and m.Part1 then
			table.insert(wcs, m)
		end
	end
	if #jis == 0 and #wcs == 0 then
		return false
	end
	for _, m in jis do
		attachBall(m.Part0, m.Part1, m.C0, m.C1)
		m.Enabled = false
	end
	for _, m in wcs do
		local part0, part1 = m.Part0, m.Part1
		local rel = part1.CFrame:PointToObjectSpace(part0.Position)
		local half = part1.Size * 0.5
		rel = Vector3.new(
			math.clamp(rel.X, -half.X, half.X),
			math.clamp(rel.Y, -half.Y, half.Y),
			math.clamp(rel.Z, -half.Z, half.Z)
		)
		local pivotWorld = part1.CFrame:PointToWorldSpace(rel)
		attachBall(part0, part1, part0.CFrame:ToObjectSpace(CFrame.new(pivotWorld)), part1.CFrame:ToObjectSpace(CFrame.new(pivotWorld)))
		m.Enabled = false
	end
	return true
end

local function setRagdoll(record): boolean
	local model = record.model
	local hum = model:FindFirstChildOfClass("Humanoid")

	local made = false
	if hum and hum.RigType == Enum.HumanoidRigType.R6 then
		made = setupR6Ragdoll(model)
	end
	if not made then
		made = setupGenericRagdoll(model)
	end
	if not made then
		return false -- nothing rigid to ragdoll (e.g. the welded grey placeholder)
	end

	-- Limbs collide with the world so the body piles on the floor; the root stops propping it upright.
	-- Remember each part's original CanCollide so reuse restores it. Server simulates the loose parts.
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			if p:GetAttribute("ZBaseCC") == nil then
				p:SetAttribute("ZBaseCC", p.CanCollide)
			end
			p.CanCollide = (p ~= record.root)
			pcall(function()
				p:SetNetworkOwner(nil)
			end)
		end
	end

	if hum then
		hum.PlatformStand = true
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end

	-- A small nudge so the limp body actually starts to collapse instead of standing perfectly still.
	if record.root and record.root.Parent then
		record.root.AssemblyLinearVelocity = Vector3.new(math.random(-3, 3), 2, math.random(-3, 3))
	end
	return true
end

-- Reverse setRagdoll so the pooled model walks again: re-enable joints, drop the ragdoll constraints,
-- restore collisions. (Assigned to the forward-declared local so release() above can call it.)
clearRagdoll = function(model)
	for _, d in model:GetDescendants() do
		-- Re-enable C0/C1 joints (Motor6D/Weld/Snap) — they re-assert their fixed pose immediately.
		-- WeldConstraints are intentionally left for release() to re-enable AFTER the rig is snapped back
		-- to its standing pose (a WeldConstraint freezes the CURRENT offset, so timing matters).
		if d:IsA("JointInstance") then
			d.Enabled = true
		elseif d.Name == "RagdollBSC" and d:IsA("BallSocketConstraint") then
			d:Destroy()
		elseif d.Name == "RagdollAtt" and d:IsA("Attachment") then
			d:Destroy()
		end
	end
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local cc = p:GetAttribute("ZBaseCC")
			if cc ~= nil then
				p.CanCollide = cc
			end
		end
	end
end

-- After the limp body has flopped and settled, freeze each part in its settled pose and lower the whole
-- pile straight down — slowly — so the corpse appears to sink into the earth, then pool it.
local function sinkAndRelease(record)
	local model = record.model
	task.wait(RAGDOLL_TIME)
	if not model.Parent then
		release(record)
		return
	end
	-- Freeze the flopped pose: anchor every part where it landed (preserves the ragdoll shape).
	local frozen: { [BasePart]: CFrame } = {}
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
			p.Anchored = true
			frozen[p] = p.CFrame
		end
	end
	-- Let the body lie on the surface a beat before it begins to sink.
	task.wait(SURFACE_HOLD)
	if not model.Parent then
		release(record)
		return
	end
	-- Slide each frozen part straight down in world space over SINK_TIME.
	local elapsed = 0
	while elapsed < SINK_TIME and model.Parent do
		elapsed += task.wait()
		local drop = Vector3.new(0, -SINK_DEPTH * math.clamp(elapsed / SINK_TIME, 0, 1), 0)
		for p, cf in frozen do
			if p.Parent then
				p.CFrame = cf + drop
			end
		end
	end
	release(record)
end

-- ===== DEATH =====
local function onZombieDied(record)
	if record.dead then
		return
	end
	record.dead = true
	active[record.model] = nil

	-- Boss bookkeeping: if this was the boss, tell clients to drop the health bar + show the defeat banner.
	if record == bossRecord then
		bossRecord = nil
		if record.bossHealthConn then
			record.bossHealthConn:Disconnect()
			record.bossHealthConn = nil
		end
		Remotes.Get("BossDefeated"):FireAllClients()
	end
	-- aliveCount is freed in release() (after the corpse linger), so corpses still count against the
	-- MaxAliveZombies cap until they're actually pooled — keeping true simultaneous bodies under the cap.

	-- Last kill of the wave? (this one is still counted in aliveCount until release, so <=1 means it's the
	-- final living zombie and nothing more is owed). Trigger the slow-mo punch-in.
	if remaining <= 0 and aliveCount <= 1 then
		Remotes.Get("BulletTime"):FireAllClients(record.root.Position)
	end

	local hum = record.model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
	end
	if record.walkTrack then
		record.walkTrack:Stop()
	end

	-- Death feedback: a quick RED flash (same brief flash as a hit — NOT permanently red), then back to
	-- the base color while the body ragdolls and sinks.
	recolor(record.model, DEATH_COLOR)
	task.delay(DEATH_FLASH_TIME, function()
		if record.model.Parent then
			restoreColors(record.model)
		end
	end)

	-- Ragdoll: play a death animation if configured, else make the rig LIMP (limbs flop, not a solid
	-- statue) and let it collapse under gravity. The weld-only placeholder rig can't ragdoll, so it falls
	-- back to a gentle physics topple.
	if record.deathTrack then
		record.deathTrack:Play()
	elseif not setRagdoll(record) then
		local root = record.root
		if root and root.Parent then
			root.AssemblyLinearVelocity = Vector3.new(math.random(-4, 4), 5, math.random(-4, 4))
			root.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-5, 5), math.random(-8, 8))
		end
	end

	-- Then sink the corpse into the ground and return it to the pool.
	task.spawn(sinkAndRelease, record)
end

-- ===== SPAWN =====
local function pickType(round: number): string?
	return Util.WeightedChoiceFiltered(ALL_WEIGHTS, function(id)
		local t = ZOMBIE_TYPES[id]
		return t.spawnWeight > 0 and round >= t.minRound
	end)
end

-- ===== ZOMBIE ANIMATIONS (server-managed; played on the rig's Animator on the server, so every client
-- sees the same thing and it can't be tampered with client-side) =====
-- Walk defaults to Roblox's built-in walk animation for the rig type (public, loads server-side) so zombies
-- animate out of the box; attack/death are optional and come from AnimationConfig.Zombies.
local DEFAULT_WALK = {
	[Enum.HumanoidRigType.R15] = "rbxassetid://507777826", -- Roblox default R15 walk
	[Enum.HumanoidRigType.R6] = "rbxassetid://180426354",  -- Roblox default R6 walk
}

local zAnimCache: { [string]: Animation } = {}
local function zGetAnim(id: string): Animation
	local a = zAnimCache[id]
	if not a then
		a = Instance.new("Animation")
		a.AnimationId = id
		zAnimCache[id] = a
	end
	return a
end

local function loadZombieTracks(record)
	local hum = record.hum
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local cfg = AnimationConfig.Zombies[record.typeId] or AnimationConfig.Zombies.Default or {}
	-- Walk: use the configured id, else fall back to the engine's default walk for this rig type.
	local walk = AnimationConfig.Resolve(cfg.Walk) or DEFAULT_WALK[record.hum.RigType]
	if walk then
		record.walkTrack = animator:LoadAnimation(zGetAnim(walk))
		record.walkTrack.Looped = true
		record.walkTrack.Priority = Enum.AnimationPriority.Movement
		record.walkTrack:Play()
	end
	local attack = AnimationConfig.Resolve(cfg.Attack)
	if attack then
		record.attackTrack = animator:LoadAnimation(zGetAnim(attack))
		record.attackTrack.Priority = Enum.AnimationPriority.Action
	end
	local death = AnimationConfig.Resolve(cfg.Death)
	if death then
		record.deathTrack = animator:LoadAnimation(zGetAnim(death))
		record.deathTrack.Priority = Enum.AnimationPriority.Action2
	end
end

-- Don't spawn on top of a zombie that's still climbing out — keep clear of any active grave (graves linger
-- until that zombie is fully out and the headstone has sunk away).
local function tooCloseToActiveGrave(pos: Vector3): boolean
	if not graveFolder then
		return false
	end
	for _, g in graveFolder:GetChildren() do
		local gp
		if g:IsA("Model") then
			gp = g:GetPivot().Position
		elseif g:IsA("BasePart") then
			gp = g.Position
		end
		if gp then
			local dx, dz = pos.X - gp.X, pos.Z - gp.Z
			if dx * dx + dz * dz < MIN_SPAWN_DIST * MIN_SPAWN_DIST then
				return true
			end
		end
	end
	return false
end

-- Spawn ~35 studs from a random living player. (No maps yet, so no ZombieSpawn points — when you build
-- maps, ask to re-add tagged spawn points.) Keeps clear of active graves so zombies don't stack.
local function getSpawnCFrame(): CFrame?
	local candidates = {}
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local r = char and char:FindFirstChild("HumanoidRootPart")
		local h = char and char:FindFirstChildOfClass("Humanoid")
		if r and h and h.Health > 0 then
			table.insert(candidates, r)
		end
	end
	if #candidates == 0 then
		return nil
	end
	for _ = 1, 12 do
		local root = candidates[math.random(#candidates)]
		local angle = math.random() * 2 * math.pi
		local cf = CFrame.new(root.Position + Vector3.new(math.cos(angle) * 35, SPAWN_HEIGHT, math.sin(angle) * 35))
		if not tooCloseToActiveGrave(cf.Position) then
			return cf
		end
	end
	return nil
end

-- ===== GRAVES (props cloned above each spawn; the zombie rises out from under them) =====
-- Grave models live in Assets > Graves (Grave1, Grave2, ...). Loaded once; a random one is cloned per spawn.
local function loadGraveTemplates()
	local regular, big = {}, {}
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		local gf = assets and ciFind(assets, "Graves")
		if gf then
			for _, c in gf:GetChildren() do
				local m = asModel(c)
				if m then
					-- Models named "Big..." (BigGrave1, BigGrave2) are the big graves for tank/boss.
					if m.Name:lower():match("^big") then
						table.insert(big, m)
					else
						table.insert(regular, m)
					end
				end
			end
		end
	end
	graveTemplates = regular
	bigGraveTemplates = big
end

-- Find the ground Y under a point (ignores zombies, players, and grave props so it hits real terrain).
local function findGroundY(x: number, z: number, fallbackY: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local filter: { Instance } = { zombieFolder, graveFolder }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(filter, pl.Character)
		end
	end
	params.FilterDescendantsInstances = filter
	local hit = Workspace:Raycast(Vector3.new(x, fallbackY + 8, z), Vector3.new(0, -80, 0), params)
	return hit and hit.Position.Y or fallbackY
end

-- Drop a random grave headstone at (x, z) sitting on the ground, then sink it away after a while.
-- Props are non-colliding and non-queryable so they never block movement, shots, or ground checks.
local function placeGrave(x: number, groundY: number, z: number, big: boolean)
	-- tank/boss rise from a Big grave; fall back to a regular grave if no Big ones exist.
	local list = (big and #bigGraveTemplates > 0) and bigGraveTemplates or graveTemplates
	if #list == 0 then
		return
	end
	local grave = list[math.random(#list)]:Clone()
	for _, p in grave:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
		end
	end
	-- Random yaw so every headstone faces a different way (do this BEFORE measuring, then drop it in place).
	grave:PivotTo(grave:GetPivot() * CFrame.Angles(0, math.random() * 2 * math.pi, 0))
	local cf, size = grave:GetBoundingBox()
	local currentBaseY = cf.Position.Y - size.Y * 0.5
	grave:PivotTo(grave:GetPivot() + Vector3.new(x - cf.Position.X, groundY - currentBaseY, z - cf.Position.Z))
	grave.Parent = graveFolder

	task.spawn(function()
		task.wait(EMERGE_TIME + GRAVE_LINGER)
		local startCF = grave:GetPivot()
		local elapsed = 0
		while elapsed < GRAVE_SINK_TIME and grave.Parent do
			elapsed += task.wait()
			grave:PivotTo(startCF + Vector3.new(0, -EMERGE_DEPTH * math.clamp(elapsed / GRAVE_SINK_TIME, 0, 1), 0))
		end
		grave:Destroy()
	end)
end

-- Emergence: drop a grave on the ground above the spawn, bury the zombie below it, then raise it to the
-- surface over EMERGE_TIME. AI is suppressed (record.emerging) until it's out, then chasing takes over.
local function startEmergence(record, spawnCF: CFrame)
	local model = record.model
	local hum = record.hum
	local root = record.root
	local pos = spawnCF.Position
	local groundY = findGroundY(pos.X, pos.Z, pos.Y)
	local finalCF = CFrame.new(pos.X, groundY + GRAVE_STAND_HEIGHT, pos.Z)

	placeGrave(pos.X, groundY, pos.Z, BIG_GRAVE_TYPES[record.typeId] == true)

	record.emerging = true
	-- Anchor ONLY the root and limp the Humanoid during the rise. The rig's joints keep the limbs glued to
	-- the root, so it rises as one piece; because we never anchor/limp-release the whole body, it doesn't
	-- topple when it reaches the surface (anchoring every part then releasing made it fall over).
	if hum then
		hum.PlatformStand = true
	end
	root.Anchored = true
	local base = finalCF + Vector3.new(0, -EMERGE_DEPTH, 0)
	model:PivotTo(base)
	task.spawn(function()
		local elapsed = 0
		while elapsed < EMERGE_TIME and model.Parent and not record.dead do
			elapsed += task.wait()
			local a = math.clamp(elapsed / EMERGE_TIME, 0, 1)
			model:PivotTo(base + Vector3.new(0, EMERGE_DEPTH * a, 0))
		end
		if model.Parent and not record.dead then
			model:PivotTo(finalCF)
			root.Anchored = false
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			if hum then
				hum.PlatformStand = false -- hand control back so it stands and walks
			end
			pcall(function()
				root:SetNetworkOwner(nil)
			end)
		end
		record.emerging = false
	end)
end

-- Spawn one zombie. `forcedType` overrides the random pick (used by the boss). Returns the record (or nil).
local function spawnOne(round: number, forcedType: string?)
	local spawnCF = getSpawnCFrame()
	if not spawnCF then
		return nil
	end
	local typeId = forcedType or pickType(round) or "default"
	local t = ZOMBIE_TYPES[typeId]
	if not t then
		return nil
	end

	local model = acquire(typeId, t)
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model.PrimaryPart
	if not hum or not root then
		return nil
	end

	local hp = scaledHealth(round, t)
	hum.MaxHealth = hp
	hum.Health = hp
	hum.WalkSpeed = scaledSpeed(round, t)

	-- Stamp the type's point value on the model so PointsService can award without a cross-service lookup.
	model:SetAttribute("PointsMult", t.pointsMult)
	model:SetAttribute("IsSpecial", t.isSpecial)

	model:PivotTo(spawnCF)
	model.Parent = zombieFolder

	-- Keep the server authoritative over zombie physics (perf + anti-exploit).
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	local now = os.clock()
	local record = {
		model = model,
		root = root,
		hum = hum,
		typeId = typeId,
		type = t,
		damage = t.damage,
		target = nil,
		targetRoot = nil,
		mode = "idle",          -- "idle" | "direct" (live chase) | "path" (navigating obstacles)
		waypoints = nil,
		waypointIndex = 1,
		computing = false,
		lastPath = 0,
		lastAttack = 0,
		nextJumpCheck = 0,
		spawnTime = now,
		nextThink = now + math.random() * GameConfig.ZombieAITickRate, -- stagger
		dead = false,
		emerging = false,
		diedConn = nil,
		lastPos = root.Position,    -- for stuck detection
		lastMoveTime = now,
		pathFailed = false,
	}
	record.diedConn = hum.Died:Connect(function()
		onZombieDied(record)
	end)

	active[model] = record
	aliveCount += 1
	loadZombieTracks(record)

	-- Rise up out of the ground (under a grave headstone) before the AI kicks in.
	startEmergence(record, spawnCF)

	return record
end

-- ===== AI =====
-- Two layers (CLAUDE.md §13): a sparse, staggered "plan" (think) decides WHO to chase and HOW (chase the
-- live position directly when in sight, or pathfind around obstacles when blocked), and a per-frame
-- "steer" actually drives the rig toward the live goal and hops obstacles. This is what makes it track in
-- real time instead of following a point that only updates when the path recomputes.

-- RaycastParams that ignore all zombies + player characters, so probes only hit world geometry.
local function worldOnlyParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local filter: { Instance } = { zombieFolder }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(filter, pl.Character)
		end
	end
	params.FilterDescendantsInstances = filter
	return params
end

-- Is there solid world geometry directly between two points?
local function sightBlocked(fromPos: Vector3, toPos: Vector3): boolean
	local dir = toPos - fromPos
	if dir.Magnitude < 0.1 then
		return false
	end
	return Workspace:Raycast(fromPos, dir, worldOnlyParams()) ~= nil
end

-- PLAN (staggered ~ZombieAITickRate): choose target + chase mode; pathfind only when needed.
local function think(record, now: number)
	local root = record.root
	if not root or not root.Parent then
		return
	end

	local target, targetRoot = nearestAlivePlayer(root.Position)
	record.target = target
	record.targetRoot = targetRoot
	if not targetRoot then
		record.mode = "idle"
		record.nextThink = now + GameConfig.ZombieAITickRate
		return
	end

	local dist = (root.Position - targetRoot.Position).Magnitude
	local blocked = sightBlocked(root.Position, targetRoot.Position)
	local stuck = (now - record.lastMoveTime) > STUCK_REPLAN and dist > ATTACK_RANGE

	if blocked or stuck then
		-- Navigate AROUND geometry. Recompute toward the player's CURRENT position; retry fast after a
		-- failure or while wedged, otherwise sparsely (perf).
		record.mode = "path"
		local interval = record.pathFailed and PATH_RETRY or GameConfig.PathRecompute
		if stuck then
			interval = math.min(interval, PATH_RETRY)
		end
		if not record.computing and (now - record.lastPath) >= interval then
			record.lastPath = now
			task.spawn(recomputePath, record, targetRoot.Position)
		end
	else
		-- Clear line of sight: chase the live position directly (no stale waypoints).
		record.mode = "direct"
		record.waypoints = nil
		record.waypointIndex = 1
	end

	-- Attack on contact.
	if dist <= ATTACK_RANGE and (now - record.lastAttack) >= ATTACK_COOLDOWN then
		record.lastAttack = now
		PlayerStateService.Damage(target, record.damage, "zombie", root.Position)
		if record.attackTrack then
			record.attackTrack:Play(0.1)
		end
	end

	-- Backstop: a zombie wedged for STUCK_TIMEOUT (or alive too long) force-kills itself so the round
	-- can't soft-lock on something unreachable.
	if (now - record.lastMoveTime) > STUCK_TIMEOUT or (now - record.spawnTime) > MAX_LIFETIME then
		record.hum.Health = 0
		return
	end

	record.nextThink = now + GameConfig.ZombieAITickRate
end

-- STEER (every frame): drive toward the live goal + hop obstacles. Cheap (no pathfinding here).
local function steer(record, now: number)
	local hum = record.hum
	local root = record.root
	if not hum or not root or not root.Parent then
		return
	end
	local targetRoot = record.targetRoot
	if record.mode == "idle" or not targetRoot or not targetRoot.Parent then
		hum:Move(Vector3.zero)
		return
	end

	local dist = (root.Position - targetRoot.Position).Magnitude

	-- Goal = the player's LIVE position (direct) or the current path waypoint (path).
	local goal = targetRoot.Position
	if record.mode == "path" and record.waypoints and record.waypointIndex <= #record.waypoints then
		local wp = record.waypoints[record.waypointIndex]
		goal = wp.Position
		local flat = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
		if flat.Magnitude < WAYPOINT_REACH then
			if wp.Action == Enum.PathWaypointAction.Jump then
				hum.Jump = true
			end
			record.waypointIndex += 1
		end
	end

	if dist <= ATTACK_RANGE then
		hum:Move(Vector3.zero) -- in melee range: stop shoving the player around
	else
		local toGoal = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
		if toGoal.Magnitude > 0.1 then
			local move = toGoal.Unit
			hum:Move(move, false)

			-- Jump up onto / over stuff: probe ahead. If something blocks at foot height but the path is
			-- clear higher up, it's a ledge/step/obstacle we can hop.
			if now >= (record.nextJumpCheck or 0) then
				record.nextJumpCheck = now + JUMP_CHECK_RATE
				local ahead = move * OBSTACLE_AHEAD
				local params = worldOnlyParams()
				local lowHit = Workspace:Raycast(root.Position - Vector3.new(0, 1.5, 0), ahead, params)
				local highHit = Workspace:Raycast(root.Position + Vector3.new(0, 2, 0), ahead, params)
				if lowHit and not highHit then
					hum.Jump = true
				end
			end
		end
	end

	-- Progress tracking for stuck detection (moving OR meleeing both count as progress).
	if (root.Position - record.lastPos).Magnitude > STUCK_DIST or dist <= ATTACK_RANGE then
		record.lastPos = root.Position
		record.lastMoveTime = now
	end
end

local lastDebug = 0
local function onHeartbeat()
	local now = os.clock()
	for _, record in active do
		if not record.dead and not record.emerging then -- emerging zombies are still rising out of the grave
			if now >= record.nextThink then
				think(record, now) -- sparse planning
			end
			steer(record, now)     -- per-frame real-time steering
		end
	end

	if DEBUG and (now - lastDebug) > 2 then
		lastDebug = now
		print(("[ZombieDebug] alive=%d remaining=%d"):format(aliveCount, remaining))
		for _, record in active do
			local h = record.hum
			print(("[ZombieDebug]  type=%s walkSpeed=%.1f state=%s hasTarget=%s anchored=%s")
				:format(
					record.typeId,
					h and h.WalkSpeed or -1,
					h and tostring(h:GetState()) or "nil",
					tostring(record.target ~= nil),
					tostring(record.root and record.root.Anchored)
				))
			break -- one sample is enough to diagnose
		end
	end
end

-- ===== PUBLIC API (the round loop in MatchService drives these) =====

-- Begin spawning `count` zombies for `round`, throttled by SPAWN_INTERVAL and the MaxAliveZombies cap.
function ZombieService.BeginRound(round: number, count: number)
	currentRound = round
	remaining = count
	roundToken += 1
	local myToken = roundToken

	task.spawn(function()
		while remaining > 0 and myToken == roundToken do
			if aliveCount < GameConfig.MaxAliveZombies then
				if spawnOne(round) then
					remaining -= 1
				end
			end
			task.wait(SPAWN_INTERVAL)
		end
	end)
end

-- Spawn exactly ONE boss for this wave: broadcasts an entrance, then streams its health to the boss bar
-- until it dies. The boss counts toward aliveCount, so the wave won't clear until it's dead.
function ZombieService.SpawnBoss(round: number)
	task.spawn(function()
		local record
		for _ = 1, 30 do -- retry in case every spawn point is briefly crowded by a fresh grave
			record = spawnOne(round, ZombieConfig.BossId)
			if record then
				break
			end
			task.wait(0.3)
		end
		if not record then
			return
		end
		bossRecord = record
		record.isBoss = true
		local hum = record.hum
		Remotes.Get("BossSpawned"):FireAllClients(record.type.name, hum.MaxHealth)
		record.bossHealthConn = hum.HealthChanged:Connect(function(h)
			Remotes.Get("BossHealth"):FireAllClients(h, hum.MaxHealth)
		end)
	end)
end

-- True once every owed zombie has spawned and the world is clear of living zombies.
function ZombieService.IsRoundCleared(): boolean
	return remaining <= 0 and aliveCount <= 0
end

function ZombieService.GetAliveCount(): number
	return aliveCount
end

function ZombieService.GetRemaining(): number
	return remaining
end

-- The Workspace folder holding all live zombies (used to exclude them from line-of-sight checks).
function ZombieService.GetFolder(): Folder
	return zombieFolder
end

-- Snapshot of the live zombies (for CombatService's arc hit). Each entry: { record with .root/.hum/... }.
function ZombieService.GetActive()
	local list = {}
	for _, record in active do
		if not record.dead and record.root and record.root.Parent and record.hum and record.hum.Health > 0 then
			table.insert(list, record)
		end
	end
	return list
end

-- Hit feedback for a non-lethal hit: a little knockback away from the shooter + a white flash.
function ZombieService.Hit(record, fromPos: Vector3)
	if record.dead then
		return
	end
	local root = record.root
	if root and root.Parent then
		local away = root.Position - fromPos
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude > 0.01 then
			root.AssemblyLinearVelocity = away.Unit * HIT_KNOCKBACK + Vector3.new(0, 4, 0)
		end
	end
	flashWhite(record)
end

-- Wipe everything (used on game over / reset). Cancels spawning and pools all live zombies.
function ZombieService.ClearAll()
	roundToken += 1
	remaining = 0
	bossRecord = nil
	for model, record in active do
		record.dead = true
		if record.diedConn then
			record.diedConn:Disconnect()
			record.diedConn = nil
		end
		release(record)
		active[model] = nil
	end
	aliveCount = 0
end

-- ===== LIFECYCLE =====
function ZombieService.Start()
	zombieFolder = Instance.new("Folder")
	zombieFolder.Name = "Zombies"
	zombieFolder.Parent = Workspace

	graveFolder = Instance.new("Folder")
	graveFolder.Name = "Graves"
	graveFolder.Parent = Workspace

	poolFolder = Instance.new("Folder")
	poolFolder.Name = "ZombiePool"
	poolFolder.Parent = ServerStorage

	templatesFolder = Instance.new("Folder")
	templatesFolder.Name = "ZombieTemplates"
	templatesFolder.Parent = ServerStorage

	loadTaggedTemplates()
	CollectionService:GetInstanceAddedSignal("ZombieTemplate"):Connect(registerTemplate)

	loadGraveTemplates()

	RunService.Heartbeat:Connect(onHeartbeat)

	print(("[ZombieService] started (%d grave model(s) in Assets/Graves)"):format(#graveTemplates))
end

return ZombieService
