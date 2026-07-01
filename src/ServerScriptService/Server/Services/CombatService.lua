--!nonstrict
-- CombatService.lua — server-authoritative shooting. **THE #1 exploit surface (CLAUDE.md §14).**
--
-- The client sends ONLY intent: (weaponId, origin, direction). The server then, in order:
--   1) rate-limits (token bucket),         4) validates the origin is near the real player,
--   2) validates the player is alive,      5) enforces the weapon is EQUIPPED + fire-rate server-side,
--   3) validates types/ranges,             6) picks the target server-side and computes ALL damage.
-- No client damage, no client kill claims. Server owns everything. (No ammo — guns never run dry.)
--
-- Damage targets are zombies from ZombieService.GetActive(). Hit/Kill signals below let
-- PointsService / BuffService / GameInventoryService / the juice plug in without touching this file.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
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
local FIRE_RATE_SLACK    = 0.85  -- fire-gate refill runs at fireRate/this (15% headroom for latency/jitter)
local FIRE_BURST         = 2     -- token-bucket capacity: absorbs frame-bunched arrivals instead of dropping them

-- ===== SIGNALS (other services subscribe; fired on damage/kill of a non-player Humanoid) =====
local hitEvent = Instance.new("BindableEvent")
local killEvent = Instance.new("BindableEvent")
local equippedEvent = Instance.new("BindableEvent")
local firedEvent = Instance.new("BindableEvent")
CombatService.Hit = hitEvent.Event           -- (player, humanoid, isHeadshot, weaponId, damage)
CombatService.Kill = killEvent.Event         -- (player, humanoid, isHeadshot, weaponId)
CombatService.Equipped = equippedEvent.Event -- (player) — loadout/equip changed
CombatService.Fired = firedEvent.Event       -- (player, weaponId) — a valid shot went out (drives recoil)

-- ===== PER-PLAYER COMBAT STATE =====
-- combat[userId] = { fire = { tokens, last } } — the per-player fire-rate token bucket
local combat: { [number]: any } = {}

local function getCombat(player: Player)
	local c = combat[player.UserId]
	if not c then
		c = { fire = nil }
		combat[player.UserId] = c
	end
	return c
end

