--!nonstrict
-- EventService.lua — THE EVENT ROLLER. Every wave break MatchService calls SpinForWave(wave): events
-- have RARITIES like crates — the roll picks a rarity tier (GameConfig.Events.RarityWeights, common
-- thinning as waves climb), then a uniform event of that tier, and broadcasts EventSpin (the client
-- roller flashes names + live % odds and LOCKS the result). When the wave starts, BeginWaveEvent runs
-- the modifier for the WHOLE wave; EndWaveEvent shuts it off the moment the wave clears.
--
-- THE WHEEL (rarity — event):
--   COMMON     calm (a plain wave), fog (Atmosphere blindfold)
--   UNCOMMON   meteors (owner-model rocks, crush zombies too), bombsquad (chaining bombers),
--              earthquake (tremors stagger the horde)
--   RARE       bloodmoon (fast + double coins), lightning (bolts kill zombies in the circles),
--              acidrain (sizzling puddles burn players), hounds (a sprinting dog pack)
--   EPIC       purge (a sea of regulars), bodyguards (two brutes guard a team coin vault)
--   LEGENDARY  goldrush (×5 coins, tougher zombies)
--   MYTHIC     apocalypse (meteors + acid + quakes at once, jackpot coins)
--   DIVINE     godmode (players take ZERO damage)
-- All visuals are procedural except the meteors (ReplicatedStorage > Assets > Meteors, owner models).
-- Tune everything in GameConfig.Events.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Modules.Remotes)

local DataService = require(script.Parent.DataService) -- base service, no cycle (bodyguards vault payout)

-- Lazy requires (break the Match -> Event -> Match cycle).
local MatchService
local ZombieService
local PlayerStateService

local EventService = {}

-- ===== TUNABLES ===== (the numbers live in GameConfig.Events — these are internal feel knobs)
local METEOR_TELEGRAPH = 1.3  -- warning-disc seconds before a meteor/bolt lands
local ACID_TELEGRAPH = 0.9    -- warning-disc seconds before an acid splash

local gen = 0        -- bumping this cancels every running event task
local folder         -- workspace container for event props (cleared by StopAll)
local activeEvent    -- the outcome currently modifying the wave (nil between waves / on calm)
local coinMult = 1   -- ProgressionService multiplies every kill's Coin grant by this
local waveCountMult = 1 -- MatchService multiplies the wave's zombie count by this (Purge/Bodyguards)
local lastWaveCoinMult = 1 -- NEW: the mult the JUST-ENDED wave ran under (wave-clear bonus reads this,
                           -- because EndWaveEvent resets coinMult before the payout fires)

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

-- A ground point in a RING around `pos`: at least minD studs away, at most maxD — never on top of it.
local function scatterAround(pos: Vector3, minD: number, maxD: number): Vector3
	local ang = math.random() * math.pi * 2
	local dist = minD + math.random() * math.max(0, maxD - minD)
	return groundAt(pos + Vector3.new(math.cos(ang) * dist, 0, math.sin(ang) * dist))
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

-- Damage every player within `radius` of `pos` (flat).
local function damagePlayersNear(pos: Vector3, radius: number, dmg: number, source: string)
	MatchService.ForEachPlayer(function(player)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - pos).Magnitude <= radius then
			PlayerStateService.Damage(player, dmg, source, pos)
		end
	end)
end

