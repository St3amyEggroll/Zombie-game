--!nonstrict
-- EventService.lua — RANDOM IN-RUN EVENTS. Each wave start MatchService calls OnWaveStart(round); we roll
-- GameConfig.Events.ChancePerWave and maybe fire ONE surprise event, announced to every client:
--   supplydrop — a crate falls near a random player; open it (ProximityPrompt) → Coins for the whole team.
--   fog        — thick fog rolls over the map for a while (client-side Lighting FX via the RunEvent remote).
--   nest       — a pulsing nest rises and spits fast crawlers until it burns out (they count toward the wave).
--   meteors    — telegraphed meteor strikes: red warning discs → falling rocks → blast damage + fire.
-- All visuals are procedural (no owner models needed). Tune everything in GameConfig.Events.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Modules.Remotes)

local DataService = require(script.Parent.DataService) -- base service, no cycle

-- Lazy requires (break the Match -> Event -> Match cycle).
local MatchService
local ZombieService
local PlayerStateService

local EventService = {}

-- ===== TUNABLES ===== (the numbers live in GameConfig.Events — these are internal feel knobs)
local METEOR_STRIKE_EVERY = 1.6  -- seconds between strikes during a shower
local METEOR_TELEGRAPH    = 1.3  -- warning-disc seconds before the rock lands
local CRATE_TIMEOUT       = 30   -- unopened supply crates despawn after this
local NEST_BURST          = 2    -- crawlers per nest burst

local lastEventWave = -math.huge
local gen = 0 -- bumping this cancels every running event task
local folder -- workspace container for event props (cleared by StopAll)

local function cfg()
	return GameConfig.Events or {}
end

local function getFolder(): Folder
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "RunEvents"
		folder.Parent = Workspace
	end
	return folder
end

local function announce(text: string, colorName: string?)
	Remotes.Get("RunEvent"):FireAllClients("announce", { text = text, color = colorName })
end

-- A random in-run player's root position (events anchor to where people actually are).
local function randomPlayerPos(): Vector3?
	local roots = {}
	MatchService.ForEachPlayer(function(player)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			table.insert(roots, root.Position)
		end
	end)
	if #roots == 0 then
		return nil
	end
	return roots[math.random(1, #roots)]
end

-- Drop a position to the ground with a ray (events land ON the floor, not floating at torso height).
local function groundAt(pos: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { getFolder() }
	local hit = Workspace:Raycast(pos + Vector3.new(0, 40, 0), Vector3.new(0, -160, 0), params)
	return hit and hit.Position or pos
end

local function mkPart(props): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	for k, v in props do
		p[k] = v
	end
	p.Parent = getFolder()
	return p
end

-- ===== SUPPLY DROP =====
local function runSupplyDrop(myGen, round)
	local at = randomPlayerPos()
	if not at then
		return
	end
	local ground = groundAt(at + Vector3.new(math.random(-18, 18), 0, math.random(-18, 18)))
	announce("SUPPLY DROP INCOMING — OPEN IT!", "gold")
	local crate = mkPart({
		Size = Vector3.new(4, 4, 4),
		Color = Color3.fromRGB(148, 108, 38),
		Material = Enum.Material.WoodPlanks,
		CFrame = CFrame.new(ground + Vector3.new(0, 120, 0)) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0),
	})
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 200, 80)
	glow.Range = 16
	glow.Parent = crate
	TweenService:Create(crate, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(ground + Vector3.new(0, 2, 0)) * (crate.CFrame - crate.CFrame.Position) }):Play()
	task.wait(2.3)
	if myGen ~= gen or not crate.Parent then
		return
	end
	Remotes.Get("WorldVFX"):FireAllClients("dust", { pos = crate.Position - Vector3.new(0, 1.5, 0) }) -- landing thump
	crate.CanQuery = true
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open"
	prompt.ObjectText = "Supply Crate"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = crate
	local opened = false
	prompt.Triggered:Connect(function(player)
		if opened or myGen ~= gen then
			return
		end
		opened = true
		local coins = tonumber(cfg().SupplyDropCoins) or 150
		MatchService.ForEachPlayer(function(pl)
			pcall(function()
				DataService.AddMoney(pl, coins)
			end)
		end)
		PlayerStateService.Heal(player, 1000) -- the opener tops off
		Remotes.Get("WorldVFX"):FireAllClients("coins", { pos = crate.Position }) -- gold fountain
		announce(("SUPPLIES! +%d COINS FOR THE TEAM"):format(coins), "green")
		crate:Destroy()
	end)
	task.delay(CRATE_TIMEOUT, function()
		if crate.Parent then
			crate:Destroy()
		end
	end)
end

-- ===== FOG ROLL ===== (pure client FX — the RunEvent remote drives Lighting on every client)
local function runFog(myGen, round)
	local secs = tonumber(cfg().FogSeconds) or 25
	announce("FOG IS ROLLING IN...", "grey")
	Remotes.Get("RunEvent"):FireAllClients("fog", { seconds = secs })
end

