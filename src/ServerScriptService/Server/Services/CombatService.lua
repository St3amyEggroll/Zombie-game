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
local ClassConfig = require(Config.ClassConfig)
local WeaponConfig = require(Config.WeaponConfig)
local GunLevelConfig = require(Config.GunLevelConfig)
local AnimationConfig = require(Config.AnimationConfig)
local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)

local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)
local ZombieService = require(script.Parent.ZombieService)
local DataService = require(script.Parent.DataService)
local SoundFXService = require(script.Parent.SoundFXService)

local CombatService = {}

-- ===== TUNABLES =====
local MAX_ORIGIN_DIST   = 6     -- studs the claimed shot origin may be from the player's HumanoidRootPart
                                -- (legit client sends Head.Position, ~2 studs out; tight enough that a
                                --  spoofed origin can't be relocated past cover to peek around walls)
local FIRE_RATE_SLACK    = 0.85  -- fire-gate refill runs at fireRate/this (15% headroom for latency/jitter)
local FIRE_BURST         = 2     -- token-bucket capacity: absorbs frame-bunched arrivals instead of dropping them

-- ===== SIGNALS (other services subscribe; fired on damage/kill of a zombie). CUSTOM ENTITIES: the
-- second argument is the zombie MODEL now (zombies have no Humanoid; health lives in ZombieService). =====
local hitEvent = Instance.new("BindableEvent")
local killEvent = Instance.new("BindableEvent")
local equippedEvent = Instance.new("BindableEvent")
local firedEvent = Instance.new("BindableEvent")
CombatService.Hit = hitEvent.Event           -- (player, zombieModel, isHeadshot, weaponId, damage)
CombatService.Kill = killEvent.Event         -- (player, zombieModel, isHeadshot, weaponId)
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

-- Where a shot VISUALLY lands: the zombie's torso center, scattered by the weapon's ImpactSpread so every
-- bullet doesn't hit the exact same pixel. Offset lies in the torso's own sideways/vertical plane (the root
-- faces the shooter), kept small so it stays on the body. Purely cosmetic — damage is applied separately.
local function visualHitPos(root: BasePart, weaponId: string): Vector3
	local cfg = AnimationConfig.ImpactSpread
	local s = (cfg and ((cfg.PerWeapon and cfg.PerWeapon[weaponId]) or cfg.Default)) or 0
	if s <= 0 then
		return root.Position
	end
	local dx = (math.random() * 2 - 1) * s          -- sideways across the torso
	local dy = (math.random() * 2 - 1) * s * 1.3    -- a touch more vertical (torsos are taller than wide)
	return root.Position + root.CFrame.RightVector * dx + root.CFrame.UpVector * dy
end

-- ===== FIRE =====
-- ===== EXPLOSIONS / SPLASH (weapon.aoe: Rocket, Plasma) =====
-- A quick server-side blast sphere (replicates to everyone) + the Explosion sound.
local function spawnBlastVFX(center: Vector3, radius: number)
	-- Clients render the layered detonation (fire burst + smoke + sparks + shockwave ring) — see
	-- WorldVFXController. The server only announces it.
	Remotes.Get("WorldVFX"):FireAllClients("boom", { pos = center, r = radius })
end

-- Damage every live zombie within cfg.radius of `center` (full at the center → 50% at the edge). Kills
-- credit the shooter (fires killEvent) so AoE pays cash/XP exactly like a direct hit.
local function applyAoE(player: Player, weaponId: string, center: Vector3, cfg)
	local radius = math.max(1, cfg.radius or 12)
	local dmg = math.max(0, cfg.damage or 0)
	if dmg > 0 then
		for _, rec in ZombieService.GetActive() do
			local root = rec.root
			if root then
				local dist = (root.Position - center).Magnitude
				if dist <= radius then
					local dealt = dmg * (1 - (dist / radius) * 0.5)
					ZombieService.NoteHit(rec, center)
					local killed = ZombieService.ApplyDamage(rec, dealt)
					hitEvent:Fire(player, rec.model, false, weaponId, dealt)
					if killed then
						killEvent:Fire(player, rec.model, false, weaponId)
					else
						ZombieService.Hit(rec, center, 24)
					end
					-- CHANGED: confirm EVERY splash hit to the shooter (not just kills), so AoE weapons
					-- (rocket/plasma) show damage numbers on everything they hit instead of feeling silent.
					-- The client's damage-number budget caps the visual so a horde-wide blast can't lag.
					Remotes.Get("HitConfirmed"):FireClient(player, root.Position, false, true, killed,
						math.floor(dealt + 0.5), false, rec.model:GetAttribute("IsSpecial") == true)
				end
			end
		end
	end
	spawnBlastVFX(center, radius)
	SoundFXService.Emit("Explosion", center)
end

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
	if not ps or ps.isDead then
		return -- dead players can't shoot (they're spectating)
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

	-- Effective stats = base weapon stats at the gun's PERSISTENT level (leveled up in the lobby with
	-- case copies + Coins; saved on the profile, read-only during a run).
	local data = DataService.Get(player)
	local gunLevel = (data and typeof(data.gunLevels) == "table" and tonumber(data.gunLevels[weaponId])) or 1
	local eff = GunLevelConfig.EffectiveStats(weapon, gunLevel)

	-- 5) fire-rate gate — CONSTANT per weapon (+ its upgrades), enforced with a small token bucket instead
	-- of a strict inter-arrival check: remotes drain per server frame, so two legit shots can arrive bunched
	-- together (network jitter / a 30Hz horde frame). The bucket refills at fireRate/FIRE_RATE_SLACK and
	-- holds FIRE_BURST, so the AVERAGE rate is still hard-capped but frame-bunched shots aren't eaten.
	-- One bucket per player (not per weapon): switching weapons can't reset your cadence.
	local now = os.clock()
	local refill = eff.fireRate / FIRE_RATE_SLACK
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
	-- Damage = base weapon damage (potions + the buff draft were removed; buffOf stays for future use),
	-- times the SOLDIER class's damage multiplier when equipped (picked in the lobby showcase).
	local baseDamage = eff.damage * (1 + buffOf(ps, "damage"))
	do
		local data = DataService.Get(player)
		local cls = data and ClassConfig.Get(data.class)
		if cls and cls.damageMult then
			baseDamage *= cls.damageMult
		end
	end
	local arcRange = GameConfig.ArcRange
	-- Pellet weapons can hit across a WIDER arc than the global cone (weapon.spreadArc — the shotgun
	-- sprays the crowd, not one line). The client lock rule stays on the narrower global arc, which is
	-- fine: a lock is only needed to fire; the pellets then find the wider crowd.
	local arcDegrees = math.max(GameConfig.ArcDegrees, weapon.spreadArc or 0)
	local dotThreshold = math.cos(math.rad(arcDegrees * 0.5)) -- 180° -> 0 (forward hemisphere)

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
	-- global arc range and the weapon's (upgraded) range — so a shotgun is genuinely short-range.
	local effRange = math.min(arcRange, eff.range or arcRange) * (1 + buffOf(ps, "range")) -- Attack Range buff
	local pellets = math.max(1, eff.pellets)

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

	-- PIERCE ability (weapon.pierce = N): after the first target locks, the round keeps flying — up to
	-- N zombies standing in a TIGHT lane behind it (±PIERCE_ARC°) each take FULL damage. No LOS re-check
	-- past the first target: the bullet is already inside the crowd (bodies are what it pierces).
	if weapon.pierce and weapon.pierce > 1 and targets[1] then
		local laneDot = math.cos(math.rad(10)) -- half-angle of the pierce lane
		local laneDir = (targets[1].root.Position - origin)
		laneDir = Vector3.new(laneDir.X, 0, laneDir.Z)
		laneDir = laneDir.Magnitude > 0.01 and laneDir.Unit or flatDir
		for _, c in cands do
			if #targets >= weapon.pierce then
				break
			end
			if c ~= targets[1] then
				local flatTo = Vector3.new(c.root.Position.X - origin.X, 0, c.root.Position.Z - origin.Z)
				if flatTo.Magnitude > 0.01 and flatTo.Unit:Dot(laneDir) >= laneDot then
					table.insert(targets, c)
				end
			end
		end
	end

	-- Bullets fly at GUN level: a miss goes straight ahead HORIZONTALLY — the cursor can't pitch shots
	-- into the sky or the floor. Only a real target above/below angles a shot (the hit path below sends
	-- its tracer at the zombie itself).
	local endpoint = origin + flatDir * effRange
	if #targets > 0 then
		-- Distribute pellets round-robin across the targets (nearest get the extras): all pellets dump into
		-- one zombie up close, but spread across a crowd. For a 1-pellet gun this is just "hit the closest".
		local pelletsOn = {}
		if weapon.pierce and weapon.pierce > 1 then
			for i = 1, #targets do
				pelletsOn[i] = 1 -- pierce: every lined-up zombie takes one FULL hit
			end
		else
			for i = 1, pellets do
				local idx = ((i - 1) % #targets) + 1
				pelletsOn[idx] = (pelletsOn[idx] or 0) + 1
			end
		end
		for idx, count in pelletsOn do
			local c = targets[idx]
			local damage = baseDamage * falloffMult(c.dist) * count
			local isCrit = math.random() < buffOf(ps, "critchance")
			if isCrit then
				damage *= (1 + GameConfig.CritBaseBonus + buffOf(ps, "critdamage")) -- Crit buffs
			end
			ZombieService.NoteHit(c.record, origin) -- so a kill launches the ragdoll away from the shooter
			local killed = ZombieService.ApplyDamage(c.record, damage)
			hitEvent:Fire(player, c.record.model, false, weaponId, damage)
			if killed then
				killEvent:Fire(player, c.record.model, false, weaponId)
			else
				ZombieService.Hit(c.record, origin, eff.knockback) -- knockback + white flash
				-- Ability status effects ride on live hits (a corpse can't be pinned or chilled).
				if weapon.chill then
					ZombieService.Chill(c.record, weapon.chill, weapon.shatter)
				end
				if weapon.pin then
					ZombieService.Pin(c.record, weapon.pin.secs)
				end
			end
			-- Scatter the VISUAL impact around the torso (damage above is unchanged); one point drives both the
			-- tracer endpoint and the damage-number pop so they stay together.
			local hitPos = visualHitPos(c.root, weaponId)
			-- NEW 7th arg: special/rare kill → the client's loot-coin burst goes bigger.
			Remotes.Get("HitConfirmed"):FireClient(player, hitPos, false, true, killed, math.floor(damage + 0.5), isCrit,
				killed and (c.record.model:GetAttribute("IsSpecial") == true) or false)
			-- A tracer per zombie hit, carrying how many pellets landed there (the client fans that many bolts).
			Remotes.Get("ShotFired"):FireAllClients(player.UserId, origin, hitPos, weaponId, count)
		end
	else
		-- Miss: fan all the pellets straight ahead.
		Remotes.Get("ShotFired"):FireAllClients(player.UserId, origin, endpoint, weaponId, pellets)
	end

	-- AoE weapons (Rocket / Plasma): blast at the impact point (a hit target, else where the shot lands).
	if weapon.aoe then
		local center = (#targets > 0) and targets[1].root.Position or endpoint
		-- NEW: the rocket is a VISIBLE projectile on clients (CombatFeedbackController.spawnRocket flies it
		-- at AnimationConfig speed) — hold the detonation (splash damage + boom + sound) for the flight
		-- time so the explosion happens when and where the rocket lands, not at the muzzle click.
		local pCfg = AnimationConfig.Projectile.PerWeapon[weaponId]
		local flightSpeed = (weaponId == "rocket") and pCfg and pCfg.Speed or nil
		if flightSpeed and flightSpeed > 0 then
			local flight = math.min((center - origin).Magnitude / flightSpeed, 2)
			task.delay(flight, function()
				if player.Parent then -- shooter may have left mid-flight
					applyAoE(player, weaponId, center, weapon.aoe)
				end
			end)
		else
			applyAoE(player, weaponId, center, weapon.aoe)
		end
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
	local prev = ps.equippedWeapon
	ps.equippedWeapon = weaponId
	-- Keep the 2-slot hotbar honest: equipping a gun from deeper in the owned list (the GUNS panel)
	-- swaps it into the hotbar slot the previous gun occupied.
	local newIdx = table.find(ps.ownedWeapons, weaponId)
	if newIdx and newIdx > 2 then
		local slot = table.find(ps.ownedWeapons, prev)
		if slot and slot <= 2 then
			ps.ownedWeapons[newIdx], ps.ownedWeapons[slot] = ps.ownedWeapons[slot], ps.ownedWeapons[newIdx]
		end
	end
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

	-- Client fires LoadoutChanged (no args) to REQUEST a re-send — the spawn-time push can beat the
	-- client's controllers loading (they'd show only slot 1 until the next equip otherwise).
	Remotes.Get("LoadoutChanged").OnServerEvent:Connect(function(player)
		if not SecurityService.Allow(player, "LoadoutResend") then
			return
		end
		local ps = MatchService.GetPlayerState(player)
		if ps then
			fireLoadout(player, ps)
		end
	end)

	print("[CombatService] started (server-authoritative fire)")
end

return CombatService
