--!nonstrict
-- MatchService.lua — match lifecycle + round manager. **THE core service.**
--
-- Owns the ephemeral per-match state (CLAUDE.md §6) and runs the real round loop:
--   Lobby -> Starting -> Playing (round 1) -> [spawn escalating zombies, wait for clear,
--   RoundBreak, advance] looping -> on a full team wipe: GameOver -> reset -> Lobby.
--
-- Player respawn is manual (CharacterAutoLoads is off) so a death stays a death until the next match —
-- Phase 6 swaps that bare death for the down/revive system; the all-dead → GameOver hook is already here.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local Remotes = require(Modules.Remotes)

-- ZombieService is required lazily in Start() to break the require cycle
-- (Match -> Zombie -> PlayerState -> Match). Stored as an upvalue the round loop reads.
local ZombieService

local MatchService = {}

-- ===== EPHEMERAL MATCH STATE (server memory only; discarded at game over) =====
local state = {
	phase = "Lobby",        -- Lobby | Starting | Playing | RoundBreak | GameOver
	round = 0,
	zombiesRemaining = 0,
	zombiesAlive = 0,
	players = {},           -- [userId] = PlayerMatchState
	startedAt = 0,
}
MatchService.State = state

local matchRunning = false
local forceEnd = false
local tryStartMatch  -- forward declaration (runMatch calls it before it's defined below)

-- ===== INTERNAL =====
local function setPhase(phase: string)
	state.phase = phase
	Remotes.Get("MatchStateChanged"):FireAllClients(phase, state.round)
	print(("[MatchService] phase -> %s (round %d)"):format(phase, state.round))
end

local function makePlayerState(player: Player)
	local pistol = WeaponConfig.pistol
	return {
		userId = player.UserId,
		points = GameConfig.StartingPoints,
		ownedWeapons = { "pistol" },
		equippedWeapon = "pistol",
		ammo = { pistol = { mag = pistol.magSize, reserve = pistol.reserveAmmo } },
		perks = {},
		packAPunched = {},
		isDown = false,
		isDead = false,
		health = GameConfig.PlayerMaxHealth,
		maxHealth = GameConfig.PlayerMaxHealth,
		kills = 0,
		specialKills = 0,
		revives = 0,
	}
end

local function getPlayerSpawns(): { BasePart }
	local list = {}
	for _, inst in CollectionService:GetTagged("PlayerSpawn") do
		if inst:IsA("BasePart") then
			table.insert(list, inst)
		end
	end
	return list
end

-- (Re)spawn a player's character and place it at a PlayerSpawn. Resets their down/dead flags.
local function spawnCharacter(player: Player)
	player:LoadCharacter()
	local char = player.Character or player.CharacterAdded:Wait()
	char:WaitForChild("HumanoidRootPart", 5)
	local spawns = getPlayerSpawns()
	if #spawns > 0 and char.PrimaryPart then
		local sp = spawns[math.random(#spawns)]
		char:PivotTo(sp.CFrame * CFrame.new(0, 4, 0))
	end
	local ps = state.players[player.UserId]
	if ps then
		ps.isDead = false
		ps.isDown = false
	end
end

-- True only if there is at least one player and every one of them is dead.
local function allPlayersDead(): boolean
	local any = false
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps then
			any = true
			if not ps.isDead then
				return false
			end
		end
	end
	return any
end

-- Zombies owed this round (CLAUDE.md §8).
local function computeCount(round: number, playerCount: number): number
	local c = GameConfig.BaseZombiesPerRound
		* (GameConfig.RoundZombieGrowth ^ (round - 1))
		* (1 + (math.max(1, playerCount) - 1) * GameConfig.PlayerCountScale)
	return math.max(1, math.floor(c))
end

-- ===== THE MATCH =====
local function runMatch()
	forceEnd = false
	setPhase("Starting")

	for _, player in Players:GetPlayers() do
		task.spawn(spawnCharacter, player)
	end
	for _ = GameConfig.LobbyCountdown, 1, -1 do
		task.wait(1)
	end

	state.round = 1
	state.startedAt = os.clock()
	setPhase("Playing")
	Remotes.Get("RoundChanged"):FireAllClients(state.round)

	local wiped = false
	while true do
		local count = computeCount(state.round, #Players:GetPlayers())
		state.zombiesRemaining = count
		ZombieService.BeginRound(state.round, count)

		while not ZombieService.IsRoundCleared() do
			if forceEnd or allPlayersDead() then
				wiped = true
				break
			end
			state.zombiesAlive = ZombieService.GetAliveCount()
			state.zombiesRemaining = ZombieService.GetRemaining()
			task.wait(0.3)
		end
		if wiped then
			break
		end

		setPhase("RoundBreak")
		task.wait(GameConfig.RoundBreakSeconds)
		state.round += 1
		Remotes.Get("RoundChanged"):FireAllClients(state.round)
		setPhase("Playing")
	end

	-- Team wipe -> game over -> reset -> back to lobby.
	setPhase("GameOver")
	task.wait(GameConfig.GameOverHoldSeconds)
	ZombieService.ClearAll()
	state.round = 0
	state.zombiesAlive = 0
	state.zombiesRemaining = 0
	-- Rebuild each player's ephemeral state from scratch (CLAUDE.md §6: owned weapons, ammo, perks,
	-- Pack-a-Punch, points are all discarded at game over — you start the next run with a pistol).
	for _, player in Players:GetPlayers() do
		if state.players[player.UserId] then
			local fresh = makePlayerState(player)
			state.players[player.UserId] = fresh
			Remotes.Get("PointsChanged"):FireClient(player, fresh.points)
		end
	end
	matchRunning = false
	setPhase("Lobby")
	-- (Phase 8: ProgressionService awards XP / bestRound off the GameOver phase before this reset.)
	tryStartMatch()
end

tryStartMatch = function()
	if matchRunning or state.phase ~= "Lobby" then
		return
	end
	if #Players:GetPlayers() < GameConfig.MinPlayersToStart then
		return
	end
	matchRunning = true
	task.spawn(runMatch)
end

-- ===== PUBLIC API =====
function MatchService.GetState()
	return state
end

function MatchService.GetPhase(): string
	return state.phase
end

function MatchService.GetRound(): number
	return state.round
end

function MatchService.GetPlayerState(player: Player)
	return state.players[player.UserId]
end

function MatchService.ForEachPlayer(fn: (Player, any) -> ())
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps then
			fn(player, ps)
		end
	end
end

-- Advance to the next round manually (the loop does this itself; exposed for tooling/later phases).
function MatchService.AdvanceRound()
	state.round += 1
	Remotes.Get("RoundChanged"):FireAllClients(state.round)
	Remotes.Get("MatchStateChanged"):FireAllClients(state.phase, state.round)
end

function MatchService.SetPhase(phase: string)
	setPhase(phase)
end

-- Force the current match to end after the current round-wait tick (used by later phases / admin).
function MatchService.EndMatch()
	forceEnd = true
end

-- ===== LIFECYCLE =====
function MatchService.Start()
	ZombieService = require(script.Parent.ZombieService)

	-- Manual respawn control: a death stays a death until the next match.
	Players.CharacterAutoLoads = false

	for _, player in Players:GetPlayers() do
		state.players[player.UserId] = makePlayerState(player)
		task.spawn(spawnCharacter, player)
	end

	Players.PlayerAdded:Connect(function(player)
		state.players[player.UserId] = makePlayerState(player)
		Remotes.Get("MatchStateChanged"):FireClient(player, state.phase, state.round)
		spawnCharacter(player)
		tryStartMatch()
	end)

	Players.PlayerRemoving:Connect(function(player)
		state.players[player.UserId] = nil
	end)

	tryStartMatch()
	print("[MatchService] started (round manager live)")
end

return MatchService
