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
local DESPAWN_DELAY    = 3      -- seconds a corpse lingers before returning to the pool
local STUCK_DIST       = 2      -- studs of movement counted as "making progress"
local STUCK_TIMEOUT    = 8      -- seconds wedged-with-a-target before a zombie force-kills itself
local PATH_RETRY       = 0.5    -- seconds to wait before retrying a FAILED path (vs PathRecompute on success)
local MAX_LIFETIME     = 30     -- backstop: a zombie alive this long is force-killed (anti soft-lock)
local SPAWN_HEIGHT     = 3      -- studs above a spawn point to drop a zombie
local DEBUG            = false  -- set true to print a live zombie's state every 2s (diagnose "not moving")

-- ===== STATE =====
local active: { [Model]: any } = {}   -- model -> record
local aliveCount = 0
local remaining = 0                   -- zombies still owed this round
local currentRound = 0
local roundToken = 0                  -- bumped to cancel in-flight spawn loops / rounds

local pool: { [string]: { Model } } = {}  -- typeId -> reusable models
local spawnPoints: { BasePart } = {}
local zombieFolder: Folder
local poolFolder: Folder

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

-- ===== SPAWN POINTS =====
local function refreshSpawnPoints()
	local list = {}
	for _, inst in CollectionService:GetTagged("ZombieSpawn") do
		if inst:IsA("BasePart") then
			table.insert(list, inst)
		end
	end
	spawnPoints = list
end

-- ===== MODEL BUILD / POOL =====
-- Shared humanoid setup (no joint-snap on death, auto-jump small ledges, an Animator for poses).
local function configureHumanoid(hum: Humanoid)
	hum.BreakJointsOnDeath = false
	hum.AutoJumpEnabled = true
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
	-- A walking rig must be unanchored (in case the owner placed a static/anchored prop).
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
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

local function release(record)
	local model = record.model
	if record.diedConn then
		record.diedConn:Disconnect()
		record.diedConn = nil
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

-- ===== DEATH =====
local function onZombieDied(record)
	if record.dead then
		return
	end
	record.dead = true
	active[record.model] = nil
	-- aliveCount is freed in release() (after the corpse linger), so corpses still count against the
	-- MaxAliveZombies cap until they're actually pooled — keeping true simultaneous bodies under the cap.

	Remotes.Get("ZombieDied"):FireAllClients(record.typeId, record.root.Position)

	local hum = record.model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
	end
	if record.walkTrack then
		record.walkTrack:Stop()
	end
	if record.deathTrack then
		record.deathTrack:Play()
	end
	task.delay(DESPAWN_DELAY, function()
		release(record)
	end)
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

