--!nonstrict
-- CombatService.lua — server-authoritative shooting. **THE #1 exploit surface (CLAUDE.md §14).**
--
-- The client sends ONLY intent: (weaponId, origin, direction). The server then, in order:
--   1) rate-limits (token bucket),         4) validates the origin is near the real player,
--   2) validates the player is alive,      5) enforces ammo + fire-rate server-side,
--   3) validates types/ranges,             6) RAYCASTS on the server and computes ALL damage.
-- No client damage, no client kill claims, no client ammo counts. Server owns everything.
--
-- Damage targets are non-player Humanoids (test dummies now; zombies in Phase 2). Hit/Kill signals
-- below let PointsService (Phase 3) and the juice (Phase 4) plug in without touching this file.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local PerkConfig = require(Config.PerkConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)

local CombatService = {}

-- ===== TUNABLES =====
local MAX_ORIGIN_DIST   = 14    -- studs the claimed shot origin may be from the player's HumanoidRootPart
local FIRE_RATE_SLACK    = 0.85  -- allow shots up to 15% faster than nominal (latency/jitter); still gated
local MAX_RANGE_HARD     = 1000  -- absolute raycast distance ceiling regardless of weapon.range

-- ===== SIGNALS (other services subscribe; fired on damage/kill of a non-player Humanoid) =====
local hitEvent = Instance.new("BindableEvent")
local killEvent = Instance.new("BindableEvent")
CombatService.Hit = hitEvent.Event    -- (player, humanoid, isHeadshot, weaponId, damage)
CombatService.Kill = killEvent.Event  -- (player, humanoid, isHeadshot, weaponId)

-- ===== PER-PLAYER COMBAT STATE =====
-- combat[userId] = { lastShot = {[weaponId]=clock}, reloading = {[weaponId]=bool} }
local combat: { [number]: any } = {}

local function getCombat(player: Player)
	local c = combat[player.UserId]
	if not c then
		c = { lastShot = {}, reloading = {} }
		combat[player.UserId] = c
	end
	return c
end

-- ===== HELPERS =====
local function hasPerk(ps, perkId: string): boolean
	return Util.Contains(ps.perks, perkId)
end

local function effectiveFireRate(ps, weapon): number
	local rate = weapon.fireRate
	if hasPerk(ps, "doubletap") then
		rate *= PerkConfig.doubletap.fireRateMult
	end
	return rate
end

local function effectiveReload(ps, weapon): number
	local secs = weapon.reloadSeconds
	if hasPerk(ps, "speed") then
		secs *= PerkConfig.speed.reloadMult
	end
	return secs
end

local function ensureAmmo(ps, weaponId: string, weapon)
	local a = ps.ammo[weaponId]
	if not a then
		a = { mag = weapon.magSize, reserve = weapon.reserveAmmo }
		ps.ammo[weaponId] = a
	end
	return a
end

local function fireAmmo(player: Player, weaponId: string, a)
	Remotes.Get("AmmoChanged"):FireClient(player, weaponId, a.mag, a.reserve)
end

-- Climb from a hit part to the nearest Humanoid (zombie/dummy bodies are Models with a Humanoid).
local function findHumanoid(part: BasePart): Humanoid?
	local current: Instance? = part
	while current and current ~= Workspace do
		local h = current:FindFirstChildOfClass("Humanoid")
		if h then
			return h
		end
		current = current.Parent
	end
	return nil
end

local function isPlayerHumanoid(humanoid: Humanoid): boolean
	local model = humanoid.Parent
	return model ~= nil and Players:GetPlayerFromCharacter(model) ~= nil
end

-- Spread the aim direction inside a cone of `spreadDeg` degrees (server owns the randomness).
local function applySpread(direction: Vector3, spreadDeg: number): Vector3
	if spreadDeg <= 0 then
		return direction
	end
	local s = math.rad(spreadDeg)
	local yaw = (math.random() * 2 - 1) * s
	local pitch = (math.random() * 2 - 1) * s
	return (CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles(pitch, yaw, 0)).LookVector
end

