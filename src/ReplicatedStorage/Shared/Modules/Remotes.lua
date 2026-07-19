--!strict
-- Remotes.lua — central remote registry. THE single source of truth for every networked endpoint.
-- Server calls Remotes.Init() once at boot to build them under ReplicatedStorage.Remotes.
-- Everyone (server or client) then uses Remotes.Get(name). Add a remote = add a line to DEFINITIONS.
--
-- Directions in the comments are documentation only: C->S = client sends intent, S->C = server tells clients.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

local FOLDER_NAME = "Remotes"

-- ===== DEFINITIONS ===== (name -> "RemoteEvent" | "RemoteFunction")
local DEFINITIONS: { [string]: string } = {
	-- DataService (meta-progression)
	DataReady         = "RemoteEvent",     -- S->C: your meta snapshot is loaded
	GetData           = "RemoteFunction",  -- C->S: fetch meta snapshot for UI
	ProgressChanged   = "RemoteEvent",     -- S->C: (xp, level, lobbyMoney) — live account progression updates
	LobbyMoneyChanged = "RemoteEvent",     -- S->C: (total) — persistent "Coins" total ticked up live in-game

	-- MatchService (lifecycle + round manager)
	MatchStateChanged = "RemoteEvent",     -- S->C: (phase, round)
	RoundChanged      = "RemoteEvent",     -- S->C: (round)
	LeaveRun          = "RemoteEvent",     -- C->S: the HUD's LEAVE button — bank my run + send me to the lobby
	-- (The lobby is a SEPARATE place — lobby-src/ — with its own remotes; pressing PLAY there teleports here.)

	-- ZombieService
	BossSpawned       = "RemoteEvent",     -- S->C: (name, maxHealth) — boss entrance + show health bar
	BossHealth        = "RemoteEvent",     -- S->C: (health, maxHealth) — update the boss bar
	BossDefeated      = "RemoteEvent",     -- S->C: hide the bar + "boss defeated" banner
	EnemyIncoming     = "RemoteEvent",     -- S->C: (typeName) — a NEW enemy type just spawned for the first time
	StartCountdown    = "RemoteEvent",     -- S->C: (seconds) — pre-run countdown while the party loads in (0 = clear)
	WaveProgress      = "RemoteEvent",     -- S->C: (remaining, total) — zombies left to kill this wave (drives the count bar)

	-- THE EVENT WHEEL (EventService) — every wave break the wheel spins next wave's modifier
	EventSpin         = "RemoteEvent",     -- S->C all: ({wave, outcome, seconds}) — animate the spin, land on outcome
	-- (Extraction remotes kept registered so old clients don't error mid-update; nothing fires them.)
	ExtractWindow     = "RemoteEvent",     -- (dead)
	ExtractChoice     = "RemoteEvent",     -- (dead)
	ExtractMult       = "RemoteEvent",     -- (dead)
	RunEvent          = "RemoteEvent",     -- S->C all: (kind, payload) — event announce + client-side FX (fog, ...)
	WorldVFX          = "RemoteEvent",     -- S->C all: (kind, {pos, ...}) — server announces, clients render particles
	                                       -- (Emit() doesn't replicate, so all world VFX are client-side bursts)

	-- CombatService (THE exploit surface — server validates everything)
	FireWeapon        = "RemoteEvent",     -- C->S: intent (weaponId, origin, direction)
	HitConfirmed      = "RemoteEvent",     -- S->C: (position, isHeadshot, hitHumanoid, killed, damage) hit juice
	ShotFired         = "RemoteEvent",     -- S->C broadcast: (shooterUserId, origin, endpoint, weaponId) for tracers
	EquipWeapon       = "RemoteEvent",     -- C->S: (weaponId) request equip
	LoadoutChanged    = "RemoteEvent",     -- S->C: (ownedWeapons, equippedWeaponId)

	-- (BuyGun REMOVED — there is NO shop in the game place. Guns come from the lobby: level unlocks
	-- + crates. The only in-game purchase surface is the coins pill's "+" → GET COINS card.)

	-- PointsService
	PointsChanged     = "RemoteEvent",     -- S->C: (points)

	-- TrapService (buyable map hazards)
	TrapActivated     = "RemoteEvent",     -- S->C: (trapPart, trapType, duration) — turn trap VFX on
	TrapDeactivated   = "RemoteEvent",     -- S->C: (trapPart) — turn trap VFX off

	-- SoundFXService (all playback is client-side; the server only broadcasts named events)
	SoundEvent        = "RemoteEvent",     -- S->C: (name, position?) — play a named SoundConfig sound
	SetSoundSettings  = "RemoteEvent",     -- C->S: ({master, music, sfx} 0..1) — persist the volume sliders
	SetShake          = "RemoteEvent",     -- C->S: (bool) — persist the camera-shake on/off preference

	-- PlayerStateService
	HealthChanged     = "RemoteEvent",     -- S->C: (health, maxHealth)
	DamageTaken       = "RemoteEvent",     -- S->C: (amount, sourcePosition) — drives directional hurt UI
	Interact          = "RemoteEvent",     -- C->S: generic interact intent
	Sprint            = "RemoteEvent",     -- NEW (Phase 1): C->S: (wantSprint: boolean)

	-- CodeService (the in-game CODES dock button — same codes + same once-per-player rule as the lobby)
	RedeemCode        = "RemoteEvent",     -- C->S: (code) redeem attempt; S->C: ({ok, msg}) result toast

	-- GameInventoryService (in-game VIEW of the lobby inventory + potion use + wave case drops)
	InvSnapshot       = "RemoteEvent",     -- S->C: (snapshot) equipped weapons + cases + potions; C->S: request one
	CaseDropped       = "RemoteEvent",     -- S->C: (rarity) you collected a wave-clear case (toast)

	-- (In-run gun upgrades were REMOVED — guns now level up persistently in the LOBBY via case copies;
	-- the level rides in on data.gunLevels and GunLevelConfig turns it into stats.)

	-- Death / spectate (dying drops you into spectate; the run ends only on a full team wipe — unless
	-- someone buys the ROBUX REVIVE during the wipe-grace window)
	DownedChanged     = "RemoteEvent",     -- S->C broadcast: (userId, isOut, 0) — a player died → spectating
	WipeCountdown     = "RemoteEvent",     -- S->C broadcast: (seconds) run ends in N unless someone revives; 0 = cancelled
}

local cache: { [string]: Instance } = {}

local function buildServer(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) :: Folder?
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	for name, class in DEFINITIONS do
		local existing = folder:FindFirstChild(name)
		if not existing then
			existing = Instance.new(class)
			existing.Name = name
			existing.Parent = folder
		end
		cache[name] = existing
	end
	return folder
end

local function getClient(name: string): Instance
	local existing = cache[name]
	if existing then
		return existing
	end
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	local inst = folder:WaitForChild(name)
	cache[name] = inst
	return inst
end

-- Server-only: build every remote up front. Idempotent.
function Remotes.Init()
	assert(RunService:IsServer(), "Remotes.Init() is server-only")
	buildServer()
end

-- Fetch a remote by name. Server returns instantly; client waits for replication.
function Remotes.Get(name: string): any
	assert(DEFINITIONS[name], "Unknown remote requested: " .. tostring(name))
	if RunService:IsServer() then
		if not cache[name] then
			buildServer()
		end
		return cache[name]
	else
		return getClient(name)
	end
end

-- Expose the definition list (read-only use) for tests / tooling.
function Remotes.List(): { [string]: string }
	return DEFINITIONS
end

return Remotes
