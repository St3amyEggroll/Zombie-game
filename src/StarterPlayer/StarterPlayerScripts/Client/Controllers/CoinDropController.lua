--!nonstrict
-- CoinDropController.lua — LOOT COINS. Your kills burst gold coins out of the zombie: they scatter
-- with a little bounce, sit on the ground for a beat, then whip into your character — and the HUD
-- coin counter ticks up as each one lands (HUDController.CoinArrived; the real payout is instant and
-- server-authoritative, this is presentation only).
--
-- 100% CLIENT-SIDE + OPTIMIZED BY DESIGN:
--   * Driven by the HitConfirmed remote the killer ALREADY receives — no new network traffic, and
--     only YOUR kills show coins on your screen (each player's client renders their own).
--   * Hard-capped pool of billboard sprites (MAX_COINS): instances are created once and recycled
--     forever — zero Instance churn during play. Overflow recycles the oldest coin instantly.
--   * ONE Heartbeat updater moves every live coin; no physics objects, no Touched events, no rays
--     per frame (one ground raycast per BURST, not per coin).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local HUDController = require(script.Parent.HUDController)

local CoinDropController = {}

-- ===== TUNABLES =====
local COIN_IMAGE   = "rbxassetid://84729396970772" -- the game's coin art (same image as the HUD counter)
local MAX_COINS    = 36    -- hard cap of live coin sprites (pool size — the lag guarantee)
local KILL_MIN, KILL_MAX       = 3, 5   -- coins per normal kill
local SPECIAL_MIN, SPECIAL_MAX = 8, 10  -- coins per special/rare kill
local COIN_STUDS   = 1.15  -- billboard size in studs
local BURST_SPEED_MIN, BURST_SPEED_MAX = 7, 13  -- horizontal scatter speed
local BURST_UP_MIN, BURST_UP_MAX       = 12, 19 -- upward pop speed
local GRAVITY      = 55
local BOUNCE       = 0.34  -- one bounce, then settle
local REST_SECONDS = 0.45  -- how long coins sit on the ground before flying to you
local REST_STAGGER = 0.07  -- extra rest per coin so they leave the ground in a stream, not a clump
local MAGNET_RAMP  = 26    -- magnet acceleration (higher = snappier pull)
local ARRIVE_DIST  = 3.0   -- studs from your torso that counts as collected
local COIN_LIFE    = 4.5   -- absolute failsafe: a coin always finishes by this age (e.g. you died)
local SPIN_SPEED   = 480   -- degrees/sec of sprite spin while flying to you
-- NEW: collect SOUNDS (owner's assets) — random pick per pickup, pitch climbs on quick streaks.
local COIN_SOUNDS  = { "rbxassetid://8646410774", "rbxassetid://134583420216867" }
local SOUND_VOLUME = 0.5
local SOUND_MIN_GAP = 0.045 -- throttle: a horde of arrivals can't stack 10 plays in one frame
local COMBO_PITCH  = 0.025  -- extra playback speed per consecutive quick pickup (the coin cascade)
local COMBO_WINDOW = 0.6    -- seconds between pickups that still count as a streak

local localPlayer = Players.LocalPlayer

local coinFolder: Folder? = nil
local pool: { any } = {}   -- free sprites
local active: { any } = {} -- live coins, oldest first
local made = 0

-- ===== COLLECT SOUND (pooled, throttled, combo pitch) =====
local SoundService = game:GetService("SoundService")
local soundPool: { Sound } = {}
local soundIdx = 1
local lastSoundAt = 0
local combo = 0

local function playCollect()
	if #soundPool == 0 then
		return
	end
	local now = os.clock()
	combo = (now - lastSoundAt < COMBO_WINDOW) and math.min(combo + 1, 10) or 0
	if now - lastSoundAt < SOUND_MIN_GAP then
		return -- still counts toward the combo, just doesn't stack another play this frame
	end
	lastSoundAt = now
	local s = soundPool[soundIdx]
	soundIdx = (soundIdx % #soundPool) + 1
	s.SoundId = COIN_SOUNDS[math.random(#COIN_SOUNDS)]
	s.PlaybackSpeed = 0.96 + math.random() * 0.06 + combo * COMBO_PITCH
	s:Play()
end

local function makeCoin()
	local part = Instance.new("Part")
	part.Name = "Coin"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	local gui = Instance.new("BillboardGui")
	gui.Name = "CoinGui"
	gui.Size = UDim2.new(COIN_STUDS, 0, COIN_STUDS, 0) -- scale = studs (world-sized, distance-correct)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0.4
	gui.MaxDistance = 220
	gui.Enabled = false
	gui.Parent = part
	local img = Instance.new("ImageLabel")
	img.Name = "CoinImage"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.ScaleType = Enum.ScaleType.Fit
	img.Image = COIN_IMAGE
	img.Parent = gui
	part.Parent = coinFolder
	return { part = part, gui = gui, img = img }
end

-- Retire a live coin (index into `active`): hide it, recycle it, tick the HUD counter one step closer
-- to the real total. frac = 1/(coins still in flight) so the LAST arrival always lands exactly on it.
local function finishCoin(index: number)
	local c = table.remove(active, index)
	if not c then
		return
	end
	local frac = 1 / (#active + 1)
	c.gui.Enabled = false
	table.insert(pool, c)
	playCollect()
	HUDController.CoinArrived(frac)
end

local function acquireCoin()
	local c = table.remove(pool)
	if c then
		return c
	end
	if made < MAX_COINS then
		made += 1
		return makeCoin()
	end
	finishCoin(1) -- pool exhausted: the oldest coin gets collected instantly and recycled
	return table.remove(pool)
end

-- Ground height for a burst: ONE ray for the whole burst, ignoring zombies/characters/our own coins.
local function groundYAt(pos: Vector3): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local exclude = { coinFolder }
	local zf = Workspace:FindFirstChild("Zombies")
	if zf then
		table.insert(exclude, zf)
	end
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(exclude, pl.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	local res = Workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -28, 0), params)
	return (res and res.Position.Y or (pos.Y - 2.2)) + COIN_STUDS * 0.55 -- sprite center sits ON the floor
end

local function spawnBurst(pos: Vector3, special: boolean)
	local n = special and math.random(SPECIAL_MIN, SPECIAL_MAX) or math.random(KILL_MIN, KILL_MAX)
	local groundY = groundYAt(pos)
	local now = os.clock()
	HUDController.CoinBurstStarted()
	for i = 1, n do
		local c = acquireCoin()
		if not c then
			break
		end
		local ang = math.random() * math.pi * 2
		local h = BURST_SPEED_MIN + math.random() * (BURST_SPEED_MAX - BURST_SPEED_MIN)
		c.pos = pos
		c.vel = Vector3.new(math.cos(ang) * h, BURST_UP_MIN + math.random() * (BURST_UP_MAX - BURST_UP_MIN), math.sin(ang) * h)
		c.groundY = groundY
		c.phase = 1 -- 1 ballistic, 2 resting, 3 magnet
		c.bounced = false
		c.t0 = now
		c.restAt = 0
		-- NEW: COIN MAGNET (Power Draft) — coins skip the ground rest and fly straight to you.
		if localPlayer:GetAttribute("PowerMagnet") then
			c.restFor = 0
		else
			c.restFor = REST_SECONDS + (i - 1) * REST_STAGGER
		end
		c.spin = math.random(0, 359)
		c.img.Rotation = c.spin
		c.part.Position = pos
		c.gui.Enabled = true
		table.insert(active, c)
	end
end

local function onHeartbeat(dt: number)
	if #active == 0 then
		return
	end
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local target = root and (root.Position + Vector3.new(0, 0.5, 0)) or nil
	local now = os.clock()
	for i = #active, 1, -1 do
		local c = active[i]
		if now - c.t0 > COIN_LIFE then
			finishCoin(i)
			continue
		end
		if c.phase == 1 then -- ballistic scatter (+ one bounce)
			c.vel += Vector3.new(0, -GRAVITY * dt, 0)
			c.pos += c.vel * dt
			if c.pos.Y <= c.groundY and c.vel.Y < 0 then
				if not c.bounced then
					c.bounced = true
					c.vel = Vector3.new(c.vel.X * 0.5, -c.vel.Y * BOUNCE, c.vel.Z * 0.5)
				else
					c.pos = Vector3.new(c.pos.X, c.groundY, c.pos.Z)
					c.phase = 2
					c.restAt = now + c.restFor
				end
			end
		elseif c.phase == 2 then -- resting on the floor
			if now >= c.restAt then
				c.phase = 3
				c.magnetT = 0
			end
		elseif target then -- magnet: exponential pull that ramps up, with a spin
			c.magnetT += dt
			local k = 5 + MAGNET_RAMP * c.magnetT
			c.pos = c.pos:Lerp(target, 1 - math.exp(-k * dt))
			c.spin += SPIN_SPEED * dt
			c.img.Rotation = c.spin
			if (c.pos - target).Magnitude <= ARRIVE_DIST then
				finishCoin(i)
				continue
			end
		end
		c.part.Position = c.pos
	end
end

-- HitConfirmed is fired ONLY to the shooter: (pos, isHeadshot, hit, killed, damage, isCrit, isSpecial).
local function onHitConfirmed(pos: any, _isHeadshot: any, _hit: any, killed: any, _damage: any, _isCrit: any, isSpecial: any)
	if killed == true and typeof(pos) == "Vector3" then
		spawnBurst(pos, isSpecial == true)
	end
end

function CoinDropController.Start()
	coinFolder = Instance.new("Folder")
	coinFolder.Name = "CoinFX_Local" -- client-created: never replicates, each player only has their own
	coinFolder.Parent = Workspace

	-- Collect-sound pool: 4 rotating Sounds through the game's SFX group (respects the volume sliders).
	local sfxGroup = SoundService:FindFirstChild("ZLSFX")
	for _ = 1, 4 do
		local s = Instance.new("Sound")
		s.Name = "CoinCollect"
		s.SoundId = COIN_SOUNDS[1]
		s.Volume = SOUND_VOLUME
		if sfxGroup then
			s.SoundGroup = sfxGroup
		end
		s.Parent = SoundService
		table.insert(soundPool, s)
	end
	task.spawn(function() -- preload so the first pickup isn't silent
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync(soundPool)
		end)
	end)

	Remotes.Get("HitConfirmed").OnClientEvent:Connect(onHitConfirmed)
	RunService.Heartbeat:Connect(onHeartbeat)
	print("[CoinDropController] started (pooled loot coins, cap " .. MAX_COINS .. ")")
end

return CoinDropController