-- ===== FIRE =====
local function onFire(player: Player, weaponId: any, origin: any, direction: any)
	-- 1) rate limit
	if not SecurityService.Allow(player, "Fire") then
		return
	end
	-- 3) type validation
	if typeof(weaponId) ~= "string" then
		return
	end
	local weapon = WeaponConfig[weaponId]
	if not weapon then
		return
	end
	if not SecurityService.IsFiniteVector3(origin) or not SecurityService.IsValidDirection(direction) then
		return
	end
	-- 2) alive
	if not SecurityService.IsAlive(player) then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return
	end
	-- own the weapon
	if not Util.Contains(ps.ownedWeapons, weaponId) then
		return
	end
	-- 4) origin must be near the server's known player position
	if not SecurityService.OriginNearPlayer(player, origin, MAX_ORIGIN_DIST) then
		return
	end

	local c = getCombat(player)
	if c.reloading[weaponId] then
		return
	end

	-- 5a) fire-rate gate
	local now = os.clock()
	local minInterval = (1 / effectiveFireRate(ps, weapon)) * FIRE_RATE_SLACK
	local last = c.lastShot[weaponId] or 0
	if now - last < minInterval then
		return
	end
	c.lastShot[weaponId] = now

	-- 5b) ammo
	local ammo = ensureAmmo(ps, weaponId, weapon)
	if ammo.mag <= 0 then
		return -- client must reload; no shot, no ammo spent
	end
	ammo.mag -= 1
	ps.equippedWeapon = weaponId
	fireAmmo(player, weaponId, ammo)

	-- 6) server raycast(s)
	local character = player.Character
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	rayParams.IgnoreWater = true

	local dir = direction.Unit
	local range = math.min(weapon.range, MAX_RANGE_HARD)
	local packMult = ps.packAPunched[weaponId] and weapon.ppDamageMult or 1
	local pellets = math.max(1, weapon.pellets)

	for _ = 1, pellets do
		local pelletDir = applySpread(dir, weapon.spread)
		local result = Workspace:Raycast(origin, pelletDir * range, rayParams)
		if result then
			local hitPart = result.Instance
			local humanoid = findHumanoid(hitPart)
			if humanoid and humanoid.Health > 0 and not isPlayerHumanoid(humanoid) then
				local isHead = (hitPart.Name == "Head")
				local damage = weapon.damage * (isHead and weapon.headshotMult or 1) * packMult
				humanoid.Health = math.max(0, humanoid.Health - damage)
				local killed = humanoid.Health <= 0

				hitEvent:Fire(player, humanoid, isHead, weaponId, damage)
				if killed then
					killEvent:Fire(player, humanoid, isHead, weaponId)
				end
				Remotes.Get("HitConfirmed"):FireClient(player, result.Position, isHead, true, killed)
			else
				-- world / non-damageable impact (still drives an impact effect later)
				Remotes.Get("HitConfirmed"):FireClient(player, result.Position, false, false, false)
			end
		end
	end
end

-- ===== RELOAD =====
local function onReload(player: Player, weaponId: any)
	if not SecurityService.Allow(player, "Reload") then
		return
	end
	if typeof(weaponId) ~= "string" then
		return
	end
	local weapon = WeaponConfig[weaponId]
	if not weapon then
		return
	end
	if not SecurityService.IsAlive(player) then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not Util.Contains(ps.ownedWeapons, weaponId) then
		return
	end

	local c = getCombat(player)
	if c.reloading[weaponId] then
		return
	end
	local ammo = ensureAmmo(ps, weaponId, weapon)
	if ammo.mag >= weapon.magSize or ammo.reserve <= 0 then
		return
	end

	c.reloading[weaponId] = true
	local duration = effectiveReload(ps, weapon)

	task.delay(duration, function()
		c.reloading[weaponId] = false
		-- Abort if the player left or died mid-reload.
		if not player.Parent or not SecurityService.IsAlive(player) then
			return
		end
		local ps2 = MatchService.GetPlayerState(player)
		if not ps2 then
			return
		end
		local a = ps2.ammo[weaponId]
		if not a then
			return
		end
		local need = weapon.magSize - a.mag
		local take = math.min(need, a.reserve)
		if take > 0 then
			a.mag += take
			a.reserve -= take
			fireAmmo(player, weaponId, a)
		end
	end)
end

-- ===== INITIAL SYNC =====
-- Send the client its current ammo (and reset fire timing) when a character spawns.
local function onCharacterAdded(player: Player)
	local c = getCombat(player)
	c.lastShot = {}
	c.reloading = {}
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return
	end
	for _, weaponId in ps.ownedWeapons do
		local weapon = WeaponConfig[weaponId]
		if weapon then
			local a = ensureAmmo(ps, weaponId, weapon)
			fireAmmo(player, weaponId, a)
		end
	end
end

local function hookPlayer(player: Player)
	getCombat(player)
	player.CharacterAdded:Connect(function()
		-- Small delay lets MatchService assign player state on join before we read it.
		task.defer(onCharacterAdded, player)
	end)
	if player.Character then
		task.defer(onCharacterAdded, player)
	end
end

-- ===== LIFECYCLE =====
function CombatService.Start()
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		combat[player.UserId] = nil
	end)

	Remotes.Get("FireWeapon").OnServerEvent:Connect(onFire)
	Remotes.Get("Reload").OnServerEvent:Connect(onReload)

	print("[CombatService] started (server-authoritative fire)")
end

return CombatService
