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
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local ZombieConfig = require(Config.ZombieConfig)
local SoundConfig = require(Config.SoundConfig)
local AnimationConfig = require(Config.AnimationConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)
local SpawnZones = require(Modules.SpawnZones)

local PlayerStateService = require(script.Parent.PlayerStateService)
local SoundFXService = require(script.Parent.SoundFXService)

local lastGrowlEmit = 0 -- os.clock() of the last ambient growl broadcast (global throttle)

local ZombieService = {}

-- ===== TUNABLES (most live in GameConfig; these are local feel knobs) =====
local SPAWN_INTERVAL      = 0.35 -- seconds between spawns at wave 1 (while a round still owes zombies)
local SPAWN_INTERVAL_MIN  = 0.15 -- floor for the per-wave speedup below
local SPAWN_INTERVAL_STEP = 0.01 -- interval shrinks this much per wave (deep waves flood in faster)
local ATTACK_RANGE     = 3.5    -- studs of CONTACT — a zombie damages you when its body touches yours
local ATTACK_VERTICAL  = 6      -- studs of height difference allowed for a hit (so a zombie far below/above
                               -- on a ramp/ledge can't tag you); paired with a line-of-sight check
local ATTACK_COOLDOWN  = 1.0    -- seconds between a zombie's attacks
-- ----- Leaper pounce (only zombies whose type has canLeap=true) -----
local LEAP_COOLDOWN    = 1.6    -- seconds between pounces (low = leaps constantly)
local LEAP_MIN_DIST    = 6      -- pounce from as close as this (so it keeps pouncing, not just once from afar)
local LEAP_MAX_DIST    = 55     -- and no farther than this (out of range = keep approaching)
local LEAP_UP_SPEED    = 30     -- vertical launch velocity — LOW arc = a fast flat dart, not a hop straight up
local LEAP_MAX_HSPEED  = 140    -- cap on the horizontal launch speed (studs/sec)
local LEAP_REACH_FRAC  = 0.95   -- fraction of the gap each pounce covers (≈1 lands basically ON you
                               -- in over several pounces instead of burying straight into melee on the first)
-- ----- BombZombie (isBomb) -----
local BOMB_TRIGGER     = 8      -- studs from a player that LIGHTS the fuse
local BOMB_FUSE        = 1.1    -- seconds after the fuse lights before it detonates
local BOMB_RADIUS      = 14     -- explosion radius (players inside take damage, falling off to 0 at the edge)
local BOMB_DAMAGE      = 90     -- explosion damage at the centre
-- ----- Ghost (canFly) -----
local GHOST_HEIGHT     = 12     -- studs above the player the ghost hovers
local GHOST_DIVE_CD    = 3.0    -- seconds between dive-bombs
local GHOST_DIVE_TIME  = 0.4    -- seconds spent dropping down on a dive
local GHOST_DIVE_RANGE = 22     -- horizontal studs within which it commits to a dive
-- ----- Necromancer (summons) -----
local SUMMON_CD        = 5.0    -- seconds between summons
local SUMMON_COUNT     = 3      -- zombies raised per summon (respects the MaxAliveZombies cap)
local WAYPOINT_REACH   = 4      -- studs to consider a path waypoint reached
local DEATH_FLASH_TIME = 0.12   -- seconds a zombie flashes red on death (same quick flash as a hit, NOT permanent)
local RAGDOLL_TIME     = 1.4    -- seconds the limp body flops/settles after death
local SURFACE_HOLD     = 1.0    -- extra seconds the body lies still ON the surface before it starts sinking
local SINK_TIME        = 3.2    -- seconds the corpse SLOWLY sinks into the ground (bigger = slower/eerier)
local MAX_CORPSES      = 12     -- ragdoll corpses settling at once; extras pool fast (each runs its own loop)
local SINK_DEPTH       = 4      -- studs the corpse sinks before it's pooled
local RAGDOLL_LIMB_ANGLE = 40   -- BallSocket cone limit (deg); too BIG = limbs splay/dislocate, too small = stiff
local STUCK_DIST       = 2      -- studs of movement counted as "making progress"
local STUCK_TIMEOUT    = 8      -- seconds wedged-with-a-target before a zombie force-kills itself
local PATH_RETRY       = 0.5    -- seconds to wait before retrying a FAILED path (vs PathRecompute on success)
local JUMP_CHECK_RATE  = 0.25   -- seconds between a zombie's "should I jump this obstacle?" probes
local OBSTACLE_AHEAD   = 3      -- studs ahead the zombie probes for a ledge/obstacle to jump
local STUCK_REPLAN     = 0.9    -- seconds of no progress before a direct-chaser switches to pathfinding
local MAX_LIFETIME     = 120    -- backstop: a zombie alive this long is force-killed (anti soft-lock).
local BOSS_UNSTUCK     = 22     -- a boss wedged/unreachable this long is RELOCATED near a player (not killed)
                               -- High so big hordes don't get culled mid-chase; STUCK_TIMEOUT handles real wedges.
local SPAWN_HEIGHT     = 3      -- studs above a spawn point to drop a zombie
local SPAWNPOINT_NEAR  = 160    -- studs: prefer ZombieSpawn parts within this range of a living player (Islands)
-- Shoreline spawns (Islands): zombies surface IN parts named "ocean", just past the water's edge.
local LOD_DISTANCE     = 130    -- studs: beyond this from its target a zombie thinks/steers at HALF rate
local SHORE_MAX_MARCH  = 260    -- studs: how far out from a player we hunt for the water's edge
local SHORE_STEP       = 6      -- studs per outward march step while hunting the shoreline
local SHORE_OUT        = 6      -- studs past the water's edge a zombie surfaces (in the water, near shore)
local BRIDGE_CLEAR     = 25     -- studs: never surface within this range of a part named "bridge"
local GRAVE_STAND_HEIGHT = 3.5 -- studs the zombie's root sits above the ground when fully risen (feet land
                               -- just above ground so it settles cleanly instead of toppling)
local MIN_SPAWN_DIST   = 10    -- min studs between a new spawn and any active grave (no stacking spawns)
-- Where pooled rigs are parked (frozen, far under any map) while they wait to be reused. They stay in
-- Workspace so a spawn doesn't have to re-replicate the whole model to every client — see release().
local PARK_POS         = Vector3.new(0, -900, 0)
-- How often the emergence/grave rises push a new CFrame. These used to run at the server's full frame
-- rate (~60Hz) on EVERY spawning zombie AND its headstone; with ~7-16 of them overlapping that was
-- thousands of replicated CFrame writes per second. 20Hz looks identical on a 1.6s rise.
local RISE_STEP        = 1 / 20
local EMERGE_DEPTH     = 5      -- studs below ground a zombie starts buried (then rises out)
local EMERGE_TIME      = 1.6    -- seconds a zombie takes to claw its way up out of the ground (slow, but
                               -- still FASTER than the death sink SINK_TIME so it reads as "rising out")
local GRAVE_LINGER     = 4      -- seconds the grave headstone stays after the zombie is out
local GRAVE_SINK_TIME  = 1.5    -- seconds the grave then takes to sink away and despawn
local GRAVE_RISE_TIME  = 0.8    -- seconds the headstone takes to rise OUT of the ground (before the zombie)
-- Which grave tier each enemy rises from: boss -> a "Huge*" grave, tank -> a "Big*" grave, others -> regular.
local GRAVE_TIER       = { boss = "huge", lumberjack = "huge", necromancer = "huge", tank = "big" }
local HIT_KNOCKBACK    = 18     -- studs/sec shove away from the shooter on a non-lethal hit
local KNOCKBACK_SPEED  = 68     -- studs/sec the DEATH ragdoll is launched, away from where the bullet came
                               -- from (strong, fixed for every kill)
local KNOCKBACK_UP     = 22     -- upward component so the body tumbles/flies rather than sliding along the floor
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
local globalSpeedMult = 1             -- BLOOD MOON (event wheel): whole-horde speed × for the wave
local eventMix = nil                  -- EVENT WHEEL: spawn-table bias { {id, share} } (BombSquad/Purge/Hounds)
local bombChain = false               -- BOMB SQUAD: bomb blasts also damage other zombies
local bossRecord: any = nil           -- the one live boss, if any (drives the boss health bar)

-- Fired with (deathPosition?) the moment a boss dies — GameInventoryService drops the wave's cases off it.
local bossDiedEvent = Instance.new("BindableEvent")
ZombieService.BossDied = bossDiedEvent.Event

-- Enemy types announced this run ("INCOMING! New enemy: X" — once per type per run; reset in ClearAll).
local announcedTypes: { [string]: boolean } = {}

local pool: { [string]: { Model } } = {}  -- typeId -> reusable models
local graveTemplates: { Model } = {}      -- regular Grave models from Assets/Graves (normal enemies)
local bigGraveTemplates: { Model } = {}   -- "Big*" graves (e.g. BigGrave1/2) for tanks
local hugeGraveTemplates: { Model } = {}  -- "Huge*" graves (e.g. HugeGrave1/2) for the boss
local zombieFolder: Folder
local poolFolder: Folder
local graveFolder: Folder

-- Owner-supplied zombie models, registered by tagging a Model "ZombieTemplate" (anywhere in the place).
-- A template named after a zombie typeId is used for that type; otherwise it's the default for all types.
local templates: { [string]: Model } = {}
local defaultTemplate: Model? = nil
local templatesFolder: Folder

-- The spawnable archetypes (ZombieConfig also holds non-type tables like BossWaves — filter them out).
local ZOMBIE_TYPES: { [string]: any } = {}
local ALL_WEIGHTS: { [string]: number } = {}
-- Model names match type ids LOOSELY: case/space/dash-insensitive, by id OR display name — so a model
-- named "Leaper Tank" (or "leaper_tank", or "LeaperTank") registers as leapertank.
local function sanitizeName(n: string): string
	return (n:lower():gsub("[%s%-_]", ""))
end
local zombieNameToId: { [string]: string } = {}
for id, t in ZombieConfig do
	if type(t) == "table" and t.id then
		ZOMBIE_TYPES[id] = t
		ALL_WEIGHTS[id] = t.spawnWeight
		zombieNameToId[sanitizeName(id)] = id
		if type(t.name) == "string" then
			zombieNameToId[sanitizeName(t.name)] = id
		end
	end
end

-- ===== SCALING (CLAUDE.md §8) ===== set per run by MatchService from the world's GameConfig.Maps tuning.
local difficultyMult = 1        -- × zombie HP + damage
local difficultySpeedMult = 1   -- × zombie speed
local allowedTypes: { [string]: boolean }? = nil  -- roster whitelist (nil = no whitelist)
local excludedTypes: { [string]: boolean }? = nil -- exclude blacklist (nil = none)
function ZombieService.SetDifficulty(diff)
	diff = (typeof(diff) == "table") and diff or {}
	difficultyMult = (typeof(diff.mult) == "number" and diff.mult > 0) and diff.mult or 1
	difficultySpeedMult = (typeof(diff.speedMult) == "number" and diff.speedMult > 0) and diff.speedMult or 1
	allowedTypes = nil
	if type(diff.roster) == "table" then
		allowedTypes = {}
		for _, id in diff.roster do
			allowedTypes[id] = true
		end
	end
	excludedTypes = (type(diff.exclude) == "table") and diff.exclude or nil