-- ===== THE NEST =====
local function runNest(myGen, round)
	local at = randomPlayerPos()
	if not at then
		return
	end
	local ground = groundAt(at + Vector3.new(math.random(-40, 40), 0, math.random(-40, 40)))
	announce("A NEST HAS FORMED — BURN IT DOWN!", "red")
	local nest = mkPart({
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(7, 7, 7),
		Color = Color3.fromRGB(84, 32, 92),
		Material = Enum.Material.CrackedLava,
		CFrame = CFrame.new(ground + Vector3.new(0, 2.4, 0)),
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(190, 80, 220)
	light.Range = 18
	light.Parent = nest
	TweenService:Create(nest, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = Vector3.new(8.2, 8.2, 8.2) }):Play() -- breathes while alive
	local secs = tonumber(cfg().NestSeconds) or 18
	local every = math.max(1, tonumber(cfg().NestSpawnEvery) or 3)
	local t0 = os.clock()
	while os.clock() - t0 < secs do
		if myGen ~= gen or not nest.Parent then
			return
		end
		for _ = 1, NEST_BURST do
			ZombieService.SpawnExtra(round, "speedy", nest.CFrame * CFrame.new(math.random(-4, 4), -1, math.random(-4, 4)))
		end
		task.wait(every)
	end
	if nest.Parent then -- burnt out: pop
		local boom = Instance.new("Explosion")
		boom.Position = nest.Position
		boom.BlastPressure = 0
		boom.BlastRadius = 0
		boom.Parent = Workspace
		nest:Destroy()
	end
end

-- ===== METEOR SHOWER =====
local function runMeteors(myGen, round)
	announce("METEOR SHOWER — WATCH THE RED CIRCLES!", "red")
	local secs = tonumber(cfg().MeteorSeconds) or 14
	local dmg = tonumber(cfg().MeteorDamage) or 25
	local radius = tonumber(cfg().MeteorRadius) or 9
	local t0 = os.clock()
	while os.clock() - t0 < secs do
		if myGen ~= gen then
			return
		end
		task.spawn(function()
			local at = randomPlayerPos()
			if not at then
				return
			end
			local ground = groundAt(at + Vector3.new(math.random(-24, 24), 0, math.random(-24, 24)))
			local disc = mkPart({ -- the telegraph: dodge THIS
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.4, radius * 2, radius * 2),
				Color = Color3.fromRGB(255, 60, 40),
				Material = Enum.Material.Neon,
				Transparency = 0.55,
				CFrame = CFrame.new(ground + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			})
			task.wait(METEOR_TELEGRAPH)
			disc:Destroy()
			if myGen ~= gen then
				return
			end
			local rock = mkPart({
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(5, 5, 5),
				Color = Color3.fromRGB(70, 48, 30),
				Material = Enum.Material.Rock,
				CFrame = CFrame.new(ground + Vector3.new(math.random(-8, 8), 130, math.random(-8, 8))),
			})
			Remotes.Get("WorldVFX"):FireAllClients("trail", { part = rock }) -- clients ride a fire/smoke trail on it
			TweenService:Create(rock, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ CFrame = CFrame.new(ground) }):Play()
			task.wait(0.36)
			if myGen ~= gen or not rock.Parent then
				return
			end
			-- Layered client-side detonation (WorldVFXController) — no stock Explosion ball.
			Remotes.Get("WorldVFX"):FireAllClients("boom", { pos = ground, r = radius })
			MatchService.ForEachPlayer(function(player)
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if root and (root.Position - ground).Magnitude <= radius then
					PlayerStateService.Damage(player, dmg, "meteor", ground)
				end
			end)
			if math.random() < 0.25 then -- some craters cough up a zombie
				ZombieService.SpawnExtra(round, nil, CFrame.new(ground + Vector3.new(0, 3, 0)))
			end
			rock.Size = Vector3.new(3.4, 3.4, 3.4) -- settles into a smoldering crater rock
			rock.CFrame = CFrame.new(ground + Vector3.new(0, 1, 0))
			task.delay(5, function()
				if rock.Parent then
					rock:Destroy()
				end
			end)
		end)
		task.wait(METEOR_STRIKE_EVERY)
	end
end

local EVENTS = {
	supplydrop = runSupplyDrop,
	fog = runFog,
	nest = runNest,
	meteors = runMeteors,
}

-- ===== PUBLIC =====

-- Called by MatchService at every wave start: maybe fire ONE random event this wave.
function EventService.OnWaveStart(round: number)
	local c = cfg()
	if round < (c.FirstWave or 3) then
		return
	end
	if round - lastEventWave < (c.CooldownWaves or 2) then
		return
	end
	if math.random() >= (c.ChancePerWave or 0.35) then
		return
	end
	-- weighted pick
	local weights = c.Weights or {}
	local total = 0
	for id in EVENTS do
		total += math.max(0, tonumber(weights[id]) or 1)
	end
	if total <= 0 then
		return
	end
	local r = math.random() * total
	local acc, chosen = 0, nil
	for id in EVENTS do
		acc += math.max(0, tonumber(weights[id]) or 1)
		if r <= acc then
			chosen = id
			break
		end
	end
	if not chosen then
		return
	end
	lastEventWave = round
	local myGen = gen
	print(("[EventService] wave %d event: %s"):format(round, chosen))
	task.spawn(EVENTS[chosen], myGen, round)
end

-- Run over: cancel every running event task and clear the props.
function EventService.StopAll()
	gen += 1
	lastEventWave = -math.huge
	if folder then
		folder:ClearAllChildren()
	end
end

function EventService.Start()
	MatchService = require(script.Parent.MatchService)
	ZombieService = require(script.Parent.ZombieService)
	PlayerStateService = require(script.Parent.PlayerStateService)
	print("[EventService] started (random in-run events armed)")
end

return EventService
