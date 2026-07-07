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
	-- (The lobby is a SEPARATE place — lobby-src/ — with its own remotes; pressing PLAY there teleports here.)

	-- ZombieService
	BossSpawned       = "RemoteEvent",     -- S->C: (name, maxHealth) — boss entrance + show health bar
	BossHealth        = "RemoteEvent",     -- S->C: (health, maxHealth) — update the boss bar
	BossDefeated      = "RemoteEvent",     -- S->C: hide the bar + "boss defeated" banner
	EnemyIncoming     = "RemoteEvent",     -- S->C: (typeName) — a NEW enemy type just spawned for the first time
	StartCountdown    = "RemoteEvent",     -- S->C: (seconds) — pre-run countdown while the party loads in (0 = clear)

	-- CombatService (THE exploit surface — server validates everything)
	FireWeapon        = "RemoteEvent",     -- C->S: intent (weaponId, origin, direction)
	HitConfirmed      = "RemoteEvent",     -- S->C: (position, isHeadshot, hitHumanoid, killed, damage) hit juice
	ShotFired         = "RemoteEvent",     -- S->C broadcast: (shooterUserId, origin, endpoint, weaponId) for tracers
	EquipWeapon       = "RemoteEvent",     -- C->S: (weaponId) request equip
	LoadoutChanged    = "RemoteEvent",     -- S->C: (ownedWeapons, equippedWeaponId)

	-- BuffService (in-run level-up buff draft)
	-- (Run-XP buff draft REMOVED — potions are the only in-run power-up now.)
	BuyGun            = "RemoteEvent",     -- C->S: ({weaponId}) buy a gun MID-RUN with Coins (same prices as the lobby)

	-- PointsService
	PointsChanged     = "RemoteEvent",     -- S->C: (points)
	KillStreak        = "RemoteEvent",     -- S->C: (streak, multiplier) — chain-kill flair + cash bonus
	FlawlessWave      = "RemoteEvent",     -- S->C all: (streak, mult) — wave cleared with NOBODY downed

	-- TrapService (buyable map hazards)
	TrapActivated     = "RemoteEvent",     -- S->C: (trapPart, trapType, duration) — turn trap VFX on
	TrapDeactivated   = "RemoteEvent",     -- S->C: (trapPart) — turn trap VFX off

	-- SoundFXService (all playback is client-side; the server only broadcasts named events)
	SoundEvent        = "RemoteEvent",     -- S->C: (name, position?) — play a named SoundConfig sound
	SetSoundSettings  = "RemoteEvent",     -- C->S: ({master, music, sfx} 0..1) — persist the volume sliders

	-- PlayerStateService
	HealthChanged     = "RemoteEvent",     -- S->C: (health, maxHealth)
	DamageTaken       = "RemoteEvent",     -- S->C: (amount, sourcePosition) — drives directional hurt UI
	Interact          = "RemoteEvent",     -- C->S: generic interact intent
	Sprint            = "RemoteEvent",     -- NEW (Phase 1): C->S: (wantSprint: boolean)

	-- GameInventoryService (in-game VIEW of the lobby inventory + potion use + wave case drops)
	InvSnapshot       = "RemoteEvent",     -- S->C: (snapshot) equipped weapons + cases + potions; C->S: request one
	ConsumePotion     = "RemoteEvent",     -- C->S: (potionId) drink a potion (timed buff; one active per TYPE)
	PotionBuffsChanged = "RemoteEvent",    -- S->C: ({ {id, type, rarity, pct, remaining} }) your ACTIVE potion buffs
	PotionDropped     = "RemoteEvent",     -- S->C: (potionId) an elite zombie dropped a potion (toast)
	CaseDropped       = "RemoteEvent",     -- S->C: (rarity) you collected a wave-clear case (toast)

	-- (In-run gun upgrades were REMOVED — guns now level up persistently in the LOBBY via case copies;
	-- the level rides in on data.gunLevels and GunLevelConfig turns it into stats.)

	-- Down / Revive (co-op: at 0 HP with teammates up you go DOWNED instead of dying; they revive you)
	Revive            = "RemoteEvent",     -- C->S: (targetUserId, holding: boolean) start/stop a revive hold
	ReviveProgress    = "RemoteEvent",     -- S->C: (targetUserId, progress 0..1) — drives the revive bar
	DownedChanged     = "RemoteEvent",     -- S->C broadcast: (userId, isDowned, bleedoutEndsAt)
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