end

-- ===== MAP / WORLD (set per run by MatchService) =====
-- Drives (a) which enemy roster spawns (ZombieConfig `worlds`), (b) how zombies emerge — "grave" (dig out of
-- the ground, Forest) vs "water" (rise from the ocean with a splash, Islands) — and (c) whether they spawn AT
-- ZombieSpawn-tagged parts (Islands) or ~35 studs from a random player (Forest). See GameConfig.Maps.
local currentMap = GameConfig.DefaultMap
local mapEmerge = "grave"
local mapUseSpawnPoints = false
function ZombieService.SetMap(mapId: string?)
	currentMap = (typeof(mapId) == "string" and mapId ~= "") and mapId or GameConfig.DefaultMap
	local cfg = GameConfig.Maps and GameConfig.Maps[currentMap]
	mapEmerge = (cfg and cfg.emerge) or "grave"
	mapUseSpawnPoints = (cfg and cfg.useSpawnPoints) == true
end

local eventHPMult = 1 -- EVENT WHEEL (Gold Rush &co): × zombie HP for the wave, set via SetHPMult

local function scaledHealth(round: number, t): number
	return math.floor(GameConfig.ZombieBaseHealth * (GameConfig.ZombieHealthGrowth ^ (round - 1)) * t.healthMult * difficultyMult * eventHPMult)
end

local function scaledSpeed(round: number, t): number
	local s = (GameConfig.ZombieBaseSpeed + GameConfig.ZombieSpeedPerRound * (round - 1)) * t.speedMult * difficultySpeedMult
	return math.min(GameConfig.ZombieMaxSpeed, s)
end


