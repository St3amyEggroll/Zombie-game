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
local RARITY_ORDER = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "divine" }

local gen = 0        -- bumping this cancels every running event task
local folder         -- workspace container for event props (cleared by StopAll)
local activeEvent    -- the outcome currently modifying the wave (nil between waves / on calm)
local coinMult = 1   -- ProgressionService multiplies every kill's Coin grant by this
local waveCountMult = 1 -- MatchService multiplies the wave's zombie count by this (Purge/Bodyguards)

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

-- ===== METEOR MODELS ===== the owner's rocks (meteor1/meteor2): ReplicatedStorage > Assets >
-- Meteors. Lookup is CASE-INSENSITIVE (Roblox's FindFirstChild isn't; folder capitalization must
-- never silently break this), falls back to hunting for anything named "meteor*" anywhere under
-- ReplicatedStorage, and re-scans until it finds something (never caches an empty miss).
local meteorTemplates = nil
local function ciChild(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	local lname = name:lower()
	for _, c in parent:GetChildren() do
		if c.Name:lower() == lname then
			return c
		end
	end
	return nil
end
local function getMeteorTemplates()
	if meteorTemplates and #meteorTemplates > 0 then
		return meteorTemplates
	end
	meteorTemplates = {}
	local mFolder = ciChild(ciChild(ReplicatedStorage, "Assets"), "Meteors")
	if mFolder then
		for _, child in mFolder:GetChildren() do
			if child:IsA("Model") or child:IsA("BasePart") then
				table.insert(meteorTemplates, child)
			end
		end
	end
	if #meteorTemplates == 0 then -- last resort: any MODEL named meteor* anywhere under ReplicatedStorage
		for _, d in ReplicatedStorage:GetDescendants() do
			if d:IsA("Model") and d.Name:lower():match("^meteor") then
				table.insert(meteorTemplates, d)
			end
		end
	end
	if #meteorTemplates == 0 then
		warn("[EventService] no meteor models found (ReplicatedStorage > Assets > Meteors) — using a fallback rock")
	else
		print(("[EventService] %d meteor model(s) loaded"):format(#meteorTemplates))
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
							if rec.isBoss then
								ZombieService.ApplyDamage(rec, (rec.maxHealth or 1000) * bossFrac)
							elseif d <= radius * 0.55 then
								ZombieService.ApplyDamage(rec, math.huge) -- dead center: flattened
							else
								ZombieService.ApplyDamage(rec, (rec.maxHealth or 100) * 0.5)
							end
						end
					end
				end
				if math.random() < 0.25 then -- some craters cough up a zombie
					ZombieService.SpawnExtra(round, nil, CFrame.new(ground + Vector3.new(0, 3, 0)))
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
						if rec.isBoss then
							ZombieService.ApplyDamage(rec, (rec.maxHealth or 1000) * bossFrac)
						else
							ZombieService.ApplyDamage(rec, math.huge)
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
		while myGen == gen do
			local allDead = #guards > 0
			for _, r in guards do
				if not r.dead then
					allDead = false
					break
				end
			end
			if allDead then
				local coins = tonumber(cfg().GuardCoins) or 400
				MatchService.ForEachPlayer(function(pl)
					pcall(function()
						DataService.AddMoney(pl, coins)
						Remotes.Get("LobbyMoneyChanged"):FireClient(pl, DataService.GetMoney(pl))
					end)
				end)
				Remotes.Get("WorldVFX"):FireAllClients("coins", { pos = pile.Position }) -- gold fountain
				announce(("VAULT CRACKED! +%d COINS FOR THE TEAM"):format(coins), "green")
				pile:Destroy()
				return
			end
			task.wait(0.5)
		end
		if pile.Parent then -- wave ended around it (wipe/skip): no payout, clean up
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

-- outcome id -> { rarity, begin(myGen, round), stop(), countMultKey }. Add a wheel outcome = one row
-- here + a LOOK row in EventWheelController + tunables in GameConfig.Events.
local OUTCOMES = {
	calm       = { rarity = "common" },
	fog        = { rarity = "common",    begin = beginFog,        stop = endFog },
	rain       = { rarity = "common",    begin = beginRain,       stop = endRain },
	meteors    = { rarity = "uncommon",  begin = beginMeteors },
	bombsquad  = { rarity = "uncommon",  begin = beginBombSquad,  stop = endBombSquad },
	earthquake = { rarity = "uncommon",  begin = beginEarthquake },
	bloodmoon  = { rarity = "rare",      begin = beginBloodMoon,  stop = endBloodMoon },
	lightning  = { rarity = "rare",      begin = beginLightning },
	acidrain   = { rarity = "rare",      begin = beginAcidRain,   stop = endAcidRain },
	hounds     = { rarity = "rare",      begin = beginHounds,     stop = endHounds },
	purge      = { rarity = "epic",      begin = beginPurge,      stop = endPurge,   countMultKey = "PurgeCountMult" },
	bodyguards = { rarity = "epic",      begin = beginBodyguards, countMultKey = "GuardCountMult" },
	goldrush   = { rarity = "legendary", begin = beginGoldRush,   stop = endGoldRush },
	apocalypse = { rarity = "mythic",    begin = beginApocalypse, stop = endApocalypse },
	godmode    = { rarity = "divine",    begin = beginGodMode,    stop = endGodMode },
}
local BY_RARITY = {} -- rarity -> sorted { outcomeId }
for id, def in OUTCOMES do
	BY_RARITY[def.rarity] = BY_RARITY[def.rarity] or {}
	table.insert(BY_RARITY[def.rarity], id)
end
for _, list in BY_RARITY do
	table.sort(list)
end

-- ===== PUBLIC =====

-- Roll the wheel for `wave` (rarity tier first — common thins per wave — then a uniform event of that
-- tier) and broadcast the visible roll with live per-EVENT odds. Returns the outcome id.
function EventService.SpinForWave(wave: number): string
	local c = cfg()
	local rw = c.RarityWeights or {}
	local w = {}
	local total = 0
	for _, r in RARITY_ORDER do
		local list = BY_RARITY[r]
		if list and #list > 0 then
			local weight = math.max(0, tonumber(rw[r]) or 0)
			if r == "common" then
				weight = math.max(tonumber(c.CommonMin) or 10,
					weight - (tonumber(c.CommonDecayPerWave) or 1.2) * (wave - 1))
			end
			if weight > 0 then
				w[r] = weight
				total += weight
			end
		end
	end
	local chosenRarity = "common"
	if total > 0 then
		local roll = math.random() * total
		local acc = 0
		for _, r in RARITY_ORDER do
			if w[r] then
				acc += w[r]
				if roll <= acc then
					chosenRarity = r
					break
				end
			end
		end
	end
	local list = BY_RARITY[chosenRarity] or BY_RARITY.common
	local chosen = list[math.random(1, #list)]
	-- Per-EVENT odds (%): the tier's slice split evenly across the tier's events — shown on every
	-- flash of the roller so a rare landing FEELS rare.
	local odds = {}
	if total > 0 then
		for r, weight in w do
			local tierList = BY_RARITY[r]
			local per = (weight / total) * 100 / #tierList
			for _, id in tierList do
				odds[id] = math.max(1, math.floor(per + 0.5))
			end
		end
	end
	Remotes.Get("EventSpin"):FireAllClients({
		wave = wave,
		outcome = chosen,
		seconds = tonumber(c.SpinSeconds) or 3,
		odds = odds,
	})
	print(("[EventService] wave %d roller: %s (%s)"):format(wave, chosen, chosenRarity))
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