-- ===== METEOR MODELS ===== the owner's rocks (meteor1/meteor2). The hunt is WIDE (owner report:
-- "still the balls" — the first two lookups missed wherever the folder actually lives):
--   pass 1 — a container named "Meteors" (case-insensitive, Folder OR Model) ANYWHERE under
--            ReplicatedStorage, ServerStorage or Workspace: its children are the templates.
--   pass 2 — anything named meteor* in those three places (Models or Parts, skipping pieces that
--            sit INSIDE another meteor, and skipping our own RunEvents folder's live clones).
-- Never caches an empty miss; prints exactly what it found (full paths) so the Output settles it.
local ServerStorage = game:GetService("ServerStorage")
local meteorTemplates = nil
local function getMeteorTemplates()
	if meteorTemplates and #meteorTemplates > 0 then
		return meteorTemplates
	end
	meteorTemplates = {}
	local evFolder = folder -- our live event props: never treat a falling clone as a template
	local containers = { ReplicatedStorage, ServerStorage, Workspace }
	for _, root in containers do
		for _, d in root:GetDescendants() do
			if (d:IsA("Folder") or d:IsA("Model")) and d.Name:lower() == "meteors" and d ~= evFolder then
				for _, child in d:GetChildren() do
					if child:IsA("Model") or child:IsA("BasePart") then
						table.insert(meteorTemplates, child)
					end
				end
			end
		end
		if #meteorTemplates > 0 then
			break
		end
	end
	if #meteorTemplates == 0 then -- pass 2: name-based hunt
		for _, root in containers do
			for _, d in root:GetDescendants() do
				if (d:IsA("Model") or d:IsA("BasePart")) and d.Name:lower():match("^meteor") then
					local skip = false
					local a = d.Parent
					while a and a ~= root do
						if a == evFolder or ((a:IsA("Model") or a:IsA("BasePart")) and a.Name:lower():match("^meteor")) then
							skip = true -- a piece of a meteor (or one of our live clones), not a template
							break
						end
						a = a.Parent
					end
					if not skip then
						table.insert(meteorTemplates, d)
					end
				end
			end
			if #meteorTemplates > 0 then
				break
			end
		end
	end
	if #meteorTemplates == 0 then
		warn("[EventService] NO meteor models found — looked for a 'Meteors' folder (then anything named "
			.. "meteor*) in ReplicatedStorage, ServerStorage and Workspace. Using the fallback rock.")
	else
		local names = {}
		for _, t in meteorTemplates do
			table.insert(names, t:GetFullName())
		end
		print(("[EventService] %d meteor model(s): %s"):format(#meteorTemplates, table.concat(names, "  |  ")))
	end
	return meteorTemplates
end

-- Clone + prep a meteor for flight: everything anchored and non-colliding, parented to the event folder.
local function cloneMeteor(): (Instance?, BasePart?)
	local templates = getMeteorTemplates()
	local template = templates[math.random(1, math.max(1, #templates))]
	if not template then
		local rock = mkPart({
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(5, 5, 5),
			Color = Color3.fromRGB(70, 48, 30),
			Material = Enum.Material.Rock,
			CFrame = CFrame.new(0, -500, 0),
		})
		return rock, rock
	end
	local clone = template:Clone()
	local firstPart = nil
	local function prep(part)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		if not firstPart then
			firstPart = part
		end
	end
	if clone:IsA("BasePart") then
		prep(clone)
	else
		for _, d in clone:GetDescendants() do
			if d:IsA("BasePart") then
				prep(d)
			end
		end
	end
	clone.Parent = getFolder()
	return clone, firstPart
end

-- ===== BLOOD MOON (rare) ===== whole wave: faster horde + double Coins + a bleeding sky (client FX).
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

-- ===== FOG (common) ===== whole wave: rolls in at wave start, burns off at the clear (client FX).
local function beginFog(myGen, round)
	announce("FOG IS ROLLING IN...", "grey")
	Remotes.Get("RunEvent"):FireAllClients("fog", { hold = true })
end

local function endFog()
	Remotes.Get("RunEvent"):FireAllClients("fogclear", {})
end

-- ===== METEOR SHOWER (uncommon) ===== OVERHAULED: the owner's meteor models tumble out of the sky
-- with a fire trail, land in a RING around players (never on top of them — owner report), crater-
-- scorch the ground, hurt players in the blast AND crush zombies (center = death, edge = half HP).
-- NEW: EVENT KILLS PAY. Lightning/meteor kills used to call ApplyDamage raw — zero points/Coins/XP,
-- which made "LURE THEM INTO THE CIRCLES" a lie. Kills now credit the nearest living in-match player
-- through CombatService.ReportKill, the same pipe as gunfire (points + kill count + Coins + XP).
local function creditEventKill(rec, pos: Vector3, sourceId: string)
	local best, bestD = nil, math.huge
	MatchService.ForEachPlayer(function(player)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			local d = (root.Position - pos).Magnitude
			if d < bestD then
				best, bestD = player, d
			end
		end
	end)
	if best then
		pcall(function()
			require(script.Parent.CombatService).ReportKill(best, rec.model, false, sourceId)
		end)
	end
end

-- Damage a zombie from an event strike; on a kill, pay the nearest player.
local function eventStrike(rec, amount: number, pos: Vector3, sourceId: string)
	if ZombieService.ApplyDamage(rec, amount) then
		creditEventKill(rec, pos, sourceId)
	end
end

local function meteorLoop(myGen, round)
	local c = cfg()
	local dmg = tonumber(c.MeteorDamage) or 25
	local radius = tonumber(c.MeteorRadius) or 9
	local minD = tonumber(c.MeteorMinDist) or 16
	local maxD = tonumber(c.MeteorMaxDist) or 36
	local bossFrac = tonumber(c.MeteorBossFrac) or 0.05
	local every = math.max(0.8, tonumber(c.MeteorEvery) or 2.2)
	task.spawn(function()
		while myGen == gen do
			task.spawn(function()
				local at = randomPlayerPos()
				if not at then
					return
				end
				local ground = scatterAround(at, minD, maxD)
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
				-- THE ROCK: the owner's model, falling in at an angle and TUMBLING, fire trail riding it.
				local rock, trailPart = cloneMeteor()
				if not rock then
					return
				end
				local ang = math.random() * math.pi * 2
				local startPos = ground + Vector3.new(math.cos(ang) * 35, 120, math.sin(ang) * 35)
				local sx, sz = (math.random() - 0.5) * 10, (math.random() - 0.5) * 10
				if trailPart then
					Remotes.Get("WorldVFX"):FireAllClients("trail", { part = trailPart })
				end
				local t0 = os.clock()
				local DUR = 0.55
				while myGen == gen do
					local a = math.clamp((os.clock() - t0) / DUR, 0, 1)
					local e = a * a -- ease-in: it accelerates like a falling thing
					rock:PivotTo(CFrame.new(startPos:Lerp(ground, e)) * CFrame.Angles(sx * a, sz * a, (sx + sz) * a * 0.5))
					if a >= 1 then
						break
					end
					RunService.Heartbeat:Wait()
				end
				if myGen ~= gen then
					if rock.Parent then
						rock:Destroy()
					end
					return
				end
				-- IMPACT: layered client detonation + a scorch ring; players hurt, zombies CRUSHED.
				Remotes.Get("WorldVFX"):FireAllClients("boom", { pos = ground, r = radius })
				local scorch = mkPart({
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(0.25, radius * 2.6, radius * 2.6),
					Color = Color3.fromRGB(24, 20, 16),
					Material = Enum.Material.Slate,
					Transparency = 0.15,
					CFrame = CFrame.new(ground + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				})
				damagePlayersNear(ground, radius, dmg, "meteor")
				for _, rec in ZombieService.GetActive() do
					local zr = rec.root
					if zr then
						local d = (zr.Position - ground).Magnitude
						if d <= radius then
							-- CHANGED: crush kills PAY now (eventStrike credits the nearest player).
							if rec.isBoss then
								eventStrike(rec, (rec.maxHealth or 1000) * bossFrac, ground, "meteor")
							elseif d <= radius * 0.55 then
								eventStrike(rec, math.huge, ground, "meteor") -- dead center: flattened
							else
								eventStrike(rec, (rec.maxHealth or 100) * 0.5, ground, "meteor")
							end
						end
					end
				end
				-- CHANGED: craters only cough up a zombie while the wave still has meat — near the end
				-- of a wave the "last zombie" moment kept sliding away as craters minted stragglers.
				if math.random() < 0.25 then
					local alive = 0
					for _, r2 in ZombieService.GetActive() do
						if not r2.dead then
							alive += 1
						end
					end
					if alive > 2 or ZombieService.GetRemaining() > 0 then
						ZombieService.SpawnExtra(round, nil, CFrame.new(ground + Vector3.new(0, 3, 0)))
					end
				end
				task.delay(5, function()
					if rock.Parent then
						rock:Destroy()
					end
				end)
				task.delay(9, function()
					if scorch.Parent then
						TweenService:Create(scorch, TweenInfo.new(1.5), { Transparency = 1 }):Play()
						task.delay(1.6, function()
							if scorch.Parent then
								scorch:Destroy()
							end
						end)
					end
				end)
			end)
			task.wait(every)
		end
	end)
end

local function beginMeteors(myGen, round)
	announce("METEOR SHOWER — WATCH THE RED CIRCLES!", "red")
	meteorLoop(myGen, round)
end

-- ===== LIGHTNING STORM (rare) ===== bolts KILL ZOMBIES in the blue circles all wave.
local function beginLightning(myGen, round)
	announce("LIGHTNING STORM — LURE THEM INTO THE CIRCLES!", "gold")
	local radius = tonumber(cfg().LightningRadius) or 10
	local every = math.max(0.8, tonumber(cfg().LightningEvery) or 2.0)
	local bossFrac = tonumber(cfg().LightningBossFrac) or 0.05
	task.spawn(function()
		while myGen == gen do
			task.spawn(function()
				local at = randomPlayerPos()
				if not at then
					return
				end
				local ground = groundAt(at + Vector3.new(math.random(-28, 28), 0, math.random(-28, 28)))
				local disc = mkPart({ -- the telegraph: lure them into THIS
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(0.4, radius * 2, radius * 2),
					Color = Color3.fromRGB(120, 200, 255),
					Material = Enum.Material.Neon,
					Transparency = 0.5,
					CFrame = CFrame.new(ground + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				})
				task.wait(METEOR_TELEGRAPH)
				disc:Destroy()
				if myGen ~= gen then
					return
				end
				local bolt = mkPart({
					Size = Vector3.new(1.4, 110, 1.4),
					Color = Color3.fromRGB(190, 230, 255),
					Material = Enum.Material.Neon,
					CFrame = CFrame.new(ground + Vector3.new(0, 55, 0)),
				})
				TweenService:Create(bolt, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ Transparency = 1, Size = Vector3.new(0.2, 110, 0.2) }):Play()
				task.delay(0.25, function()
					if bolt.Parent then
						bolt:Destroy()
					end
				end)
				Remotes.Get("WorldVFX"):FireAllClients("boom", { pos = ground, r = radius * 0.7 })
				for _, rec in ZombieService.GetActive() do
					local root = rec.root
					if root and (root.Position - ground).Magnitude <= radius then
						-- CHANGED: lured kills PAY now (the event's whole instruction is to lure them in).
						if rec.isBoss then
							eventStrike(rec, (rec.maxHealth or 1000) * bossFrac, ground, "lightning")
						else
							eventStrike(rec, math.huge, ground, "lightning")
						end
					end
				end
			end)
			task.wait(every)
		end
	end)
end

-- ===== BOMB SQUAD (uncommon) ===== the wave is salted with bomb zombies whose blasts CHAIN.
local function beginBombSquad(myGen, round)
	announce("BOMB SQUAD — DON'T LET THEM GET CLOSE!", "red")
	ZombieService.SetEventMix({ bombzombie = tonumber(cfg().BombShare) or 0.4 })
	ZombieService.SetBombChain(true)
end

local function endBombSquad()
	ZombieService.SetEventMix(nil)
	ZombieService.SetBombChain(false)
end

-- ===== EARTHQUAKE (uncommon) ===== periodic tremors: screen shake + the whole horde staggers.
local function quakeLoop(myGen)
	local every = math.max(3, tonumber(cfg().QuakeEvery) or 8)
	local stun = tonumber(cfg().QuakeStun) or 1.4
	task.spawn(function()
		while myGen == gen do
			task.wait(every)
			if myGen ~= gen then
				return
			end
			Remotes.Get("RunEvent"):FireAllClients("quake", { secs = 0.9 })
			ZombieService.StaggerAll(stun)
		end
	end)
end

local function beginEarthquake(myGen, round)
	announce("EARTHQUAKE — THE GROUND WON'T SIT STILL!", "grey")
	quakeLoop(myGen)
end

-- ===== ACID RAIN (rare) ===== green splashes leave sizzling puddles that burn PLAYERS.
local function acidLoop(myGen)
	local c = cfg()
	local every = math.max(0.8, tonumber(c.AcidEvery) or 1.7)
	local puddleSecs = tonumber(c.AcidPuddleSecs) or 8
	local dps = tonumber(c.AcidDPS) or 8
	local radius = tonumber(c.AcidRadius) or 6
	task.spawn(function()
		while myGen == gen do
			task.spawn(function()
				local at = randomPlayerPos()
				if not at then
					return
				end
				local ground = scatterAround(at, 4, 24)
				local disc = mkPart({ -- brief green warning, then the splash
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(0.3, radius * 2, radius * 2),
					Color = Color3.fromRGB(120, 230, 60),
					Material = Enum.Material.Neon,
					Transparency = 0.65,
					CFrame = CFrame.new(ground + Vector3.new(0, 0.25, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				})
				task.wait(ACID_TELEGRAPH)
				if myGen ~= gen then
					disc:Destroy()
					return
				end
				-- The puddle: sizzles for puddleSecs, burning players standing in it.
				disc.Transparency = 0.3
				disc.Color = Color3.fromRGB(96, 210, 40)
				local t0 = os.clock()
				while myGen == gen and os.clock() - t0 < puddleSecs do
					damagePlayersNear(ground, radius, dps * 0.5, "acid")
					task.wait(0.5)
				end
				if disc.Parent then
					TweenService:Create(disc, TweenInfo.new(0.8), { Transparency = 1 }):Play()
					task.delay(0.9, function()
						if disc.Parent then
							disc:Destroy()
						end
					end)
				end
			end)
			task.wait(every)
		end
	end)
end

-- TOXIC BITES: while acid rain (or the apocalypse) is up, any zombie hit also POISONS you — a short
-- damage-over-time after the bite. Wired once in Start() off PlayerStateService.Damaged.
local toxicBites = false
local poisoned = {} -- player -> true while a DoT is already ticking (no stacking)

local function beginAcidRain(myGen, round)
	announce("ACID RAIN — TOXIC ZOMBIES, STAY OUT OF THE PUDDLES!", "green")
	toxicBites = true
	Remotes.Get("RunEvent"):FireAllClients("acidrain", { on = true }) -- the green downpour (client FX)
	acidLoop(myGen)
end

local function endAcidRain()
	toxicBites = false
	Remotes.Get("RunEvent"):FireAllClients("acidrain", { on = false })
end

-- ===== RAIN (common) ===== pure weather: a grey downpour, nothing else. Mood.
local function beginRain(myGen, round)
	announce("RAIN...", "grey")
	Remotes.Get("RunEvent"):FireAllClients("rain", { on = true })
end

local function endRain()
	Remotes.Get("RunEvent"):FireAllClients("rain", { on = false })
end

-- ===== BLOODHOUNDS (rare) ===== a hunting pack: a big share of spawns are sprinting dog zombies.
local function beginHounds(myGen, round)
	announce("BLOODHOUNDS — THE PACK IS LOOSE!", "red")
	ZombieService.SetEventMix({ hound = tonumber(cfg().HoundShare) or 0.35 })
end

local function endHounds()
	ZombieService.SetEventMix(nil)
end

-- ===== THE PURGE (epic) ===== a SEA of regular zombies: nothing special, just far too many.
local function beginPurge(myGen, round)
	announce("THE PURGE — THEY JUST KEEP COMING!", "red")
	ZombieService.SetEventMix({ default = 1 })
end

local function endPurge()
	ZombieService.SetEventMix(nil)
end

-- ===== BODYGUARDS (epic) ===== two brutes guard a coin vault; kill BOTH and the team gets paid.
local function beginBodyguards(myGen, round)
	announce("BODYGUARDS — KILL BOTH BRUTES TO CRACK THE VAULT!", "gold")
	task.spawn(function()
		local at = randomPlayerPos()
		if not at then
			return
		end
		local ground = scatterAround(at, 20, 40)
		local pile = mkPart({ -- the vault: a glowing gold pile
			Size = Vector3.new(5, 2.6, 5),
			Color = Color3.fromRGB(235, 185, 60),
			Material = Enum.Material.Metal,
			CFrame = CFrame.new(ground + Vector3.new(0, 1.3, 0)) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0),
		})
		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(255, 210, 90)
		glow.Range = 18
		glow.Parent = pile
		local guards = {}
		for i = 1, 2 do
			local rec
			for _ = 1, 20 do -- retry in case the spot is briefly crowded
				if myGen ~= gen then -- CHANGED: wave ended mid-retry — stop injecting brutes into the break
					if pile.Parent then
						pile:Destroy()
					end
					return
				end
				rec = ZombieService.SpawnExtra(round, "tank",
					CFrame.new(ground + Vector3.new(i == 1 and -7 or 7, 3, 0)))
				if rec then
					break
				end
				task.wait(0.3)
			end
			if rec then
				table.insert(guards, rec)
			end
		end
		-- CHANGED: the payout no longer loses the wave-clear race. Killing the second guard usually
		-- CLEARS the wave, which bumps `gen` within 0.1s — the old 0.5s poll died before it ever saw
		-- the kill. The payout now fires off CombatService.Kill (synchronous with the killing shot,
		-- so it always beats the gen bump), with a gen-guarded poll as fallback for kill paths that
		-- skip the Kill signal (frost shatter). Skip/wipe teardowns mark guards dead WITHOUT firing
		-- Kill and bump gen first, so they still pay nothing.
		local paid = false
		local function tryPayout()
			if paid or myGen ~= gen then
				return
			end
			local allDead = #guards > 0
			for _, r in guards do
				if not r.dead then
					allDead = false
					break
				end
			end
			if not allDead then
				return
			end
			paid = true
			local coins = tonumber(cfg().GuardCoins) or 400
			MatchService.ForEachPlayer(function(pl)
				pcall(function()
					-- CHANGED: pay through ProgressionService so the Scavenger class mult applies
					-- and the coins count in the end-of-run summary (raw AddMoney skipped both).
					require(script.Parent.ProgressionService).AwardCoins(pl, coins)
				end)
			end)
			Remotes.Get("WorldVFX"):FireAllClients("coins", { pos = pile.Position }) -- gold fountain
			announce(("VAULT CRACKED! +%d COINS FOR THE TEAM"):format(coins), "green")
			pcall(function() -- the VAULT CRACKER title (lazy require: no boot-order coupling)
				require(script.Parent.TitleService).GrantInMatch("vaultcracker")
			end)
			pile:Destroy()
		end
		local conn = require(script.Parent.CombatService).Kill:Connect(function(_pl, model)
			for _, r in guards do
				if r.model == model then
					tryPayout() -- r.dead is already set when Kill fires
					break
				end
			end
		end)
		while not paid and myGen == gen do
			tryPayout()
			task.wait(0.25)
		end
		conn:Disconnect()
		if not paid and pile.Parent then -- wave ended around it (wipe/skip): no payout, clean up
			pile:Destroy()
		end
	end)
end

-- ===== GOLD RUSH (legendary) ===== ×5 Coins per kill; the horde is beefier.
local function beginGoldRush(myGen, round)
	announce("GOLD RUSH — EVERY KILL PAYS BIG!", "gold")
	coinMult = tonumber(cfg().GoldRushCoinMult) or 5
	ZombieService.SetHPMult(tonumber(cfg().GoldRushHPMult) or 1.75)
end

local function endGoldRush()
	coinMult = 1
	ZombieService.SetHPMult(1)
end

-- ===== APOCALYPSE (mythic) ===== meteors + acid + quakes AT ONCE, paid like a jackpot.
local function beginApocalypse(myGen, round)
	announce("APOCALYPSE — EVERYTHING, ALL AT ONCE!", "red")
	coinMult = tonumber(cfg().ApocCoinMult) or 3
	toxicBites = true
	Remotes.Get("RunEvent"):FireAllClients("acidrain", { on = true }) -- the green downpour rides along
	meteorLoop(myGen, round)
	acidLoop(myGen)
	quakeLoop(myGen)
end

local function endApocalypse()
	coinMult = 1
	toxicBites = false
	Remotes.Get("RunEvent"):FireAllClients("acidrain", { on = false })
end

-- ===== GOD MODE (divine) ===== players take ZERO damage all wave. The 1% miracle.
local function beginGodMode(myGen, round)
	announce("GOD MODE — NOTHING CAN HURT YOU THIS WAVE!", "gold")
	PlayerStateService.SetInvulnerable(true)
end

local function endGodMode()
	PlayerStateService.SetInvulnerable(false)
end

-- outcome id -> { begin(myGen, round), stop(), countMultKey }. Odds live in GameConfig.Events.Weights
-- (per event, no rarity tiers — owner call). Add a wheel outcome = one row here + a weight there +
-- a LOOK row in EventWheelController.
local OUTCOMES = {
	calm       = {},
	fog        = { begin = beginFog,        stop = endFog },
	rain       = { begin = beginRain,       stop = endRain },
	meteors    = { begin = beginMeteors },
	bombsquad  = { begin = beginBombSquad,  stop = endBombSquad },
	earthquake = { begin = beginEarthquake },
	bloodmoon  = { begin = beginBloodMoon,  stop = endBloodMoon },
	lightning  = { begin = beginLightning },
	acidrain   = { begin = beginAcidRain,   stop = endAcidRain },
	hounds     = { begin = beginHounds,     stop = endHounds },
	purge      = { begin = beginPurge,      stop = endPurge,   countMultKey = "PurgeCountMult" },
	bodyguards = { begin = beginBodyguards, countMultKey = "GuardCountMult" },
	goldrush   = { begin = beginGoldRush,   stop = endGoldRush },
	apocalypse = { begin = beginApocalypse, stop = endApocalypse },
	godmode    = { begin = beginGodMode,    stop = endGodMode },
}

-- ===== PUBLIC =====

-- Roll the wheel for `wave`: ONE weighted roll straight over the per-event table (calm thins per
-- wave, nudging everything else up), broadcast the visible roll with live per-event odds (one
-- decimal — GOD MODE really reads 0.5%). Returns the outcome id.
function EventService.SpinForWave(wave: number): string
	local c = cfg()
	local weights = c.Weights or {}
	local w = {}
	local total = 0
	for id in OUTCOMES do
		local weight = math.max(0, tonumber(weights[id]) or 0)
		if id == "calm" then
			weight = math.max(tonumber(c.CalmMin) or 8,
				weight - (tonumber(c.CalmDecayPerWave) or 0.5) * (wave - 1))
		end
		if weight > 0 then
			w[id] = weight
			total += weight
		end
	end
	local chosen = "calm"
	if total > 0 then
		local roll = math.random() * total
		local acc = 0
		for id, weight in w do
			acc += weight
			if roll <= acc then
				chosen = id
				break
			end
		end
	end
	local odds = {}
	if total > 0 then
		for id, weight in w do
			odds[id] = math.floor((weight / total) * 1000 + 0.5) / 10 -- one decimal, honest small odds
		end
	end
	-- CHANGED: two-stage broadcast so the outcome can't be datamined at spin start. Stage 1 starts
	-- the roller with only the odds table; stage 2 delivers the locked outcome right when the
	-- animation needs it. (It used to ride in stage 1 — an exploiter could read next wave's fate the
	-- moment the break began and pre-position/pre-buy around it.)
	local secs = tonumber(c.SpinSeconds) or 3
	Remotes.Get("EventSpin"):FireAllClients({
		wave = wave,
		seconds = secs,
		odds = odds,
	})
	task.delay(math.max(0.4, secs * 0.5), function()
		-- CHANGED (reel v2): the lock lands at HALF-spin — the client reel needs the target while
		-- still scrolling so the final row can glide in naturally. Still unreadable at spin start.
		Remotes.Get("EventSpin"):FireAllClients({
			wave = wave,
			lock = chosen,
		})
	end)
	print(("[EventService] wave %d roller: %s"):format(wave, chosen))
	return chosen
end

-- The wave is starting: run the spun outcome for the whole wave. MUST be called BEFORE the wave's
-- zombie count is computed — Purge/Bodyguards resize the wave through GetCountMult().
function EventService.BeginWaveEvent(outcome: string?, wave: number)
	EventService.EndWaveEvent() -- belt-and-braces: never stack two wave modifiers
	waveCountMult = 1
	local def = outcome and OUTCOMES[outcome]
	if not def then
		return
	end
	activeEvent = outcome
	gen += 1
	if def.countMultKey then
		waveCountMult = tonumber(cfg()[def.countMultKey]) or 1
	end
	if def.begin then
		task.spawn(def.begin, gen, wave)
	end
end

-- The wave cleared (or the run ended): shut the modifier off.
function EventService.EndWaveEvent()
	waveCountMult = 1
	lastWaveCoinMult = coinMult -- NEW: remember the ended wave's mult for the wave-clear bonus
	if not activeEvent then
		return
	end
	local def = OUTCOMES[activeEvent]
	activeEvent = nil
	gen += 1 -- cancels every event loop / in-flight strike follow-up
	if def and def.stop then
		def.stop()
	end
end

-- The active event's live Coin multiplier — ProgressionService reads this on every kill grant.
function EventService.CoinMult(): number
	return coinMult
end

-- NEW: the coin multiplier the JUST-ENDED wave ran under. The wave-clear bonus fires AFTER
-- EndWaveEvent has reset coinMult, so Blood Moon / Gold Rush / Apocalypse never doubled the
-- 50-coin clear payout — this closes that gap.
function EventService.WaveCoinMult(): number
	return lastWaveCoinMult
end

-- The active event's wave-size multiplier — MatchService reads this when computing the wave count.
function EventService.GetCountMult(): number
	return waveCountMult
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

	-- Scan for the meteor models AT BOOT (not lazily at the first strike) so the Output line that says
	-- what was found — or the warning that says where it looked — is sitting right there on startup.
	task.spawn(getMeteorTemplates)

	-- TOXIC BITES (acid rain / apocalypse): a zombie hit also poisons — 3 extra ticks over ~2.4s.
	-- Listens to the Damaged signal so every zombie attack path is covered without touching them.
	PlayerStateService.Damaged:Connect(function(player, _amount, source)
		if not toxicBites or source ~= "zombie" or poisoned[player] then
			return
		end
		poisoned[player] = true
		task.spawn(function()
			local tickDmg = (tonumber(cfg().AcidDPS) or 8) * 0.5
			for _ = 1, 3 do
				task.wait(0.8)
				if not toxicBites or not player.Parent then
					break
				end
				PlayerStateService.Damage(player, tickDmg, "poison")
			end
			poisoned[player] = nil
		end)
	end)

	print("[EventService] started (the rarity roller is armed)")
end

return EventService