local warnedNoSpawns = false
local function getSpawnCFrame(): CFrame?
	if #spawnPoints > 0 then
		local sp = spawnPoints[math.random(#spawnPoints)]
		return sp.CFrame * CFrame.new(0, SPAWN_HEIGHT, 0)
	end
	-- No ZombieSpawn parts tagged: fall back to ~35 studs from a random living player so the game works
	-- with zero map setup. (Tag `ZombieSpawn` parts to place real spawn points.)
	if not warnedNoSpawns then
		warnedNoSpawns = true
		warn("[ZombieService] no parts tagged 'ZombieSpawn' — spawning zombies near players as a fallback.")
	end
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
	local root = candidates[math.random(#candidates)]
	local angle = math.random() * 2 * math.pi
	return CFrame.new(root.Position + Vector3.new(math.cos(angle) * 35, SPAWN_HEIGHT, math.sin(angle) * 35))
end

local function spawnOne(round: number): boolean
	local spawnCF = getSpawnCFrame()
	if not spawnCF then
		return false
	end
	local typeId = pickType(round) or "walker"
	local t = ZOMBIE_TYPES[typeId]
	if not t then
		return false
	end

	local model = acquire(typeId, t)
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model.PrimaryPart
	if not hum or not root then
		return false
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
		waypoints = nil,
		waypointIndex = 1,
		computing = false,
		lastPath = 0,
		lastAttack = 0,
		spawnTime = now,
		nextThink = now + math.random() * GameConfig.ZombieAITickRate, -- stagger
		dead = false,
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

	if t.isSpecial then
		Remotes.Get("ZombieSpawned"):FireAllClients(typeId, root.Position)
	end
	return true
end

-- ===== AI HEARTBEAT (steering only; pathfinding is async) =====
local function think(record, now: number)
	if record.dead then
		return
	end
	local root = record.root
	if not root or not root.Parent then
		return
	end

	local target, targetRoot = nearestAlivePlayer(root.Position)
	record.target = target
	if not targetRoot then
		record.hum:Move(Vector3.zero) -- nobody alive to chase: idle in place
		record.nextThink = now + GameConfig.ZombieAITickRate
		return
	end

	-- Sparse path recompute (off the heartbeat). Retry quickly after a failed path, otherwise sparsely.
	local recomputeInterval = record.pathFailed and PATH_RETRY or GameConfig.PathRecompute
	if not record.computing and (now - record.lastPath) >= recomputeInterval then
		record.lastPath = now
		task.spawn(recomputePath, record, targetRoot.Position)
	end

	-- Steer toward the current waypoint, or straight at the target if we have no path.
	local goal = targetRoot.Position
	if record.waypoints and record.waypointIndex <= #record.waypoints then
		local wp = record.waypoints[record.waypointIndex]
		goal = wp.Position
		local flat = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
		if flat.Magnitude < WAYPOINT_REACH then
			if wp.Action == Enum.PathWaypointAction.Jump then
				record.hum:ChangeState(Enum.HumanoidStateType.Jumping)
			end
			record.waypointIndex += 1
		end
	end

	local dist = (root.Position - targetRoot.Position).Magnitude
	-- Drive the walk with Humanoid:Move (a continuous direction; more reliable than MoveTo for chasing —
	-- no 8s MoveTo timeout, and it keeps walking between AI ticks).
	if dist <= ATTACK_RANGE then
		record.hum:Move(Vector3.zero) -- in melee range: stop shoving the player around
	else
		local toGoal = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
		if toGoal.Magnitude > 0.1 then
			record.hum:Move(toGoal.Unit, false)
		end
	end

	-- Attack on contact.
	if dist <= ATTACK_RANGE and (now - record.lastAttack) >= ATTACK_COOLDOWN then
		record.lastAttack = now
		PlayerStateService.Damage(target, record.damage, "zombie")
		if record.attackTrack then
			record.attackTrack:Play(0.1)
		end
	end

	-- Stuck detection: moving OR meleeing a player both count as progress. A zombie that does neither
	-- for STUCK_TIMEOUT (wedged on geometry / unreachable) force-kills itself so the round can clear.
	if (root.Position - record.lastPos).Magnitude > STUCK_DIST or dist <= ATTACK_RANGE then
		record.lastPos = root.Position
		record.lastMoveTime = now
	end
	if (now - record.lastMoveTime) > STUCK_TIMEOUT or (now - record.spawnTime) > MAX_LIFETIME then
		record.hum.Health = 0 -- triggers Died -> onZombieDied -> aliveCount frees, round can clear
		return
	end

	record.nextThink = now + GameConfig.ZombieAITickRate
end

local lastDebug = 0
local function onHeartbeat()
	local now = os.clock()
	for _, record in active do
		if now >= record.nextThink then
			think(record, now)
		end
	end

	if DEBUG and (now - lastDebug) > 2 then
		lastDebug = now
		print(("[ZombieDebug] alive=%d remaining=%d spawnPoints=%d"):format(aliveCount, remaining, #spawnPoints))
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

-- Wipe everything (used on game over / reset). Cancels spawning and pools all live zombies.
function ZombieService.ClearAll()
	roundToken += 1
	remaining = 0
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

	poolFolder = Instance.new("Folder")
	poolFolder.Name = "ZombiePool"
	poolFolder.Parent = ServerStorage

	templatesFolder = Instance.new("Folder")
	templatesFolder.Name = "ZombieTemplates"
	templatesFolder.Parent = ServerStorage

	loadTaggedTemplates()
	CollectionService:GetInstanceAddedSignal("ZombieTemplate"):Connect(registerTemplate)

	refreshSpawnPoints()
	CollectionService:GetInstanceAddedSignal("ZombieSpawn"):Connect(refreshSpawnPoints)
	CollectionService:GetInstanceRemovedSignal("ZombieSpawn"):Connect(refreshSpawnPoints)

	RunService.Heartbeat:Connect(onHeartbeat)

	print(("[ZombieService] started (%d spawn point(s) tagged)"):format(#spawnPoints))
end

return ZombieService