-- ===== HELPERS =====
-- The player's current in-run buff total for a stat (additive fraction; 0 if none). Set by BuffService.
local function buffOf(ps, key: string): number
	return (ps.buffs and ps.buffs[key]) or 0
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
	-- own the weapon AND actually be holding it — an exploiter must not fire every owned weapon in
	-- parallel (each weapon would otherwise get its own independent fire-rate gate).
	if weaponId ~= ps.equippedWeapon or not Util.Contains(ps.ownedWeapons, weaponId) then
		return
	end
	-- 4) origin must be near the server's known player position
	if not SecurityService.OriginNearPlayer(player, origin, MAX_ORIGIN_DIST) then
		return
	end

	local c = getCombat(player)

	-- 5) fire-rate gate — CONSTANT per weapon, enforced with a small token bucket instead of a strict
	-- inter-arrival check: remotes drain per server frame, so two legit shots can arrive bunched together
	-- (network jitter / a 30Hz horde frame). The bucket refills at fireRate/FIRE_RATE_SLACK and holds
	-- FIRE_BURST, so the AVERAGE rate is still hard-capped but frame-bunched shots aren't silently eaten.
	-- One bucket per player (not per weapon): switching weapons can't reset your cadence.
	local now = os.clock()
	local refill = weapon.fireRate / FIRE_RATE_SLACK
	local b = c.fire
	if not b then
		b = { tokens = 1, last = now }
		c.fire = b
	end
	b.tokens = math.min(FIRE_BURST, b.tokens + (now - b.last) * refill)
	b.last = now
	if b.tokens < 1 then
		return
	end
	b.tokens -= 1

	firedEvent:Fire(player, weaponId) -- drives the server-side gun recoil

	-- 6) AUTO-AIM: hit the CLOSEST live zombie within ArcRange that sits in the forward arc (centered on the
	-- aim direction) and is in line of sight. The bullet (tracer) then travels to that zombie.
	local dir = direction.Unit
	-- The arc test is FLAT (Y ignored) on BOTH client and server: the third-person cursor often rests on
	-- the ground near a zombie, which pitches the raw 3D aim down — flat matching keeps the rules identical
	-- to AimController's lock rule, so what locks is exactly what hits. Distance/falloff stay 3D.
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	flatDir = (flatDir.Magnitude > 0.01) and flatDir.Unit or dir
	local baseDamage = weapon.damage * (1 + buffOf(ps, "damage")) -- Damage buff
	local arcRange = GameConfig.ArcRange
	local dotThreshold = math.cos(math.rad(GameConfig.ArcDegrees * 0.5)) -- 180° -> 0 (forward hemisphere)

	-- LOS ray ignores zombies AND every player's character: there is no friendly fire, so a teammate
	-- crossing your line must not silently absorb your shot (bodies are not cover).
	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude
	losParams.IgnoreWater = true
	local losExclude = { ZombieService.GetFolder() }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(losExclude, pl.Character)
		end
	end
	losParams.FilterDescendantsInstances = losExclude

	-- Shotguns fire `pellets` per shot; everything else fires 1. The effective reach is the shorter of the
	-- global arc range and the weapon's own range (so a shotgun is genuinely short-range).
	local effRange = math.min(arcRange, weapon.range or arcRange) * (1 + buffOf(ps, "range")) -- Attack Range buff
	local pellets = math.max(1, weapon.pellets or 1)

	-- Collect in-arc, in-range zombies, nearest first (flat angle test — see flatDir above).
	local cands = {}
	for _, record in ZombieService.GetActive() do
		local root = record.root
		local toZombie = root.Position - origin
		local dist = toZombie.Magnitude
		local flatTo = Vector3.new(toZombie.X, 0, toZombie.Z)
		if dist > 0.01 and dist <= effRange and flatTo.Magnitude > 0.01 and flatTo.Unit:Dot(flatDir) >= dotThreshold then
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
				ZombieService.Hit(c.record, origin, weapon.knockback) -- per-weapon knockback + white flash
			end
			Remotes.Get("HitConfirmed"):FireClient(player, c.root.Position, false, true, killed, math.floor(damage + 0.5))
			-- A tracer to each zombie hit (a shotgun visibly sprays).
			Remotes.Get("ShotFired"):FireAllClients(player.UserId, origin, c.root.Position, weaponId)
		end
	else
		Remotes.Get("ShotFired"):FireAllClients(player.UserId, origin, endpoint, weaponId) -- miss: one tracer straight ahead
	end
end

-- ===== LOADOUT =====
local function fireLoadout(player: Player, ps)
	Remotes.Get("LoadoutChanged"):FireClient(player, ps.ownedWeapons, ps.equippedWeapon)
	equippedEvent:Fire(player) -- WeaponModelService re-attaches the in-hand model
end

-- Core equip: validate ownership, set the equipped weapon, sync the loadout to the client + model.
local function applyEquip(player: Player, weaponId: string): boolean
	local weapon = WeaponConfig[weaponId]
	if not weapon then
		return false
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not Util.Contains(ps.ownedWeapons, weaponId) then
		return false
	end
	if ps.equippedWeapon == weaponId then
		return true -- already holding it
	end
	ps.equippedWeapon = weaponId
	fireLoadout(player, ps)
	return true
end

-- Client requests to equip an owned weapon (rate-limited).
local function onEquip(player: Player, weaponId: any)
	if not SecurityService.Allow(player, "Interact") then
		return
	end
	if typeof(weaponId) ~= "string" then
		return
	end
	applyEquip(player, weaponId)
end

-- Server-side equip helper (no rate limit) for other services that need to force an equip.
function CombatService.SetEquipped(player: Player, weaponId: string): boolean
	return applyEquip(player, weaponId)
end

-- ===== INITIAL SYNC =====
-- Send the client its current loadout (and reset fire timing) when a character spawns.
local function onCharacterAdded(player: Player)
	local c = getCombat(player)
	c.fire = nil
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return
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
	Remotes.Get("EquipWeapon").OnServerEvent:Connect(onEquip)

	print("[CombatService] started (server-authoritative fire)")
end

return CombatService
