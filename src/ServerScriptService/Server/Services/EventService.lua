--!nonstrict
-- EventService.lua — THE EVENT WHEEL. Every wave break MatchService calls SpinForWave(wave): we do a
-- weighted roll over the wheel's outcomes, broadcast EventSpin (clients animate a visible spin that
-- LANDS on the result), and hand the outcome back. When the wave actually starts, BeginWaveEvent runs
-- the modifier for the WHOLE wave; EndWaveEvent shuts it off the moment the wave clears.
--
-- The wheel:
--   calm      — a normal wave (its weight shrinks as waves climb, so deep runs get wilder)
--   bloodmoon — the sky bleeds: zombies run BloodMoonSpeedMult faster, kills pay DOUBLE Coins
--   fog       — thick fog sits on the map for the whole wave (client Lighting FX)
--   meteors   — telegraphed meteor strikes rain the whole wave: red disc → rock → blast damage
-- (Supply Drop and the Nest were CUT when the wheel landed — momentary drops didn't fit whole-wave
-- modifiers.) All visuals are procedural. Tune everything in GameConfig.Events.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Modules.Remotes)

-- Lazy requires (break the Match -> Event -> Match cycle).
local MatchService
local ZombieService
local PlayerStateService

local EventService = {}

-- ===== TUNABLES ===== (the numbers live in GameConfig.Events — these are internal feel knobs)
local METEOR_TELEGRAPH = 1.3  -- warning-disc seconds before the rock lands

local gen = 0        -- bumping this cancels every running event task
local folder         -- workspace container for event props (cleared by StopAll)
local activeEvent    -- the outcome currently modifying the wave (nil between waves / on calm)
local coinMult = 1   -- ProgressionService multiplies every kill's Coin grant by this (Blood Moon ×2)

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

-- ===== BLOOD MOON ===== whole wave: faster horde + double Coins + a bleeding sky (client FX).
local function beginBloodMoon(myGen, round)
	announce("BLOOD MOON — FAST ZOMBIES, DOUBLE COINS!", "red")
	coinMult = tonumber(cfg().BloodMoonCoinMult) or 2
	ZombieService.SetSpeedMult(tonumber(cfg().BloodMoonSpeedMult) or 1.35)
	Remotes.Get("RunEvent"):FireAllClients("bloodmoon", { on = true })
end

local function endBloodMoon()
	coinMult = 1
	ZombieService.SetSpeedMult(1)
	Remotes.Get("RunEvent"):FireAllClients("bloodmoon", { on = false })
end

-- ===== FOG ===== whole wave: rolls in at wave start, burns off at the clear (client Lighting FX).
local function beginFog(myGen, round)
	announce("FOG IS ROLLING IN...", "grey")
	Remotes.Get("RunEvent"):FireAllClients("fog", { hold = true })
end

local function endFog()
	Remotes.Get("RunEvent"):FireAllClients("fogclear", {})
end

-- ===== METEOR SHOWER ===== whole wave: strikes every MeteorEvery seconds until the wave clears.
local function beginMeteors(myGen, round)
	announce("METEOR SHOWER — WATCH THE RED CIRCLES!", "red")
	local dmg = tonumber(cfg().MeteorDamage) or 25
	local radius = tonumber(cfg().MeteorRadius) or 9
	local every = math.max(0.8, tonumber(cfg().MeteorEvery) or 2.2)
	task.spawn(function()
		while myGen == gen do
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
			task.wait(every)
		end
	end)
end

local function endMeteors()
	-- The strike loop watches `gen`; EndWaveEvent bumps it, so nothing else to do here.
end

-- outcome id -> { begin(myGen, round), stop() }. Add a wheel outcome = add a row + a weight in config.
local OUTCOMES = {
	calm      = { begin = nil,            stop = nil },
	bloodmoon = { begin = beginBloodMoon, stop = endBloodMoon },
	fog       = { begin = beginFog,       stop = endFog },
	meteors   = { begin = beginMeteors,   stop = endMeteors },
}

-- ===== PUBLIC =====

-- Roll the wheel for `wave` and broadcast the visible spin. Returns the outcome id; MatchService
-- hands it back to BeginWaveEvent when the wave actually starts (the spin itself changes nothing).
function EventService.SpinForWave(wave: number): string
	local c = cfg()
	local weights = c.Weights or {}
	-- Calm's weight shrinks with the wave number: breathers get rarer, never impossible.
	local calmW = math.max(tonumber(c.CalmMin) or 2,
		(tonumber(c.CalmBase) or 10) - (tonumber(c.CalmDecayPerWave) or 0.5) * (wave - 1))
	local total = 0
	local w = {}
	for id in OUTCOMES do
		w[id] = (id == "calm") and calmW or math.max(0, tonumber(weights[id]) or 0)
		total += w[id]
	end
	local chosen = "calm"
	if total > 0 then
		local r = math.random() * total
		local acc = 0
		for id, weight in w do
			acc += weight
			if r <= acc then
				chosen = id
				break
			end
		end
	end
	Remotes.Get("EventSpin"):FireAllClients({
		wave = wave,
		outcome = chosen,
		seconds = tonumber(c.SpinSeconds) or 3,
	})
	print(("[EventService] wave %d wheel: %s"):format(wave, chosen))
	return chosen
end

-- The wave is starting: run the spun outcome for the whole wave.
function EventService.BeginWaveEvent(outcome: string?, wave: number)
	EventService.EndWaveEvent() -- belt-and-braces: never stack two wave modifiers
	local def = outcome and OUTCOMES[outcome]
	if not def or not def.begin then
		return -- calm (or unknown): a normal wave
	end
	activeEvent = outcome
	gen += 1
	task.spawn(def.begin, gen, wave)
end

-- The wave cleared (or the run ended): shut the modifier off.
function EventService.EndWaveEvent()
	if not activeEvent then
		return
	end
	local def = OUTCOMES[activeEvent]
	activeEvent = nil
	gen += 1 -- cancels the meteor loop / any in-flight strike follow-ups
	if def and def.stop then
		def.stop()
	end
end

-- Blood Moon's live Coin multiplier — ProgressionService reads this on every kill grant.
function EventService.CoinMult(): number
	return coinMult
end

-- Run over: cancel every running event task and clear the props.
function EventService.StopAll()
	EventService.EndWaveEvent()
	gen += 1
	if folder then
		folder:ClearAllChildren()
	end
end

function EventService.Start()
	MatchService = require(script.Parent.MatchService)
	ZombieService = require(script.Parent.ZombieService)
	PlayerStateService = require(script.Parent.PlayerStateService)
	print("[EventService] started (the event wheel is armed)")
end

return EventService
