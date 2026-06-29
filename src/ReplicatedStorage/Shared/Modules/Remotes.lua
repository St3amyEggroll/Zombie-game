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

	-- MatchService (lifecycle + round manager)
	MatchStateChanged = "RemoteEvent",     -- S->C: (phase, round)
	RoundChanged      = "RemoteEvent",     -- S->C: (round)

	-- ZombieService
	ZombieSpawned     = "RemoteEvent",     -- S->C: special announce / spawn VFX
	ZombieDied        = "RemoteEvent",     -- S->C: kill juice

	-- CombatService (THE exploit surface — server validates everything)
	FireWeapon        = "RemoteEvent",     -- C->S: intent (origin, direction, weaponId)
	Reload            = "RemoteEvent",     -- C->S: intent
	HitConfirmed      = "RemoteEvent",     -- S->C: drives hit juice
	AmmoChanged       = "RemoteEvent",     -- S->C: (weaponId, mag, reserve)

	-- PointsService
	PointsChanged     = "RemoteEvent",     -- S->C: (points)

	-- PerkService
	BuyPerk           = "RemoteEvent",     -- C->S: intent
	PerksChanged      = "RemoteEvent",     -- S->C: (perks)

	-- BuyService
	BuyWall           = "RemoteEvent",     -- C->S
	BuyAmmo           = "RemoteEvent",     -- C->S
	OpenDoor          = "RemoteEvent",     -- C->S
	PackAPunch        = "RemoteEvent",     -- C->S
	RollMysteryBox    = "RemoteEvent",     -- C->S
	MysteryBoxResult  = "RemoteEvent",     -- S->C: drives the roller animation

	-- ReviveService (co-op heart)
	Revive            = "RemoteEvent",     -- C->S: start/stop a revive hold
	PlayerDowned      = "RemoteEvent",     -- S->C
	ReviveProgress    = "RemoteEvent",     -- S->C: (targetUserId, progress 0..1)
	PlayerRevived     = "RemoteEvent",     -- S->C

	-- PlayerStateService
	HealthChanged     = "RemoteEvent",     -- S->C: (health, maxHealth)
	Interact          = "RemoteEvent",     -- C->S: generic interact intent

	-- ProgressionService (between-run meta)
	MatchSummary      = "RemoteEvent",     -- S->C: end-of-match stats + XP/unlocks
	BuyUnlock         = "RemoteFunction",  -- C->S: spend tokens, returns success bool
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