-- ===== MODEL BUILD / POOL =====
-- CUSTOM ENTITIES (no Roblox Humanoid): zombies are plain physics models driven by our own velocity
-- steering, with health living in the server-side record and animations on a model-level
-- AnimationController. The owner's templates still SHIP with a Humanoid (map contract) — this strips
-- it at runtime and stamps a RigR6 attribute (Torso present = R6-style joints) for ragdoll/anim picks.
local function configureRig(model: Model)
	for _, h in model:GetChildren() do
		if h:IsA("Humanoid") then
			h:Destroy()
		end
	end
	local ac = model:FindFirstChildOfClass("AnimationController")
	if ac then
		ac:Destroy() -- fresh controller = fresh Animator (pooled models must drop stale loaded tracks)
	end
	ac = Instance.new("AnimationController")
	Instance.new("Animator").Parent = ac
	ac.Parent = model
	model:SetAttribute("RigR6", model:FindFirstChild("Torso") ~= nil)
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

	configureRig(model) -- no Humanoid: installs the AnimationController + RigR6 stamp

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
	-- 1) a tagged "ZombieTemplate" matching this type
	if templates[typeId] then
		return templates[typeId]
	end
	-- A child whose (sanitized) name resolves to this type — matches "Leaper Tank" for leapertank etc.
	local function matchIn(parent: Instance?): Instance?
		if not parent then
			return nil
		end
		for _, c in parent:GetChildren() do
			if zombieNameToId[sanitizeName(c.Name)] == typeId then
				return c
			end
		end
		return nil
	end
	-- 2) a TYPE-SPECIFIC model in an "Assets" folder (case-insensitive) in ReplicatedStorage OR
	--    ServerStorage — checked BEFORE the generic default template, so a new enemy's model is used
	--    whether it's tagged or just dropped into Assets/Zombies.
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		if assets then
			local zf = ciFind(assets, "Zombies")
			local candidates = {
				zf and ciFind(zf, typeId) or nil,
				zf and matchIn(zf) or nil,
				ciFind(assets, typeId),
				matchIn(assets),
			}
			for _, c in candidates do
				local m = asModel(c)
				if m then
					return m
				end
			end
		end
	end
	-- 3) the default tagged template, else the generic Assets fallbacks
	if defaultTemplate then
		return defaultTemplate
	end
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		if assets then
			local zf = ciFind(assets, "Zombies")
			local candidates = {
				zf and ciFind(zf, "Default") or nil,
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
	local rootPart = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CollisionGroup = "ZombieRig" -- zombies-only collisions (the ocean is solid ONLY for this group)
			-- The Humanoid used to manage this: ONLY the root collides (a non-colliding root fell through
			-- the world once the Humanoid left), limbs never do, and nothing needs Touch events.
			d.CanCollide = (d == rootPart)
			d.CanTouch = false
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
	configureRig(model) -- strips the template's Humanoid + installs the AnimationController
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
	local typeId = zombieNameToId[sanitizeName(inst.Name)]
	templates[typeId or inst.Name] = inst
	if not defaultTemplate then
		defaultTemplate = inst
	end
	print(("[ZombieService] registered zombie template '%s'%s"):format(
		inst.Name, typeId and (" as " .. typeId) or ""))
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
	-- (No per-zombie Highlight anymore: Roblox renders at most ~31 at once, so a horde's worth mostly
	-- dropped while still costing memory. ZombieOutlineController on each CLIENT owns a small pool and
	-- outlines only the nearest zombies.)
	return model
end

-- PARK a rig (perf — see the pool note at poolFolder's creation): a pooled rig STAYS in Workspace,
-- frozen and hidden far under the map. Sending it to ServerStorage made every client DESTROY the model
-- on death and re-download the whole rig on the next spawn — that round trip was the spawn lag.
-- Parked = anchored, non-colliding, non-queryable, so it can't be hit, raycast, or simulated.
local function parkModel(model: Model)
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
		end
	end
	model:PivotTo(CFrame.new(PARK_POS))
end

-- Wake a parked rig: undo exactly what release() froze (prepModel's rule — ONLY the root collides).
local function unpark(model: Model)
	local rootPart = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = (p == rootPart)
			p.CanQuery = true
		end
	end
end

local function acquire(typeId: string, t): Model
	local list = pool[typeId]
	if list and #list > 0 then
		local model = table.remove(list) :: Model
		unpark(model) -- it was frozen under the map; hand it back ready to walk
		return model
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

	-- Undo the ragdoll: re-enable the rig's joints, remove ragdoll constraints, restore collisions.
	if clearRagdoll then
		clearRagdoll(model)
	end

	-- CUSTOM ENTITIES: no Humanoid to resurrect — just rebuild a fresh AnimationController/Animator
	-- (loaded AnimationTracks die with the old Animator; stale ones can't be replayed on reuse).
	configureRig(model)

	-- Free the cap slot only now (the corpse occupied a real Workspace instance until this moment).
	aliveCount = math.max(0, aliveCount - 1)

	-- Reset visuals/physics so the pooled model comes back clean (upright, base color, no velocity).
	restoreColors(model)
	local staleIce = model:FindFirstChild("IceShell")
	if staleIce then
		staleIce:Destroy()
	end
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

	parkModel(model) -- freeze it under the map, still in Workspace (see parkModel)
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
		-- DOWNED players are out of the fight: zombies skip them (they can't be hit while downed anyway).
		if hum and root and hum.Health > 0 and char:GetAttribute("Downed") ~= true then
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
	if record.alignOr then
		record.alignOr.Enabled = false -- the upright constraint would fight the ragdoll
	end

	local made = false
	if model:GetAttribute("RigR6") then
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


	-- Knock the ragdoll backward, AWAY from where the bullet came from (a strong, fixed launch). Every part
	-- gets the same velocity so the whole body flies off together, then the loose joints make it tumble.
	if record.root and record.root.Parent then
		local dir = record.knockDir or -record.root.CFrame.LookVector
		local launch = dir * KNOCKBACK_SPEED + Vector3.new(0, KNOCKBACK_UP, 0)
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") then
				p.AssemblyLinearVelocity = launch
			end
		end
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
local corpseCount = 0 -- live flop+sink loops (capped at MAX_CORPSES; the overflow fast-pools)
local CORPSE_PRESSURE_ALIVE = 80 -- with this many zombies alive, corpses fast-pool too (ragdolls are
                                 -- the most expensive physics left — spend the budget on the living)

local function sinkAndRelease(record)
	local model = record.model
	corpseCount += 1
	if corpseCount > MAX_CORPSES or aliveCount > CORPSE_PRESSURE_ALIVE then
		-- Over the corpse budget: a short beat so the kill still reads, then pool immediately.
		task.wait(0.35)
		corpseCount -= 1
		release(record)
		return
	end
	task.wait(RAGDOLL_TIME)
	if not model.Parent then
		corpseCount -= 1
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
		corpseCount -= 1
		release(record)
		return
	end
	-- Slide each frozen part straight down in world space over SINK_TIME.
	-- 20Hz, not every frame (see RISE_STEP). Every part here is ANCHORED, so each write is its own
	-- replicated property change — at 60Hz, 12 settling corpses × a ~15-part rig was ~10k CFrame
	-- writes a second going out to every client. Over a 3.2s sink 20Hz looks identical.
	local elapsed = 0
	while elapsed < SINK_TIME and model.Parent do
		elapsed += task.wait(RISE_STEP)
		local drop = Vector3.new(0, -SINK_DEPTH * math.clamp(elapsed / SINK_TIME, 0, 1), 0)
		for p, cf in frozen do
			if p.Parent then
				p.CFrame = cf + drop
			end
		end
	end
	corpseCount -= 1
	release(record)
end

-- ===== DEATH =====
-- Forward declarations: these live in the STATUS EFFECTS section far below, but death (here, earlier in
-- the file) needs them — without the forward locals these calls silently resolve to nil globals.
local clearFrost
local spawnShatterVFX
local applyDamage -- defined right after onZombieDied (shatter chains + death are mutually recursive)

local function onZombieDied(record)
	if record.dead then
		return
	end
	record.dead = true
	record.model:SetAttribute("ZDead", true) -- NEW: clients (auto-aim) stop targeting the corpse instantly
	active[record.model] = nil
	-- Corpses are anonymous: hide our overhead tag the moment it dies (spawnOne re-arms it on reuse).
	if record.tag then
		record.tag.Enabled = false
	end
	-- Death GORE: clients render a goo burst at the body (bosses get the big send-off).
	if record.root then
		Remotes.Get("WorldVFX"):FireAllClients(record.isBoss and "bossgore" or "gore", {
			pos = record.root.Position,
			big = record.type and record.type.isSpecial == true or nil,
		})
	end
	if record.alignOr then
		record.alignOr.Enabled = false
	end
	clearFrost(record, false) -- drop the ice shell (the shatter below plays its own sound)
	if record.root then
		SoundFXService.Emit("ZDeath:" .. record.typeId, record.root.Position)
	end

	-- Freeze Ray SHATTER: a chilled zombie's death pops a frost nova that damages nearby zombies.
	-- (Chains are intentional: shattered kills of other chilled zombies shatter too.)
	if record.shatter and record.root and os.clock() < (record.chilledUntil or 0) then
		local pos = record.root.Position
		local cfg = record.shatter
		record.shatter = nil
		spawnShatterVFX(pos, cfg.radius or 10)
		SoundFXService.Emit("FrostShatter", pos, 140)
		for _, other in active do
			if other ~= record and not other.dead and other.root and (other.health or 0) > 0 then
				if (other.root.Position - pos).Magnitude <= (cfg.radius or 10) then
					applyDamage(other, cfg.damage or 45)
				end
			end
		end
	end

	-- Direction to launch the ragdoll: along the bullet's travel — from the shot origin toward the zombie,
	-- i.e. it flies backward away from the shooter. Falls back to "away from whoever it was facing".
	local kroot = record.root
	if kroot then
		local dir
		if record.lastHitOrigin then
			local d = kroot.Position - record.lastHitOrigin
			dir = Vector3.new(d.X, 0, d.Z)
		end
		if not dir or dir.Magnitude < 0.01 then
			local look = kroot.CFrame.LookVector
			dir = Vector3.new(-look.X, 0, -look.Z)
		end
		record.knockDir = (dir.Magnitude > 0.01) and dir.Unit or Vector3.new(0, 0, -1)
	end

	-- Boss bookkeeping: if this was the boss, tell clients to drop the health bar + show the defeat banner.
	if record == bossRecord then
		bossRecord = nil
		-- Where the boss fell — the wave's case drops burst out of the corpse (GameInventoryService).
		ZombieService.LastBossDeathPos = record.root and record.root.Position or nil
		ZombieService.LastBossDeathTime = os.clock()
		Remotes.Get("BossDefeated"):FireAllClients()
		bossDiedEvent:Fire(ZombieService.LastBossDeathPos) -- case drops ride on this (boss KILL, not wave end)
	end
	-- aliveCount is freed in release() (after the corpse linger), so corpses still count against the
	-- MaxAliveZombies cap until they're actually pooled — keeping true simultaneous bodies under the cap.

	record.speed = 0 -- the steer loop skips dead records; belt-and-braces
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
			local dir = record.knockDir or Vector3.new(0, 0, -1)
			root.AssemblyLinearVelocity = dir * KNOCKBACK_SPEED + Vector3.new(0, KNOCKBACK_UP, 0)
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
		-- Eligible = random-spawnable, unlocked by round, allowed on this map (worlds nil = every map), AND
		-- allowed by the difficulty roster. World-specific enemies (t.worlds set, e.g. Islands) BYPASS the
		-- roster whitelist so a map always showcases its own zombies at every difficulty; `exclude` still applies.
		return t.spawnWeight > 0 and round >= t.minRound
			and (t.worlds == nil or t.worlds[currentMap] == true)
			and (allowedTypes == nil or allowedTypes[id] == true or t.worlds ~= nil)
			and (excludedTypes == nil or excludedTypes[id] ~= true)
	end)
end

-- ===== CUSTOM HEALTH (no Humanoid) =====
-- THE single damage entry point. Health lives ONLY in the server-side record (even harder to exploit
-- than Humanoid.Health). Updates our overhead tag, feeds the boss bar, and triggers death at zero.
applyDamage = function(record, amount: number): boolean
	if record.dead or (record.health or 0) <= 0 then
		return false
	end
	record.health = math.max(0, record.health - amount)
	if record.tag and record.tagBar then -- show the tag on first blood; keep the bar honest
		record.tag.Enabled = true
		record.tagBar.Size = UDim2.new(math.clamp(record.health / math.max(1, record.maxHealth), 0, 1), 0, 1, 0)
	end
	if record.isBoss then
		Remotes.Get("BossHealth"):FireAllClients(record.health, record.maxHealth)
	end
	if record.health <= 0 then
		onZombieDied(record)
		return true
	end
	return false
end

-- Overhead name + health bar (replaces the Humanoid's built-in display). Lives on the Head, hidden
-- until the first hit; pooled models keep the instance and just get re-armed.
local function ensureTag(record)
	local head = record.model:FindFirstChild("Head") or record.root
	if not head then
		return
	end
	local bb = head:FindFirstChild("ZTag")
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "ZTag"
		bb.Size = UDim2.fromOffset(110, 34)
		bb.StudsOffset = Vector3.new(0, 2.2, 0)
		bb.AlwaysOnTop = false
		bb.MaxDistance = 120
		local nm = Instance.new("TextLabel")
		nm.Name = "Nm"
		nm.Size = UDim2.new(1, 0, 0, 18)
		nm.BackgroundTransparency = 1
		nm.Font = Enum.Font.GothamBold
		nm.TextSize = 12
		nm.TextColor3 = Color3.fromRGB(235, 235, 225)
		nm.TextStrokeTransparency = 0.2
		nm.Parent = bb
		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Position = UDim2.fromOffset(10, 22)
		track.Size = UDim2.new(1, -20, 0, 6)
		track.BackgroundColor3 = Color3.fromRGB(20, 22, 16)
		track.BorderSizePixel = 0
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(1, 0)
		tc.Parent = track
		track.Parent = bb
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = Color3.fromRGB(196, 40, 30)
		fill.BorderSizePixel = 0
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(1, 0)
		fc.Parent = fill
		fill.Parent = track
		bb.Parent = head
	end
	bb.Nm.Text = record.type.name or record.typeId
	bb.Track.Fill.Size = UDim2.fromScale(1, 1)
	-- CHANGED: grunts stay anonymous until first blood, but a BOMB ZOMBIE (looks like a grunt, explodes
	-- on you) and BOSSES are named from spawn — you must be able to identify and prioritize them before
	-- contact. The colored threat outline (client) is the at-a-distance signal; this is the name.
	local named = record.isBoss or record.typeId == "bombzombie"
	bb.Enabled = named
	record.tag = bb
	record.tagBar = bb.Track.Fill
end

-- ===== ZOMBIE ANIMATIONS (server-managed; played on the rig's Animator on the server, so every client
-- sees the same thing and it can't be tampered with client-side) =====
-- Walk: ONLY a configured AnimationConfig id plays a track. With no id, the client-side PROCEDURAL
-- animator (ZombieAnimController) drives the limbs instead — the model is stamped ZTrackAnim=false so
-- the client knows this rig is its to animate. (The old Roblox-catalog default walk is gone: a looping
-- track would fight the procedural Motor6D transforms.)

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
	local ac = record.model:FindFirstChildOfClass("AnimationController")
	local animator = ac and ac:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local cfg = AnimationConfig.Zombies[record.typeId] or AnimationConfig.Zombies.Default or {}
	local walk = AnimationConfig.Resolve(cfg.Walk)
	record.model:SetAttribute("ZTrackAnim", walk ~= nil) -- true = a real track owns the limbs
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

-- Spawn AT a ZombieSpawn-tagged part (place these where zombies should appear — e.g. in the shallows on
-- Islands so they wade ashore). Prefers points near a living player; falls back to any tagged point.
local function getSpawnPointCFrame(): CFrame?
	local pts = CollectionService:GetTagged("ZombieSpawn")
	if #pts == 0 then
		return nil
	end
	local playerPositions = {}
	for _, pl in Players:GetPlayers() do
		local char = pl.Character
		local r = char and char:FindFirstChild("HumanoidRootPart")
		local h = char and char:FindFirstChildOfClass("Humanoid")
		if r and h and h.Health > 0 then
			table.insert(playerPositions, r.Position)
		end
	end
	local near, all = {}, {}
	for _, p in pts do
		if p:IsA("BasePart") and p:IsDescendantOf(Workspace) then -- ignore points in maps tucked into ServerStorage
			table.insert(all, p)
			for _, pp in playerPositions do
				if (p.Position - pp).Magnitude <= SPAWNPOINT_NEAR then
					table.insert(near, p)
					break
				end
			end
		end
	end
	local pool = (#near > 0) and near or all
	if #pool == 0 then
		return nil
	end
	local part = pool[math.random(#pool)]
	-- Top surface of the part + a small random offset within its footprint so a busy point doesn't stack.
	local top = part.Position.Y + part.Size.Y * 0.5
	local ox = (math.random() - 0.5) * math.min(part.Size.X, 12)
	local oz = (math.random() - 0.5) * math.min(part.Size.Z, 12)
	return CFrame.new(part.Position.X + ox, top + SPAWN_HEIGHT, part.Position.Z + oz)
end

-- ===== SHORELINE SPAWNS (water maps) ===== the owner names the water parts "ocean" (and any crossings
-- "bridge"). Zombies surface IN the ocean just past the water's edge nearest a player — never on land and
-- never beside a bridge — then wade ashore. Parts are re-scanned whenever the active map changes.
local oceanParts: { BasePart } = {}
local bridgeParts: { BasePart } = {}
local scannedMap: Instance? = nil
local nextWaterScan = 0

-- Ocean/zombie collision channels: the ocean is solid ONLY for zombies. "OceanZ" collides with
-- "ZombieRig" (every zombie part rides in it — see prepModel) and nothing else, so players and props
-- keep falling/swimming through the water exactly as the map is built.
do
	local PhysicsService = game:GetService("PhysicsService")
	pcall(function()
		PhysicsService:RegisterCollisionGroup("OceanZ")
		PhysicsService:RegisterCollisionGroup("ZombieRig")
		PhysicsService:RegisterCollisionGroup("Players") -- idempotent (PlayerStateService owns it)
		PhysicsService:CollisionGroupSetCollidable("OceanZ", "ZombieRig", true)
		PhysicsService:CollisionGroupSetCollidable("OceanZ", "Default", false)
		PhysicsService:CollisionGroupSetCollidable("OceanZ", "Players", false)
		-- PERF: zombies do NOT collide with EACH OTHER — packed hordes were spending most of the
		-- physics budget shoving one another (they still hit players, the map, and the ocean).
		PhysicsService:CollisionGroupSetCollidable("ZombieRig", "ZombieRig", false)
	end)
end

local function isOceanPart(inst: Instance?): boolean
	return inst ~= nil and inst:IsA("BasePart") and inst.Name:lower():find("ocean", 1, true) ~= nil
end

local function scanWaterParts()
	local map = Workspace:FindFirstChild("ActiveMap") or Workspace
	local now = os.clock()
	if scannedMap == map and (#oceanParts > 0 or now < nextWaterScan) then
		return -- cached (empty results retry on a cooldown, not per spawn)
	end
	scannedMap = map
	nextWaterScan = now + 5
	oceanParts, bridgeParts = {}, {}
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") then
			local n = d.Name:lower()
			if n:find("ocean", 1, true) then
				table.insert(oceanParts, d)
				-- Solid for ZOMBIES ONLY (see the OceanZ collision group above): they wade on the
				-- surface; players still pass through like the non-collidable water it was built as.
				d.CollisionGroup = "OceanZ"
				d.CanCollide = true
			elseif n:find("bridge", 1, true) then
				table.insert(bridgeParts, d)
			end
		end
	end
end

-- Distance from `pos` to the closest point on any bridge part's box.
local function nearBridge(pos: Vector3): boolean
	for _, b in bridgeParts do
		if b.Parent then
			local lp = b.CFrame:PointToObjectSpace(pos)
			local half = b.Size * 0.5
			local clamped = Vector3.new(
				math.clamp(lp.X, -half.X, half.X),
				math.clamp(lp.Y, -half.Y, half.Y),
				math.clamp(lp.Z, -half.Z, half.Z)
			)
			if (b.CFrame:PointToWorldSpace(clamped) - pos).Magnitude < BRIDGE_CLEAR then
				return true
			end
		end
	end
	return false
end

-- March outward from a random player until the downcast first lands on an "ocean" part — that's the
-- water's edge on the side nearest them. Surface just PAST the edge, on the water, clear of bridges.
-- (A bridge deck over the water reads as land, so the march naturally skips water under bridges.)
local function getShorelineCFrame(): CFrame?
	scanWaterParts()
	if #oceanParts == 0 then
		return nil -- no "ocean"-named parts on this map
	end
	local roots = {}
	for _, pl in Players:GetPlayers() do
		local char = pl.Character
		local r = char and char:FindFirstChild("HumanoidRootPart")
		local h = char and char:FindFirstChildOfClass("Humanoid")
		if r and h and h.Health > 0 then
			table.insert(roots, r)
		end
	end
	if #roots == 0 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	-- Raycast AS A ZOMBIE: ocean parts live in the OceanZ group which does NOT collide with Default,
	-- so a default-group ray passes straight through the water and never finds the shoreline.
	params.CollisionGroup = "ZombieRig"
	local filter: { Instance } = { zombieFolder, graveFolder }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(filter, pl.Character)
		end
	end
	params.FilterDescendantsInstances = filter

	local function oceanBelow(x: number, z: number, castY: number): RaycastResult?
		local hit = Workspace:Raycast(Vector3.new(x, castY, z), Vector3.new(0, -300, 0), params)
		return (hit and isOceanPart(hit.Instance)) and hit or nil
	end

	for _ = 1, 14 do -- random player + random direction per attempt
		local origin = roots[math.random(#roots)].Position
		local castY = origin.Y + 90
		local ang = math.random() * 2 * math.pi
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local t = SHORE_STEP
		while t <= SHORE_MAX_MARCH do
			local p = origin + dir * t
			local hit = Workspace:Raycast(Vector3.new(p.X, castY, p.Z), Vector3.new(0, -300, 0), params)
			if not hit then
				break -- marched off the map — try another direction
			end
			if isOceanPart(hit.Instance) then
				-- Found the water's edge. Surface a touch further out (still confirmed over ocean).
				local out = oceanBelow(p.X + dir.X * SHORE_OUT, p.Z + dir.Z * SHORE_OUT, castY)
				local surface = (out or hit).Position
				if not nearBridge(surface) and not SpawnZones.IsBlocked(surface) then
					return CFrame.new(surface)
				end
				break -- edge found but blocked (bridge/fog) — try another direction
			end
			t += SHORE_STEP
		end
	end
	return nil
end

-- Pick where the next zombie surfaces. Water maps (Islands) surface at the ocean's edge nearest a player
-- (parts named "ocean"), then ZombieSpawn-tagged parts, then the Forest near-player fallback — so the map
-- still functions while it's half-built.
local function getSpawnCFrame(): CFrame?
	if mapEmerge == "water" then
		local cf = getShorelineCFrame()
		if cf then
			return cf
		end
	end
	if mapUseSpawnPoints then
		local cf = getSpawnPointCFrame()
		if cf then
			return cf
		end
		-- No ZombieSpawn points tagged yet — fall through to near-player so the map still functions.
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
	for _ = 1, 12 do
		local root = candidates[math.random(#candidates)]
		local angle = math.random() * 2 * math.pi
		local cf = CFrame.new(root.Position + Vector3.new(math.cos(angle) * 35, SPAWN_HEIGHT, math.sin(angle) * 35))
		if not tooCloseToActiveGrave(cf.Position) and not SpawnZones.IsBlocked(cf.Position) then
			return cf -- clear of other graves AND outside the out-of-bounds fog
		end
	end
	return nil
end

-- ===== GRAVES (props cloned above each spawn; the zombie rises out from under them) =====
-- Grave models live in Assets > Graves (Grave1, Grave2, ...). Loaded once; a random one is cloned per spawn.
local function loadGraveTemplates()
	local regular, big, huge = {}, {}, {}
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		local gf = assets and ciFind(assets, "Graves")
		if gf then
			for _, c in gf:GetChildren() do
				local m = asModel(c)
				if m then
					local n = m.Name:lower()
					if n:match("^huge") then       -- HugeGrave1/2 -> boss
						table.insert(huge, m)
					elseif n:match("^big") then    -- BigGrave1/2 -> tanks
						table.insert(big, m)
					else                            -- Grave1/2 -> normal enemies
						table.insert(regular, m)
					end
				end
			end
		end
	end
	graveTemplates = regular
	bigGraveTemplates = big
	hugeGraveTemplates = huge
end

-- Water emergence props (Islands): optional Models under Assets > Splashes (Splash1, Splash2, ...). If none
-- exist a simple procedural water ring is used, so Islands works before the owner builds splash models.
local splashTemplates: { Model } = {}
local function loadWaterTemplates()
	local list = {}
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		local sf = assets and ciFind(assets, "Splashes")
		if sf then
			for _, c in sf:GetChildren() do
				local m = asModel(c)
				if m then
					table.insert(list, m)
				end
			end
		end
	end
	splashTemplates = list
end

-- Find the ground under a point: returns (groundY, surfaceNormal). Ignores zombies, players, and grave
-- props so it hits the real terrain/ramps. The normal points straight up over flat ground and tilts with
-- the slope on a ramp — graves use it to lie flush against (and rise out of) the ramp surface.
local function findGround(x: number, z: number, fallbackY: number): (number, Vector3)
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
	if hit then
		return hit.Position.Y, hit.Normal
	end
	return fallbackY, Vector3.yAxis
end

-- Build a rotation whose UP axis is `normal` (so a model lies flush on a ramp), with a random `yaw` spin
-- around that normal. Falls back to straight-up over degenerate normals.
local function orientationFromNormal(normal: Vector3, yaw: number): CFrame
	local up = (normal.Magnitude > 1e-4) and normal.Unit or Vector3.yAxis
	-- A reference axis that's never parallel to `up`, so the cross products stay well-defined.
	local ref = (math.abs(up.Y) > 0.99) and Vector3.xAxis or Vector3.yAxis
	local right = up:Cross(ref)
	right = (right.Magnitude > 1e-4) and right.Unit or Vector3.xAxis
	return CFrame.fromMatrix(Vector3.zero, right, up) * CFrame.Angles(0, yaw, 0)
end

-- Rise a random grave headstone UP out of the ground at (x, z), hold it while the zombie emerges, then
-- sink it away. `tier` = "huge" (boss) | "big" (tank) | nil (regular); falls back to regular if that tier
-- has no models. Props are non-colliding + non-queryable so they never block movement/shots/ground checks.
local function placeGrave(x: number, groundY: number, z: number, normal: Vector3, tier: string?)
	local list = graveTemplates
	if tier == "huge" and #hugeGraveTemplates > 0 then
		list = hugeGraveTemplates
	elseif tier == "big" and #bigGraveTemplates > 0 then
		list = bigGraveTemplates
	end
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

	-- Orient the headstone so its UP axis follows the ground's surface normal (diagonal on a ramp, upright
	-- on flat ground), with a random yaw so every stone faces a different way. Do this BEFORE measuring.
	local up = (normal.Magnitude > 1e-4) and normal.Unit or Vector3.yAxis
	local orient = orientationFromNormal(normal, math.random() * 2 * math.pi)
	grave:PivotTo(orient + grave:GetPivot().Position)

	-- Measure along the (now tilted) grave's own axes — size.Y is its height along the normal.
	local cf, size = grave:GetBoundingBox()
	local riseDepth = size.Y + 1 -- fully bury it under the surface so the whole stone can rise out
	-- Fully-risen pose: the stone's bottom face sits on the ground point, so its centre is half its height
	-- UP the normal. Buried pose: that centre pushed riseDepth DOWN the normal.
	local groundPos = Vector3.new(x, groundY, z)
	local risenCenter = groundPos + up * (size.Y * 0.5)
	local buriedCenter = risenCenter - up * riseDepth
	grave:PivotTo(grave:GetPivot() + (buriedCenter - cf.Position))
	grave.Parent = graveFolder
	local buriedCF = grave:GetPivot()

	task.spawn(function()
		-- 1) the headstone rises up out of the ground FIRST — ALONG the surface normal.
		local elapsed = 0
		while elapsed < GRAVE_RISE_TIME and grave.Parent do
			elapsed += task.wait(RISE_STEP) -- 20Hz, not every frame (see RISE_STEP)
			grave:PivotTo(buriedCF + up * (riseDepth * math.clamp(elapsed / GRAVE_RISE_TIME, 0, 1)))
		end
		if not grave.Parent then
			return
		end
		grave:PivotTo(buriedCF + up * riseDepth) -- fully up, flush with the surface
		-- 2) hold while the zombie climbs out + lingers.
		task.wait(EMERGE_TIME + GRAVE_LINGER)
		-- 3) sink the stone back along the normal and despawn.
		local sinkStart = grave:GetPivot()
		elapsed = 0
		while elapsed < GRAVE_SINK_TIME and grave.Parent do
			elapsed += task.wait(RISE_STEP) -- 20Hz, not every frame (see RISE_STEP)
			grave:PivotTo(sinkStart - up * (riseDepth * math.clamp(elapsed / GRAVE_SINK_TIME, 0, 1)))
		end
		grave:Destroy()
	end)
end

-- Water emergence (Islands): a splash where the zombie surfaces. Clones an Assets>Splashes model if the owner
-- built one; otherwise spawns a quick expanding water ring. Non-colliding; fades and cleans itself up.
local function placeSplash(x: number, surfaceY: number, z: number)
	local pos = Vector3.new(x, surfaceY, z)
	if #splashTemplates > 0 then
		local splash = splashTemplates[math.random(#splashTemplates)]:Clone()
		for _, p in splash:GetDescendants() do
			if p:IsA("BasePart") then
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
			end
		end
		splash:PivotTo(CFrame.new(pos))
		splash.Parent = graveFolder
		task.delay(GRAVE_LINGER, function()
			for _, p in splash:GetDescendants() do
				if p:IsA("BasePart") then
					pcall(function()
						p.Transparency = math.min(1, p.Transparency + 0.5)
					end)
				end
			end
			task.wait(0.4)
			splash:Destroy()
		end)
		return
	end
	-- Procedural fallback: a flat translucent disc that expands and fades (reads as water spray).
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.Material = Enum.Material.Water
	ring.Color = Color3.fromRGB(180, 220, 240)
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.6, 4, 4)
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)) -- lay the cylinder flat = a disc on the surface
	ring.Parent = graveFolder
	task.spawn(function()
		local elapsed = 0
		while elapsed < 1 and ring.Parent do
			elapsed += task.wait()
			local a = math.clamp(elapsed, 0, 1)
			ring.Size = Vector3.new(0.6, 4 + 16 * a, 4 + 16 * a)
			ring.Transparency = 0.2 + 0.8 * a
		end
		ring:Destroy()
	end)
end

-- Emergence: props above the spawn (a grave on land, a splash on water), then raise the buried zombie to the
-- surface over EMERGE_TIME. AI is suppressed (record.emerging) until it's out, then chasing takes over.
local function startEmergence(record, spawnCF: CFrame)
	local model = record.model
	local root = record.root
	local pos = spawnCF.Position
	-- The zombie itself always stands upright (the Humanoid balances it); only a grave follows the slope.
	local groundY, groundNormal
	if mapEmerge == "water" then
		groundY, groundNormal = pos.Y, Vector3.yAxis -- the ZombieSpawn point is placed AT the water surface
		placeSplash(pos.X, groundY, pos.Z)
		Remotes.Get("WorldVFX"):FireAllClients("splash", { pos = Vector3.new(pos.X, groundY, pos.Z) })
		-- (Footing comes from the ocean itself: ocean parts are solid for the ZombieRig collision
		-- group only, so the zombie stands on the water surface and wades ashore.)
	else
		groundY, groundNormal = findGround(pos.X, pos.Z, pos.Y)
		placeGrave(pos.X, groundY, pos.Z, groundNormal, GRAVE_TIER[record.typeId])
		Remotes.Get("WorldVFX"):FireAllClients("dig", { pos = Vector3.new(pos.X, groundY, pos.Z) })
	end
	local finalCF = CFrame.new(pos.X, groundY + GRAVE_STAND_HEIGHT, pos.Z)

	record.emerging = true
	-- Anchor ONLY the root during the rise. The rig's joints keep the limbs glued to the root, so it
	-- rises as one piece (anchoring every part then releasing made it fall over).
	root.Anchored = true
	local base = finalCF + Vector3.new(0, -EMERGE_DEPTH, 0)
	model:PivotTo(base)
	task.spawn(function()
		task.wait(GRAVE_RISE_TIME) -- let the headstone rise out of the ground FIRST, then the zombie climbs out
		local elapsed = 0
		while elapsed < EMERGE_TIME and model.Parent and not record.dead do
			elapsed += task.wait(RISE_STEP) -- 20Hz, not every frame (see RISE_STEP)
			local a = math.clamp(elapsed / EMERGE_TIME, 0, 1)
			model:PivotTo(base + Vector3.new(0, EMERGE_DEPTH * a, 0))
		end
		if model.Parent and not record.dead then
			model:PivotTo(finalCF)
			root.Anchored = false
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			pcall(function()
				root:SetNetworkOwner(nil)
			end)
		end
		record.emerging = false
	end)
end

-- Spawn one zombie. `forcedType` overrides the random pick (used by the boss). Returns the record (or nil).
-- CHANGED: optional `atCF` places the spawn THERE (events: meteor craters, vault guards) — it must flow
-- into startEmergence, because a PivotTo after the fact was overwritten by the emergence rise.
local function spawnOne(round: number, forcedType: string?, atCF: CFrame?)
	local spawnCF = atCF or getSpawnCFrame()
	if not spawnCF then
		return nil
	end
	-- EVENT MIX (the wheel): an active wave modifier can bias the spawn table — e.g. BOMB SQUAD makes
	-- ~40% of spawns bomb zombies, THE PURGE forces 100% regulars, BLOODHOUNDS salts in the dogs.
	if not forcedType and eventMix then
		local r = math.random()
		local acc = 0
		for _, m in eventMix do
			acc += m.share
			if r < acc then
				forcedType = m.id
				break
			end
		end
	end
	local typeId = forcedType or pickType(round) or "default"
	local t = ZOMBIE_TYPES[typeId]
	if not t then
		return nil
	end

	local model = acquire(typeId, t)
	local root = model.PrimaryPart
	if not root then
		return nil
	end

	-- (ELITE golden zombies REMOVED — every spawn is a plain roll of its type now.)
	local hp = scaledHealth(round, t)
	local spd = scaledSpeed(round, t)

	-- CUSTOM UPRIGHT: no Humanoid balancing — an AlignOrientation keeps the rig standing + facing its
	-- move direction (disabled on death so ragdolls tumble freely; re-armed here on pooled reuse).
	local att = root:FindFirstChild("ZAlignAtt")
	if not att then
		att = Instance.new("Attachment")
		att.Name = "ZAlignAtt"
		att.Parent = root
	end
	local alignOr = root:FindFirstChild("ZAlignOr")
	if not alignOr then
		alignOr = Instance.new("AlignOrientation")
		alignOr.Name = "ZAlignOr"
		alignOr.Mode = Enum.OrientationAlignmentMode.OneAttachment
		alignOr.Attachment0 = att
		alignOr.MaxTorque = 1e6
		alignOr.MaxAngularVelocity = 40
		alignOr.Responsiveness = 60
		alignOr.Parent = root
	end
	alignOr.CFrame = spawnCF.Rotation + Vector3.zero
	alignOr.Enabled = true

	-- Stamp the type's point value on the model so PointsService can award without a cross-service lookup.
	model:SetAttribute("PointsMult", t.pointsMult)
	model:SetAttribute("IsSpecial", t.isSpecial)
	-- NEW: the type id + threat flags, so the CLIENT can color threat outlines and identify dangerous
	-- archetypes AT A DISTANCE (the "specials force you to move" loop). Many high-threat types
	-- (bomb/lead/leaper/ghost/speedy) aren't flagged isSpecial, so the client keys off ZType directly.
	model:SetAttribute("ZType", t.id)
	model:SetAttribute("ZBomb", t.isBomb == true)
	-- NEW: aliveness flag for clients (no Humanoid to read anymore) — AimController skips ZDead corpses.
	model:SetAttribute("ZDead", false)

	model:PivotTo(spawnCF)
	model.Parent = zombieFolder

	-- Stand height: how far the root's centre sits above the rig's FEET (bounding-box bottom). The hover
	-- spring holds the root here so legs touch the ground instead of the torso resting on it.
	local hipY = 2.6
	do
		local ok, bbCF, bbSize = pcall(function()
			local cf, size = model:GetBoundingBox()
			return cf, size
		end)
		if ok and bbCF and bbSize then
			hipY = math.max(1, root.Position.Y - (bbCF.Position.Y - bbSize.Y / 2))
		end
	end

	-- Keep the server authoritative over zombie physics (perf + anti-exploit).
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	local now = os.clock()
	local record = {
		model = model,
		root = root,
		typeId = typeId,
		type = t,
		health = hp,            -- CUSTOM health: lives in this record only (see applyDamage)
		maxHealth = hp,
		hipY = hipY,            -- root height above the feet — the hover spring holds it here
		speed = spd,            -- CUSTOM WalkSpeed replacement — the steer loop drives velocity from this
		baseSpeed = spd,        -- statusSpeed() restores to this after chills/pins expire
		alignOr = alignOr,
		damage = t.damage * difficultyMult * (GameConfig.ZombieDamageMult or 1),
		target = nil,
		targetRoot = nil,
		mode = "idle",          -- "idle" | "direct" (live chase) | "path" (navigating obstacles)
		waypoints = nil,
		waypointIndex = 1,
		computing = false,
		lastPath = 0,
		lastAttack = 0,
		nextLeap = 0,           -- Leaper pounce cooldown clock
		leapUntil = 0,          -- while os.clock() < this, the Leaper is mid-pounce (don't drive it)
		fuseLit = false,        -- BombZombie: has the fuse started
		fuseEnd = 0,            -- BombZombie: os.clock() the fuse detonates
		exploded = false,       -- BombZombie: already blew up
		nextSummon = 0,         -- Necromancer: summon cooldown clock
		ghostNextDive = 0,      -- Ghost: dive cooldown clock
		ghostDiveUntil = 0,     -- Ghost: while os.clock() < this, it's dropping on a dive
		nextJumpCheck = 0,
		spawnTime = now,
		nextThink = now + math.random() * GameConfig.ZombieAITickRate, -- stagger
		dead = false,
		emerging = false,
		lastPos = root.Position,    -- for stuck detection
		lastMoveTime = now,
		pathFailed = false,
	}
	-- (No Humanoid.Died — applyDamage() calls onZombieDied directly at zero health.)
	ensureTag(record)

	active[model] = record
	aliveCount += 1
	loadZombieTracks(record)

	-- First appearance of a NEW enemy type this run → "INCOMING!" banner for everyone. Starters
	-- (minRound 1) and bosses (spawnWeight 0 — they get their own entrance banner) are skipped.
	if not announcedTypes[typeId] and t.spawnWeight > 0 and (t.minRound or 1) > 1 then
		announcedTypes[typeId] = true
		Remotes.Get("EnemyIncoming"):FireAllClients(t.name or typeId)
	end

	-- RARE (special) zombies announce themselves with a scream from their spawn point. Bosses are
	-- excluded (spawnWeight 0) — they get their own entrance roar when the boss wave summons them.
	if t.isSpecial and t.spawnWeight > 0 then
		SoundFXService.Emit("RareScream", spawnCF.Position, 220)
	end

	-- Rise up out of the ground (under a grave headstone) before the AI kicks in.
	startEmergence(record, spawnCF)

	return record
end

-- ===== SPECIAL BEHAVIORS (BombZombie / Ghost / Necromancer) =====
-- Expanding neon blast sphere (server-made, so everyone sees it).
local function spawnExplosionVFX(pos: Vector3)
	-- Layered client-side detonation (WorldVFXController) — the server only announces it.
	Remotes.Get("WorldVFX"):FireAllClients("boom", { pos = pos, r = BOMB_RADIUS })
end

-- BombZombie detonation: damage players in radius (falls off to 0 at the edge), flash, and die.
local function explode(record)
	if record.exploded then
		return
	end
	record.exploded = true
	local root = record.root
	local pos = root and root.Position
	if pos then
		for _, pl in Players:GetPlayers() do
			local char = pl.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hrp and hum and hum.Health > 0 then
				local d = (hrp.Position - pos).Magnitude
				if d <= BOMB_RADIUS then
					local dmg = BOMB_DAMAGE * (1 - d / BOMB_RADIUS) * (GameConfig.ZombieDamageMult or 1)
					if dmg > 0 then
						PlayerStateService.Damage(pl, dmg, "explosion", pos)
					end
				end
			end
		end
		-- BOMB SQUAD (event wheel): the blast chains into OTHER zombies too — killing a bomber inside
		-- the horde sets off fireworks (a chained bomber's own death re-enters here and keeps going).
		if bombChain then
			for _, rec in active do
				local r2 = rec.root
				if rec ~= record and not rec.dead and r2 then
					local d2 = (r2.Position - pos).Magnitude
					if d2 <= BOMB_RADIUS then
						applyDamage(rec, BOMB_DAMAGE * (1 - d2 / BOMB_RADIUS))
					end
				end
			end
		end
		spawnExplosionVFX(pos)
		SoundFXService.Emit("Explosion", pos, 220)
	end
	applyDamage(record, math.huge) -- dies in its own blast
end

-- Necromancer: raise `n` extra grunts, respecting the alive cap.
local function summonAdds(n: number)
	for _ = 1, n do
		if aliveCount >= GameConfig.MaxAliveZombies then
			break
		end
		spawnOne(currentRound, "default")
	end
end

-- ===== STATUS EFFECTS (weapon abilities) =====
local ICE_TINT = Color3.fromRGB(130, 190, 255)

-- Freeze Ray: freeze/slow the zombie (slowPct 1 = frozen SOLID in an ice shell); remember the shatter
-- payload so its death pops a frost AoE. Follow-up hits while frozen just refresh the timer — the
-- frozen sound + ice shell only trigger on the FIRST hit of a freeze.
function ZombieService.Chill(record, chillCfg, shatterCfg)
	if not record or record.dead then
		return
	end
	local slow = chillCfg.slowPct or 0.3
	local secs = chillCfg.secs or 2
	-- Bosses can't be frozen SOLID (an auto freeze ray would perma-lock them) — they take a
	-- half-strength slow instead.
	if record.isBoss and slow >= 0.999 then
		slow, secs = 0.5, 2
	end
	record.slowPct = slow
	record.chilledUntil = os.clock() + secs
	record.shatter = shatterCfg
	if not record.frostTint then
		record.frostTint = true
		recolor(record.model, ICE_TINT)
		local root = record.root
		-- The ice block + frozen sound only accompany a REAL freeze (slowed zombies just tint blue).
		if root and slow >= 0.999 then
			SoundFXService.Emit("ZombieFrozen", root.Position, 130)
			-- Encase the zombie in a translucent ice block sized to its body.
			local okBB, cf, size = pcall(function()
				return record.model:GetBoundingBox()
			end)
			local ice = Instance.new("Part")
			ice.Name = "IceShell"
			ice.Material = Enum.Material.Ice
			ice.Color = ICE_TINT
			ice.Transparency = 0.45
			ice.CanCollide = false
			ice.CanQuery = false
			ice.CanTouch = false
			ice.Massless = true
			ice.CastShadow = false
			if okBB and typeof(size) == "Vector3" then
				ice.Size = size + Vector3.new(0.7, 0.7, 0.7)
				ice.CFrame = cf
			else
				ice.Size = Vector3.new(4.7, 6.7, 3.7)
				ice.CFrame = root.CFrame
			end
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = root
			wc.Part1 = ice
			wc.Parent = ice
			ice.Parent = record.model
		end
	end
end

-- Melt a frozen zombie back to normal (thaw or death): drop the ice shell + base colors.
-- (Assigns the forward-declared local above onZombieDied — do NOT re-localize.)
function clearFrost(record, playBreak: boolean)
	if not record.frostTint then
		return
	end
	record.frostTint = nil
	restoreColors(record.model)
	local shell = record.model and record.model:FindFirstChild("IceShell")
	if shell then
		shell:Destroy()
		if playBreak then -- only actual ice makes a breaking sound (slow-only chills just untint)
			SoundFXService.Emit("IceBreak", record.root and record.root.Position or nil, 130)
		end
	end
end

-- Crossbow: nail the zombie in place.
function ZombieService.Pin(record, secs)
	if not record or record.dead then
		return
	end
	record.pinnedUntil = os.clock() + (secs or 2)
end

-- Per-frame speed from active statuses (called from steer). Cheap: two clock compares + one field write.
local function statusSpeed(record, now)
	local base = record.baseSpeed
	if not base then
		return
	end
	local target = base * globalSpeedMult -- BLOOD MOON: the whole horde runs hot for the wave
	if now < (record.pinnedUntil or 0) then
		target = 0
	elseif now < (record.chilledUntil or 0) then
		target = base * globalSpeedMult * (1 - (record.slowPct or 0))
	end
	record.speed = target
	if record.frostTint and now >= (record.chilledUntil or 0) then
		clearFrost(record, true) -- the ice breaks as the freeze wears off
	end
end

-- ===== CUSTOM LOCOMOTION (no Humanoid) ===== velocity-driven walking + an AlignOrientation upright.
-- setVel: horizontal velocity toward `dir` at record.speed (gravity keeps the Y component). Also turns
-- the rig to face its travel. Passing a ~zero dir stops it (grounded zombies don't slide).
local JUMP_VEL = 34 -- vertical launch for ledge hops (~the old JumpPower 55 feel)
local function setVel(record, dir: Vector3)
	local root = record.root
	if not root then
		return
	end
	local v = root.AssemblyLinearVelocity
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.05 or (record.speed or 0) <= 0 then
		root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
		return
	end
	local d = flat.Unit
	root.AssemblyLinearVelocity = Vector3.new(d.X * record.speed, v.Y, d.Z * record.speed)
	if record.alignOr then
		record.alignOr.CFrame = CFrame.lookAlong(Vector3.zero, d) -- face the way it's walking
	end
end

-- grounded: short downcast from the root (jumps/leaps only fire with footing, like Humanoid states did).
local function grounded(record): boolean
	local root = record.root
	if not root then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Exclude EVERY zombie, not just this one: zombies don't collide with each other, so a ray that
	-- lands on a packed horde-mate must not count as footing (that was the "stacking" bug — hover
	-- perched walkers on each other's heads).
	params.FilterDescendantsInstances = { zombieFolder }
	return Workspace:Raycast(root.Position, Vector3.new(0, -4.5, 0), params) ~= nil
end

local function jump(record)
	if not grounded(record) then
		return
	end
	local root = record.root
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, JUMP_VEL, v.Z)
end

-- HOVER SPRING: the Humanoid used to levitate the root at hip height — without it the rig sinks until
-- the root part rests on the floor (torso on the ground, legs inside it). Each steer frame, if the root
-- sits BELOW its measured stand height (record.hipY, taken from the rig's bounding box at spawn), push
-- it up with a proportional vertical velocity. Push-up only — never pulls down — so jumps, leaps, and
-- falling off ledges keep their natural arcs (root above target = gravity handles it).
local HOVER_SPRING = 10  -- upward studs/sec per stud of sink
local HOVER_MAX = 50     -- vertical correction cap
local function hover(record)
	local root = record.root
	if not root or root.Anchored then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { zombieFolder } -- ignore ALL zombies (see grounded) — real ground only
	-- Cast from ABOVE the root: if the rig has already punched into the floor, a ray from root height
	-- starts INSIDE the floor part and sails through it (that was the freeze-ray "zombie in the ground"
	-- bug — rapid knockback resets let it penetrate, then the ray missed the surface it was under).
	local top = root.Position + Vector3.new(0, 2.5, 0)
	local hit = Workspace:Raycast(top, Vector3.new(0, -(record.hipY + 5), 0), params)
	if not hit then
		return -- airborne / over a drop: let gravity have it
	end
	local err = (hit.Position.Y + record.hipY) - root.Position.Y
	if err > 1.2 then
		-- Deep in the floor: SNAP back to stand height (what the Humanoid hip solver used to do) —
		-- a velocity push would leave it visibly buried for several frames.
		record.model:PivotTo(root.CFrame + Vector3.new(0, err, 0))
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
	elseif err > 0.05 then
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, math.clamp(err * HOVER_SPRING, 2, HOVER_MAX), v.Z)
	end
end

-- Frozen SOLID (a full Freeze Ray chill, slowPct >= 1): no walking, no diving, no biting until it breaks.
local function isFrozen(record, now: number): boolean
	return now < (record.chilledUntil or 0) and (record.slowPct or 0) >= 0.999
end

-- Frost nova visual for a shattered corpse. (Assigns the forward-declared local above onZombieDied.)
function spawnShatterVFX(pos, radius)
	-- Ice-shard burst + cold mist, rendered client-side (WorldVFXController "shatter").
	Remotes.Get("WorldVFX"):FireAllClients("shatter", { pos = pos, r = radius })
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

-- Leaper pounce: a `canLeap` zombie periodically launches itself in a ballistic arc toward the player to
-- close a big gap, so distance/cover doesn't keep you safe. Only from the GROUND, from a medium distance,
-- with line of sight, and on cooldown. The horizontal speed is solved so it lands roughly ON the player
-- (projectile math from the fixed launch height), capped so a long pounce isn't absurdly fast.
local function tryLeap(record, now: number, targetRoot: BasePart, flatDist: number)
	local t = record.type
	if not (t and t.canLeap) then
		return
	end
	if now < (record.nextLeap or 0) then
		return
	end
	if flatDist < LEAP_MIN_DIST or flatDist > LEAP_MAX_DIST then
		return
	end
	local root = record.root
	if not root then
		return
	end
	-- Must be grounded (don't re-pounce mid-air) and able to see the target (don't pounce into a wall).
	if not grounded(record) then
		return
	end
	if sightBlocked(root.Position, targetRoot.Position) then
		return
	end

	record.nextLeap = now + LEAP_COOLDOWN
	local to = targetRoot.Position - root.Position
	local horiz = Vector3.new(to.X, 0, to.Z)
	local dir = horiz.Magnitude > 0.01 and horiz.Unit or root.CFrame.LookVector
	-- Time aloft for the fixed vertical launch, then the horizontal speed that covers `flatDist` in that time.
	local g = math.max(1, Workspace.Gravity)
	local airTime = 2 * LEAP_UP_SPEED / g
	local hSpeed = math.min(LEAP_MAX_HSPEED, (flatDist * LEAP_REACH_FRAC) / airTime)

	-- Mark the pounce window so steer() stops driving it: while grounded the Humanoid's walk controller damps
	-- horizontal velocity back to WalkSpeed (which made it "just jump straight up"). Put it in the Jumping
	-- state and leave it physics-only for the flight so the ballistic arc actually carries it AT the player.
	record.leapUntil = now + airTime + 0.15
	root.AssemblyLinearVelocity = dir * hSpeed + Vector3.new(0, LEAP_UP_SPEED, 0)
	if record.attackTrack then
		record.attackTrack:Play(0.05) -- reuse the attack/lunge anim as the pounce, if one is set
	end
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

	-- Ambient growl: each zombie voices off every 6-14s, globally throttled (SoundConfig.GrowlMinGap) so
	-- a full horde is a murmur, not a wall of sound. Distance filtering happens in SoundFXService.Emit.
	if now >= (record.nextGrowl or 0) then
		record.nextGrowl = now + math.random(60, 140) / 10
		-- Bosses roar ONCE on entry (ZRoar at spawn) and never growl ambiently.
		if not record.isBoss and (now - lastGrowlEmit) >= SoundConfig.GrowlMinGap then
			lastGrowlEmit = now
			SoundFXService.Emit("ZGrowl:" .. record.typeId, root.Position, 80)
		end
	end

	-- Water maps: steer's edge probe flags open water ahead — treat it like blocked sight so the
	-- zombie pathfinds AROUND the ocean (over bridges / along the shore) instead of walking into it.
	local waterAhead = mapEmerge == "water" and now < (record.avoidWaterUntil or 0)

	if blocked or stuck or waterAhead then
		-- Navigate AROUND geometry. Recompute toward the player's CURRENT position; retry fast after a
		-- failure or while wedged, otherwise sparsely (perf).
		record.mode = "path"
		local interval = record.pathFailed and PATH_RETRY or GameConfig.PathRecompute
		if stuck or waterAhead then
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

	-- Damage-on-touch is handled per-frame in steer(). Here, if we're NOT in contact, a Leaper may pounce.
	local toPlayer = targetRoot.Position - root.Position
	local flatDist = Vector3.new(toPlayer.X, 0, toPlayer.Z).Magnitude
	local frozen = isFrozen(record, now) -- frozen SOLID: no pouncing, no fuse-lighting until the ice breaks
	if flatDist > ATTACK_RANGE and not frozen then
		tryLeap(record, now, targetRoot, flatDist)
	end

	local t = record.type
	-- BombZombie: light the fuse when close, then detonate a couple seconds later. (An ALREADY-lit fuse
	-- still detonates through a freeze — freezing stops it lighting, not burning.)
	if t and t.isBomb and not record.exploded then
		if not record.fuseLit and flatDist <= BOMB_TRIGGER and not frozen then
			record.fuseLit = true
			record.fuseEnd = now + BOMB_FUSE
			recolor(record.model, DEATH_COLOR) -- warning flash while the fuse burns
			SoundFXService.Emit("BombFuse", record.root and record.root.Position or nil)
		end
		if record.fuseLit and now >= record.fuseEnd then
			explode(record)
			return
		end
	end

	-- Necromancer: raise extra grunts on a cooldown (on top of the wave's own spawns). DEFERRED: spawning
	-- inserts new keys into `active` and this think() runs inside onHeartbeat's iteration of `active` —
	-- mutating a table mid-iteration is undefined (can error/skip records), so the spawns land next step.
	if t and t.summons and now >= (record.nextSummon or 0) then
		record.nextSummon = now + SUMMON_CD
		task.defer(summonAdds, SUMMON_COUNT)
		SoundFXService.Emit("SummonCast", root.Position, 160)
	end

	-- Backstop: a zombie wedged for STUCK_TIMEOUT (or alive too long) force-kills itself so the round
	-- can't soft-lock on something unreachable. NEVER applies to bosses — a long boss fight is normal, and
	-- force-killing one would fire "Boss Defeated" (and even a free victory on the final wave).
	if not record.isBoss and record ~= bossRecord then
		if (now - record.lastMoveTime) > STUCK_TIMEOUT or (now - record.spawnTime) > MAX_LIFETIME then
			applyDamage(record, math.huge)
			return
		end
	else
		-- FIX (boss soft-lock): a boss can't force-kill itself (that fires "Boss Defeated" / a free
		-- victory), so a boss that hasn't moved for BOSS_UNSTUCK is RELOCATED to a fresh valid spawn
		-- near a living player — breaking any unreachable-geometry / stranded-island lock without ending
		-- the fight. Throttled so it can't teleport-spam; the wave loop can no longer spin forever.
		if (now - record.lastMoveTime) > BOSS_UNSTUCK and now >= (record.nextRelocate or 0) then
			local cf = getSpawnCFrame()
			if cf then
				if record.model and record.model.PrimaryPart then
					record.model:PivotTo(cf + Vector3.new(0, 2, 0))
				elseif record.root then
					record.root.CFrame = cf + Vector3.new(0, 2, 0)
				end
				record.lastMoveTime = now
				record.nextRelocate = now + 6
			end
		end
	end

	-- DISTANCE LOD: far zombies re-think at half rate (they still walk at you, they just plan less).
	record.nextThink = now + GameConfig.ZombieAITickRate * (dist > LOD_DISTANCE and 2 or 1)
end

-- STEER (every frame): drive toward the live goal + hop obstacles. Cheap (no pathfinding here).
local function steer(record, now: number)
	local root = record.root
	if not root or not root.Parent then
		return
	end
	-- Keep the rig standing at hip height (flyers hold their own Y; a mid-leap arc must stay ballistic;
	-- emergence still owns the root while anchored).
	if not record.emerging and now >= (record.leapUntil or 0) and not (record.type and record.type.canFly) then
		hover(record)
	end
	statusSpeed(record, now) -- chills/pins apply + expire here (runs every steer frame)
	if isFrozen(record, now) then
		setVel(record, Vector3.zero)
		if record.type and record.type.canFly then
			root.AssemblyLinearVelocity = Vector3.zero -- frozen flyers hang in place instead of drifting
		end
		return
	end
	local targetRoot = record.targetRoot
	if record.mode == "idle" or not targetRoot or not targetRoot.Parent then
		setVel(record, Vector3.zero)
		return
	end

	-- Mid-pounce (Leaper): let the ballistic arc carry it; applying walk force here would kill the horizontal
	-- speed and it'd just drop straight down. Resume normal steering once it lands.
	if now < (record.leapUntil or 0) then
		return
	end

	-- Ghost (canFly): hover above the player and dive-bomb. Physics stays on (still shootable/knockable);
	-- we set velocity each frame to hold height, chase horizontally, and drop on a dive.
	if record.type and record.type.canFly then
		-- Flyers are always "making progress" (velocity-driven, never truly wedged) — keep the stuck
		-- detector fed, or think()'s 8s backstop force-kills every ghost shortly after it spawns.
		record.lastPos = root.Position
		record.lastMoveTime = now
		local pPos = targetRoot.Position
		local flatToP = Vector3.new(pPos.X - root.Position.X, 0, pPos.Z - root.Position.Z)
		local diving = now < (record.ghostDiveUntil or 0)
		if not diving and now >= (record.ghostNextDive or 0) and flatToP.Magnitude < GHOST_DIVE_RANGE then
			record.ghostDiveUntil = now + GHOST_DIVE_TIME
			record.ghostNextDive = now + GHOST_DIVE_CD
			diving = true
		end
		local aimY = diving and pPos.Y or (pPos.Y + GHOST_HEIGHT)
		local horiz = flatToP.Magnitude > 0.5 and (flatToP.Unit * record.speed) or Vector3.zero
		local vy = math.clamp((aimY - root.Position.Y) * 6, -60, 60)
		root.AssemblyLinearVelocity = Vector3.new(horiz.X, vy, horiz.Z)
		-- Bite on contact (mostly lands during a dive).
		if record.target and record.damage > 0 and (pPos - root.Position).Magnitude <= ATTACK_RANGE + 1.5
			and (now - record.lastAttack) >= ATTACK_COOLDOWN then
			record.lastAttack = now
			PlayerStateService.Damage(record.target, record.damage, "zombie", root.Position)
			SoundFXService.Emit("ZAttack:" .. record.typeId, root.Position)
		end
		return
	end

	local dist = (root.Position - targetRoot.Position).Magnitude

	-- DISTANCE LOD: far zombies steer every OTHER frame — the Humanoid keeps walking on its last Move
	-- direction between skipped frames, so the approach looks identical at range.
	if dist > LOD_DISTANCE then
		record.lodFlip = not record.lodFlip
		if record.lodFlip then
			return
		end
	end

	-- Water maps: never chase INTO the ocean. In direct mode, probe the ground one step ahead a few
	-- times a second — open water (or a sheer drop) ahead flips this zombie to pathfinding via
	-- record.avoidWaterUntil (think() treats it like blocked sight) and halts it this frame.
	if mapEmerge == "water" and record.mode == "direct" and not record.emerging then
		local now2 = os.clock()
		if now2 >= (record.nextEdgeProbe or 0) then
			record.nextEdgeProbe = now2 + 0.2
			local aheadFlat = Vector3.new(targetRoot.Position.X - root.Position.X, 0, targetRoot.Position.Z - root.Position.Z)
			if aheadFlat.Magnitude > 0.1 then
				local params = worldOnlyParams()
				params.CollisionGroup = "ZombieRig" -- see the ocean (OceanZ ignores Default-group rays)
				-- A zombie still ON the ocean must keep wading ashore (the water is solid for it) —
				-- only steer away from water once it's standing on real land. Then it STAYS on land.
				local under = Workspace:Raycast(root.Position + Vector3.new(0, 3, 0), Vector3.new(0, -25, 0), params)
				local onLand = under ~= nil and not isOceanPart(under.Instance)
				local ahead = root.Position + aheadFlat.Unit * 5
				local probe = onLand and Workspace:Raycast(ahead + Vector3.new(0, 4, 0), Vector3.new(0, -25, 0), params) or nil
				if onLand and ((not probe) or isOceanPart(probe.Instance)) then
					record.avoidWaterUntil = now2 + 1.5
					record.mode = "path"
					record.lastPath = 0 -- think() recomputes a route on its next tick
					setVel(record, Vector3.zero)
					return
				end
			end
		end
	end

	-- Goal = the player's LIVE position (direct) or the current path waypoint (path).
	local goal = targetRoot.Position
	if record.mode == "path" and record.waypoints and record.waypointIndex <= #record.waypoints then
		local wp = record.waypoints[record.waypointIndex]
		goal = wp.Position
		local flat = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
		if flat.Magnitude < WAYPOINT_REACH then
			if wp.Action == Enum.PathWaypointAction.Jump then
				jump(record)
			end
			record.waypointIndex += 1
		end
	end

	if dist <= ATTACK_RANGE then
		setVel(record, Vector3.zero) -- in contact: stop shoving the player around
		-- Damage on TOUCH: while its body is against yours, it bites once per cooldown.
		-- (damage <= 0 = no melee at all: the Bomb Zombie only threatens with its explosion.)
		if record.target and record.damage > 0 and (now - record.lastAttack) >= ATTACK_COOLDOWN then
			record.lastAttack = now
			PlayerStateService.Damage(record.target, record.damage, "zombie", root.Position)
			SoundFXService.Emit("ZAttack:" .. record.typeId, root.Position)
			if record.attackTrack then
				record.attackTrack:Play(0.1)
			end
		end
	else
		local toGoal = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
		if toGoal.Magnitude > 0.1 then
			local move = toGoal.Unit
			setVel(record, move)

			-- Jump up onto / over stuff: probe ahead. If something blocks at foot height but the path is
			-- clear higher up, it's a ledge/step/obstacle we can hop.
			if now >= (record.nextJumpCheck or 0) then
				record.nextJumpCheck = now + JUMP_CHECK_RATE
				local ahead = move * OBSTACLE_AHEAD
				local params = worldOnlyParams()
				local lowHit = Workspace:Raycast(root.Position - Vector3.new(0, 1.5, 0), ahead, params)
				local highHit = Workspace:Raycast(root.Position + Vector3.new(0, 2, 0), ahead, params)
				if lowHit and not highHit then
					jump(record)
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
-- ===== PERF (the 200-zombie horde) ===== close zombies steer EVERY frame (attacks/leaps need the
-- precision); distant ones only need to march, so they steer at STEER_FAR_HZ. Halves-plus the per-frame
-- work of a packed horde without changing anything a player can see up close.
local STEER_NEAR_DIST = 60 -- studs from their target under which zombies steer every frame
local STEER_FAR_HZ    = 10 -- steering rate for everyone farther away

local function onHeartbeat()
	local now = os.clock()
	for _, record in active do
		if not record.dead and not record.emerging then -- emerging zombies are still rising out of the grave
			if now >= record.nextThink then
				think(record, now) -- sparse planning
			end
			local near = true
			local tr = record.targetRoot
			local root = record.root
			if tr and tr.Parent and root then
				near = (root.Position - tr.Position).Magnitude <= STEER_NEAR_DIST
			end
			if near or now >= (record.nextSteer or 0) then
				record.nextSteer = now + (near and 0 or 1 / STEER_FAR_HZ)
				steer(record, now) -- real-time steering (LOD-throttled when far)
			end
		end
	end

	if DEBUG and (now - lastDebug) > 2 then
		lastDebug = now
		print(("[ZombieDebug] alive=%d remaining=%d"):format(aliveCount, remaining))
		for _, record in active do
			print(("[ZombieDebug]  type=%s speed=%.1f hp=%.0f mode=%s hasTarget=%s anchored=%s")
				:format(
					record.typeId,
					record.speed or -1,
					record.health or -1,
					tostring(record.mode),
					tostring(record.target ~= nil),
					tostring(record.root and record.root.Anchored)
				))
			break -- one sample is enough to diagnose
		end
	end
end

-- ===== PUBLIC API (the round loop in MatchService drives these) =====

-- NEW (spawn-lag fix): PREWARM the pool during the pre-run countdown.
--
-- On a FRESH JOIN the pool is empty, so the first wave pays the full price mid-combat: a :Clone() of
-- the rig, prepModel() walking every descendant, configureRig(), the tag BillboardGui — and, worse,
-- the CLIENTS have never seen the model (owner templates get moved into ServerStorage by
-- registerTemplate), so they download its meshes and textures at the exact moment the first zombies
-- appear. That is the hitch the owner feels with only 6 zombies on screen.
--
-- Building the rigs up front moves ALL of that into the countdown (dead time), and because the pool
-- now lives in Workspace, parking them also REPLICATES the models to every client before the wave —
-- so the first real spawn is just a CFrame change on a rig the client already has loaded.
-- One rig is built per frame so the warm-up itself never spikes a frame.
local PREWARM_PER_TYPE = 3   -- rigs to pre-build per early zombie type
local PREWARM_MAX      = 14  -- total rigs to pre-build (keep the warm-up short)

function ZombieService.Prewarm(round: number?)
	round = math.max(1, tonumber(round) or 1)
	task.spawn(function()
		local made = 0
		for id, t in ZOMBIE_TYPES do
			if made >= PREWARM_MAX then
				break
			end
			-- Only the types that can actually show up around this wave (bosses have spawnWeight 0).
			if (t.spawnWeight or 0) > 0 and (t.minRound or 1) <= round + 2 then
				local list = pool[id]
				if not list then
					list = {}
					pool[id] = list
				end
				for _ = 1, PREWARM_PER_TYPE do
					if made >= PREWARM_MAX or #list >= PREWARM_PER_TYPE then
						break
					end
					local ok, model = pcall(buildZombie, id, t)
					if not ok or not model then
						break -- no template for this type: skip it, don't spam the log
					end
					parkModel(model)
					model.Parent = poolFolder
					table.insert(list, model)
					made += 1
					task.wait() -- one rig per frame: the warm-up must never hitch either
				end
			end
		end
		if made > 0 then
			print(("[ZombieService] prewarmed %d zombie rigs (pool is hot before wave 1)"):format(made))
		end
	end)
end

-- Begin spawning `count` zombies for `round`, throttled by SPAWN_INTERVAL and the MaxAliveZombies cap.
function ZombieService.BeginRound(round: number, count: number)
	currentRound = round
	remaining = count
	roundToken += 1
	local myToken = roundToken

	local interval = math.max(SPAWN_INTERVAL_MIN, SPAWN_INTERVAL - SPAWN_INTERVAL_STEP * (round - 1))
	task.spawn(function()
		while remaining > 0 and myToken == roundToken do
			if aliveCount < GameConfig.MaxAliveZombies then
				if spawnOne(round) then
					remaining -= 1
				end
			end
			task.wait(interval)
		end
	end)
end

-- ===== EVENT WHEEL HOOKS ===== whole-wave modifiers EventService switches on/off around each wave.

-- BLOOD MOON: a global speed multiplier, applied per-frame in statusSpeed so every LIVE zombie
-- speeds up the moment it lands and reverts the moment it lifts.
function ZombieService.SetSpeedMult(mult: number)
	globalSpeedMult = math.max(0.1, mult or 1)
end

-- GOLD RUSH &co: × HP for NEW spawns this wave (live zombies keep their rolled health).
function ZombieService.SetHPMult(mult: number)
	eventHPMult = math.max(0.1, mult or 1)
end

-- BOMB SQUAD / THE PURGE / BLOODHOUNDS: bias the spawn table — { [typeId] = share 0..1 }; whatever
-- share is left over rolls the normal weighted table. nil clears.
function ZombieService.SetEventMix(mix)
	if typeof(mix) == "table" then
		local out = {}
		for id, share in mix do
			if ZOMBIE_TYPES[id] and tonumber(share) then
				table.insert(out, { id = id, share = share })
			end
		end
		eventMix = (#out > 0) and out or nil
	else
		eventMix = nil
	end
end

-- BOMB SQUAD: bomb-zombie blasts also chain into OTHER zombies for the wave (fireworks).
function ZombieService.SetBombChain(on: boolean)
	bombChain = on == true
end

-- EARTHQUAKE: stagger every live non-boss zombie for `secs` (rides the pin/status system).
function ZombieService.StaggerAll(secs: number)
	local untilT = os.clock() + math.max(0.1, secs or 1)
	for _, record in active do
		if not record.isBoss then
			record.pinnedUntil = math.max(record.pinnedUntil or 0, untilT)
		end
	end
end

-- Spawn exactly ONE boss for this wave: broadcasts an entrance, then streams its health to the boss bar
-- until it dies. The boss counts toward aliveCount, so the wave won't clear until it's dead.
-- Boss HP scales with the party: × the number of players in the run (2p = 2x, 3p = 3x, ...).
function ZombieService.SpawnBoss(round: number, bossId: string?, playerCount: number?)
	task.spawn(function()
		local id = bossId or "boss"
		local record
		for _ = 1, 30 do -- retry in case every spawn point is briefly crowded by a fresh grave
			record = spawnOne(round, id)
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
		local mult = math.max(1, math.floor(playerCount or 1))
		if mult > 1 then
			record.maxHealth = record.maxHealth * mult
			record.health = record.maxHealth
		end
		Remotes.Get("BossSpawned"):FireAllClients(record.type.name, record.maxHealth)
		SoundFXService.Emit("ZRoar:" .. record.typeId, record.root and record.root.Position or nil, 250)
		-- (No HealthChanged connection — applyDamage() feeds the boss bar for isBoss records.)
	end)
end

-- NEW (EventService): spawn ONE extra zombie outside the wave's owed count — used by events (the Nest,
-- meteor craters). Registers through the normal spawn path, so it counts as alive (the wave won't clear
-- until it dies) and pools/cleans up like any other zombie. Optional cf overrides where it appears.
function ZombieService.SpawnExtra(round: number, typeId: string?, cf: CFrame?)
	-- CHANGED: cf now rides INTO spawnOne (and startEmergence) — the old post-spawn PivotTo was
	-- silently undone 0.8s later when the emergence rise re-pivoted to the original spawn point.
	return spawnOne(round, typeId, cf)
end

-- True once every owed zombie has spawned and the world is clear of living zombies.
function ZombieService.IsRoundCleared(): boolean
	-- Cleared the instant the last LIVING zombie dies. `active` only ever holds live zombies (each entry
	-- is removed the moment it dies), so corpses still lingering/sinking (aliveCount) no longer hold up
	-- the next-wave timer.
	return remaining <= 0 and next(active) == nil
end

function ZombieService.GetAliveCount(): number
	return aliveCount
end

function ZombieService.GetRemaining(): number
	return remaining
end

-- Zombies STILL TO KILL this wave = owed-but-not-yet-spawned (remaining) + currently-alive (the `active`
-- set, which clears the INSTANT a zombie dies). NOTE: aliveCount is NOT used here — it only drops once the
-- corpse finishes sinking, which would pin the bar at the wave total until bodies despawn.
function ZombieService.GetLeft(): number
	local aliveNow = 0
	for _ in active do
		aliveNow += 1
	end
	return remaining + aliveNow
end

-- The Workspace folder holding all live zombies (used to exclude them from line-of-sight checks).
function ZombieService.GetFolder(): Folder
	return zombieFolder
end

-- THE public damage entry (CombatService / TrapService / events): custom health, returns killed.
function ZombieService.ApplyDamage(record, amount: number): boolean
	return applyDamage(record, amount)
end

-- Snapshot of the live zombies (for CombatService's arc hit). Each entry: { record with .root/.speed/... }.
function ZombieService.GetActive()
	local list = {}
	for _, record in active do
		if not record.dead and record.root and record.root.Parent and (record.health or 0) > 0 then
			table.insert(list, record)
		end
	end
	return list
end

-- Remember where the last shot that hit this zombie came from, so a KILLING shot can launch the ragdoll
-- backward along the bullet's travel. Cheap; called for every hit (lethal or not) from CombatService.
function ZombieService.NoteHit(record, fromPos: Vector3)
	record.lastHitOrigin = fromPos
end

-- Hit feedback for a non-lethal hit: knockback away from the shooter (scaled by the weapon) + a white flash.
-- `knockback` is the weapon's shove in studs/sec (falls back to HIT_KNOCKBACK). This is NOT the death launch.
function ZombieService.Hit(record, fromPos: Vector3, knockback: number?)
	if record.dead then
		return
	end
	local root = record.root
	if root and root.Parent then
		local away = root.Position - fromPos
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude > 0.01 then
			root.AssemblyLinearVelocity = away.Unit * (knockback or HIT_KNOCKBACK) + Vector3.new(0, 4, 0)
		end
	end
	flashWhite(record)
end

-- SKIP WAVE (the Robux dev product): cancel everything still owed and drop every live zombie dead.
-- Deaths run the normal Died flow (ragdoll, pooling, active-set removal), so the wave completes through
-- the standard cleared check. No cash/XP is credited — there's no shooter.
function ZombieService.SkipWave()
	remaining = 0
	for _, record in active do
		if not record.dead and (record.health or 0) > 0 then
			applyDamage(record, math.huge)
		end
	end
end

-- Wipe everything (used on game over / reset). Cancels spawning and pools all live zombies.
function ZombieService.ClearAll()
	roundToken += 1
	remaining = 0
	bossRecord = nil
	globalSpeedMult = 1 -- a run ending mid-event must not leak modifiers into the next run
	eventMix = nil
	eventHPMult = 1
	bombChain = false
	announcedTypes = {} -- next run re-announces each enemy type's first appearance
	for model, record in active do
		record.dead = true
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

	-- THE POOL LIVES IN WORKSPACE (perf — this was the spawn-lag fix). A pooled rig parked in
	-- ServerStorage is NOT replicated: every death told all clients to destroy the model, and every
	-- spawn re-sent the entire rig (parts, meshes, textures, welds, tag GUI) to everyone. Parking the
	-- rigs in Workspace instead means a spawn only replicates a CFrame + a few property flips, because
	-- the client already has the model. release() freezes them (anchored / no collision / no raycast)
	-- far under the map; unpark() wakes them.
	poolFolder = Instance.new("Folder")
	poolFolder.Name = "ZombiePool"
	poolFolder.Parent = Workspace

	templatesFolder = Instance.new("Folder")
	templatesFolder.Name = "ZombieTemplates"
	templatesFolder.Parent = ServerStorage

	loadTaggedTemplates()
	CollectionService:GetInstanceAddedSignal("ZombieTemplate"):Connect(registerTemplate)

	loadGraveTemplates()
	loadWaterTemplates()

	RunService.Heartbeat:Connect(onHeartbeat)

	print(("[ZombieService] started (graves: %d regular, %d big, %d huge)"):format(#graveTemplates, #bigGraveTemplates, #hugeGraveTemplates))
end

return ZombieService
