--!nonstrict
-- AssetPreloadController.lua — kill the FIRST-SPAWN HITCH.
--
-- THE BUG THIS FIXES: on a fresh join the client had never seen a zombie rig (the owner's templates get
-- moved into ServerStorage, which is not replicated), so the very first wave made every client download
-- AND upload-to-GPU the zombie meshes/textures at the exact moment the first zombies clawed out of the
-- ground. Six zombies was enough to feel it — as a frame hitch, which reads as input lag because your
-- shots sit in the queue behind the stalled frame.
--
-- THE FIX: ZombieService now prewarms its pool during the pre-run countdown and parks the rigs in
-- Workspace (ZombiePool), so the models replicate to us BEFORE the wave. This controller then asks the
-- engine to fully realize them (decode textures, upload meshes) while the countdown is still running,
-- plus anything else the first seconds of a run touches. By the time wave 1 starts, nothing is cold.
--
-- Everything here is best-effort and pcall-wrapped: a missing folder or a bad asset id must never stop
-- a player from joining the run.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationConfig = require(Shared.Config.AnimationConfig)

local AssetPreloadController = {}

-- ===== TUNABLES =====
local POOL_WAIT     = 25   -- seconds to wait for the prewarmed pool to appear before giving up
local SETTLE_TIME   = 0.6  -- seconds to let the pool finish filling before we preload it
local BATCH_WINDOW  = 1.0  -- seconds to let a pool top-up finish before preloading it as one batch

-- Preload a list of instances/ids. PreloadAsync yields and can throw on a bad id — always pcall it,
-- and never let it run on an empty list (that logs a warning for nothing).
local function preload(assets)
	if #assets == 0 then
		return
	end
	pcall(function()
		ContentProvider:PreloadAsync(assets)
	end)
end

-- Every Animation id the zombies use (blank ids are skipped by Resolve). Preloading these means the
-- first walk/attack/death plays instantly instead of fetching mid-fight.
local function zombieAnimations(): { Instance }
	local out = {}
	local seen = {}
	for _, cfg in pairs(AnimationConfig.Zombies or {}) do
		if typeof(cfg) == "table" then
			for _, key in { "Walk", "Attack", "Death" } do
				local id = AnimationConfig.Resolve(cfg[key])
				if id and not seen[id] then
					seen[id] = true
					local a = Instance.new("Animation")
					a.AnimationId = id
					table.insert(out, a)
				end
			end
		end
	end
	return out
end

-- The parked rigs themselves (meshes + textures) and any asset folders the client can see.
local function worldAssets(): { Instance }
	local out = {}
	local pool = Workspace:FindFirstChild("ZombiePool")
	if pool then
		for _, m in pool:GetChildren() do
			table.insert(out, m)
		end
	end
	-- Owner asset folders that live client-side (zombies/weapons/meteors/graves put in ReplicatedStorage).
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets then
		table.insert(out, assets)
	end
	return out
end

function AssetPreloadController.Start()
	task.spawn(function()
		-- The animation ids don't depend on anything spawning — do them straight away.
		local anims = zombieAnimations()
		preload(anims)
		for _, a in anims do
			a:Destroy() -- the Animation instances were only carriers for the preload
		end

		-- Then the rigs, once ZombieService has parked them (it fills the pool one per frame).
		local pool = Workspace:WaitForChild("ZombiePool", POOL_WAIT)
		if pool then
			task.wait(SETTLE_TIME)
		end
		preload(worldAssets())

		-- TOP-UPS, for the whole run (audit): this used to be six timed passes and then it stopped
		-- forever — 24 seconds after joining — which missed every zombie type that unlocks at a deeper
		-- wave. Now we watch the pool: MatchService tops it up during each wave break, and every rig
		-- that lands gets warmed here BEFORE that type ever claws out of the ground. Batched behind a
		-- short debounce so a 12-rig top-up is one PreloadAsync, not twelve.
		if pool then
			local pending = false
			pool.ChildAdded:Connect(function()
				if pending then
					return
				end
				pending = true
				task.delay(BATCH_WINDOW, function()
					pending = false
					preload(worldAssets())
				end)
			end)
		end
	end)
	print("[AssetPreloadController] started (warming zombie rigs + animations)")
end

return AssetPreloadController
