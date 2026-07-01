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

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local ShopConfig = require(Config.ShopConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)
local ZombieService = require(script.Parent.ZombieService)

local CombatService = {}

-- ===== TUNABLES =====
local MAX_ORIGIN_DIST   = 6     -- studs the claimed shot origin may be from the player's HumanoidRootPart
                                -- (legit client sends Head.Position, ~2 studs out; tight enough that a
                                --  spoofed origin can't be relocated past cover to peek around walls)
local FIRE_RATE_SLACK    = 0.85  -- allow shots up to 15% faster than nominal (latency/jitter); still gated
local MAX_RANGE_HARD     = 1000  -- absolute raycast distance ceiling regardless of weapon.range

-- ===== SIGNALS (other services subscribe; fired on damage/kill of a non-player Humanoid) =====
local hitEvent = Instance.new("BindableEvent")
local killEvent = Instance.new("BindableEvent")
local equippedEvent = Instance.new("BindableEvent")
local firedEvent = Instance.new("BindableEvent")
local reloadEvent = Instance.new("BindableEvent")
CombatService.Hit = hitEvent.Event           -- (player, humanoid, isHeadshot, weaponId, damage)
CombatService.Kill = killEvent.Event         -- (player, humanoid, isHeadshot, weaponId)
CombatService.Equipped = equippedEvent.Event -- (player) — loadout/equip changed
CombatService.Fired = firedEvent.Event       -- (player, weaponId) — a valid shot went out (drives recoil)
CombatService.ReloadStarted = reloadEvent.Event -- (player, weaponId, duration) — drives the reload anim

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
-- The player's current in-run buff total for a stat (additive fraction; 0 if none). Set by BuffService.
local function buffOf(ps, key: string): number
	return (ps.buffs and ps.buffs[key]) or 0
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

-- Range-falloff damage multiplier: 1.0 within FalloffStart, lerping down to FalloffMinMult at FalloffEnd.
local function falloffMult(dist: number): number
	local s, e = GameConfig.FalloffStart, GameConfig.FalloffEnd
	if dist <= s or e <= s then
		return 1
	end
	local t = math.clamp((dist - s) / (e - s), 0, 1)
	return 1 + (GameConfig.FalloffMinMult - 1) * t
end

-- Spread the aim direction inside a cone of `spreadDeg` degrees (server owns the randomness).
local function applySpread(direction: Vector3, spreadDeg: number): Vector3
	if spreadDeg <= 0 then
		return direction
	end
	local dir = direction.Unit
	-- Pick an up reference that is never parallel to `dir`, so CFrame.lookAt stays well-defined even
	-- when aiming exactly straight up/down (otherwise its LookVector is NaN → a wasted, no-effect shot).
	local up = (math.abs(dir.Y) > 0.999) and Vector3.xAxis or Vector3.yAxis
	local s = math.rad(spreadDeg)
	local yaw = (math.random() * 2 - 1) * s
	local pitch = (math.random() * 2 - 1) * s
	return (CFrame.lookAt(Vector3.zero, dir, up) * CFrame.Angles(pitch, yaw, 0)).LookVector
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

	-- 5a) fire-rate gate (Attack Speed buff lets you fire faster)
	local now = os.clock()
	local effFireRate = weapon.fireRate * (1 + buffOf(ps, "attackspeed"))
	local minInterval = (1 / effFireRate) * FIRE_RATE_SLACK
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
	firedEvent:Fire(player, weaponId) -- drives the server-side gun recoil

	-- 6) AUTO-AIM: hit the CLOSEST live zombie within ArcRange that sits in the forward arc (centered on the
	-- aim direction) and is in line of sight. The bullet (tracer) then travels to that zombie.
	local character = player.Character
	local dir = direction.Unit
	local baseDamage = weapon.damage
		* ShopConfig.DamageMultFor(ps.upgrades and ps.upgrades[weaponId] or 0)
		* (1 + buffOf(ps, "damage")) -- Damage buff
	local arcRange = GameConfig.ArcRange
	local dotThreshold = math.cos(math.rad(GameConfig.ArcDegrees * 0.5)) -- 180° -> 0 (forward hemisphere)

	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude
	losParams.IgnoreWater = true
	losParams.FilterDescendantsInstances = { character, ZombieService.GetFolder() }

	-- Shotguns fire `pellets` per shot; everything else fires 1. The effective reach is the shorter of the
	-- global arc range and the weapon's own range (so a shotgun is genuinely short-range).
	local effRange = math.min(arcRange, weapon.range or arcRange) * (1 + buffOf(ps, "range")) -- Attack Range buff
	local pellets = math.max(1, weapon.pellets or 1)

	-- Collect in-arc, in-range zombies, nearest first.
	local cands = {}
	for _, record in ZombieService.GetActive() do
		local root = record.root
		local toZombie = root.Position - origin
		local dist = toZombie.Magnitude
		if dist > 0.01 and dist <= effRange and toZombie.Unit:Dot(dir) >= dotThreshold then
			table.insert(cands, { record = record, root = root, dist = dist })
		end
	end
	table.sort(cands, function(a, b)
		return a.dist < b.dist
	end)

	-- How many distinct zombies the pellets may spread across. Default 1 = all pellets dump into the
	-- closest zombie (the shotgun focuses one target). A weapon can set maxTargets > 1 to spread.
	local maxTargets = math.max(1, weapon.maxTargets or 1)

	-- Take up to `maxTargets` distinct VISIBLE targets (line of sight checked), nearest first.
	local targets = {}
	for _, c in cands do
		if #targets >= maxTargets then
			break
		end
		if not Workspace:Raycast(origin, c.root.Position - origin, losParams) then
			table.insert(targets, c)
		end
	end

	local endpoint = origin + dir * effRange -- where the tracer lands on a miss (straight ahead)
	if #targets > 0 then
		-- Distribute pellets round-robin across the targets (nearest get the extras): all pellets dump into
		-- one zombie up close, but spread across a crowd. For a 1-pellet gun this is just "hit the closest".
		local pelletsOn = {}
		for i = 1, pellets do
			local idx = ((i - 1) % #targets) + 1
			pelletsOn[idx] = (pelletsOn[idx] or 0) + 1
		end
		for idx, count in pelletsOn do
			local c = targets[idx]
			local humanoid = c.record.hum
			local damage = baseDamage * falloffMult(c.dist) * count
				if math.random() < buffOf(ps, "critchance") then damage *= (1 + GameConfig.CritBaseBonus + buffOf(ps, "critdamage")) end -- Crit buffs
			humanoid.Health = math.max(0, humanoid.Health - damage)
			local killed = humanoid.Health <= 0
			ZombieService.NoteHit(c.record, origin) -- so a kill launches the ragdoll away from the shooter
			hitEvent:Fire(player, humanoid, false, weaponId, damage)
			if killed then
				killEvent:Fire(player, humanoid, false, weaponId)
			else
				ZombieService.Hit(c.record, origin) -- knockback + white flash
			end
			Remotes.Get("HitConfirmed"):FireClient(player, c.root.Position, false, true, killed, math.floor(damage + 0.5))
			-- A tracer to each zombie hit (a shotgun visibly sprays).
			Remotes.Get("ShotFired"):FireAllClients(player.UserId, origin, c.root.Position, weaponId)
		end
	else
		Remotes.Get("ShotFired"):FireAllClients(player.UserId, origin, endpoint, weaponId) -- miss: one tracer straight ahead
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
	local duration = weapon.reloadSeconds
	reloadEvent:Fire(player, weaponId, duration) -- drives the reload animation

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

-- ===== LOADOUT (Phase 3: buying weapons makes weapon switching matter) =====
local function fireLoadout(player: Player, ps)
	Remotes.Get("LoadoutChanged"):FireClient(player, ps.ownedWeapons, ps.equippedWeapon)
	equippedEvent:Fire(player) -- WeaponModelService re-attaches the in-hand model
end

-- Grant a weapon (wall-buy / box) and auto-equip it. Idempotent on ownership; always refills its ammo.
function CombatService.GrantWeapon(player: Player, weaponId: string): boolean
	local weapon = WeaponConfig[weaponId]
	if not weapon then
		return false
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return false
	end
	if not Util.Contains(ps.ownedWeapons, weaponId) then
		table.insert(ps.ownedWeapons, weaponId)
	end
	ps.ammo[weaponId] = { mag = weapon.magSize, reserve = weapon.reserveAmmo }
	ps.equippedWeapon = weaponId
	fireAmmo(player, weaponId, ps.ammo[weaponId])
	fireLoadout(player, ps)
	return true
end

-- Refill a weapon's reserve to full (wall ammo / Ammo buy). Leaves the magazine for the player to reload.
function CombatService.RefillAmmo(player: Player, weaponId: string): boolean
	local weapon = WeaponConfig[weaponId]
	if not weapon then
		return false
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return false
	end
	local a = ensureAmmo(ps, weaponId, weapon)
	a.reserve = weapon.reserveAmmo
	fireAmmo(player, weaponId, a)
	return true
end

-- Add `frac` of each owned weapon's FULL reserve back to its reserve (capped). Used by ammo pickups.
function CombatService.GiveAmmoFraction(player: Player, frac: number): boolean
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return false
	end
	for _, weaponId in ps.ownedWeapons do
		local weapon = WeaponConfig[weaponId]
		if weapon then
			local a = ensureAmmo(ps, weaponId, weapon)
			local add = math.ceil(weapon.reserveAmmo * frac)
			a.reserve = math.min(weapon.reserveAmmo, a.reserve + add)
			fireAmmo(player, weaponId, a)
		end
	end
	return true
end

-- Client requests to equip an owned weapon.
local function onEquip(player: Player, weaponId: any)
	if not SecurityService.Allow(player, "Interact") then
		return
	end
	if typeof(weaponId) ~= "string" then
		return
	end
	local weapon = WeaponConfig[weaponId]
	if not weapon then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not Util.Contains(ps.ownedWeapons, weaponId) then
		return
	end
	ps.equippedWeapon = weaponId
	local a = ensureAmmo(ps, weaponId, weapon)
	fireAmmo(player, weaponId, a)
	fireLoadout(player, ps)
end

-- ===== INITIAL SYNC =====
-- Send the client its current ammo + loadout (and reset fire timing) when a character spawns.
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
	fireLoadout(player, ps)
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
	Remotes.Get("EquipWeapon").OnServerEvent:Connect(onEquip)

	print("[CombatService] started (server-authoritative fire)")
end

return CombatService
