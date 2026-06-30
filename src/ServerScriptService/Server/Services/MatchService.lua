--!nonstrict
-- MatchService.lua — match lifecycle + wave manager (Zombie Rush style). **THE core service.**
--
-- Endless waves: Lobby -> Starting -> Playing (wave 1) -> [spawn escalating zombies, clear, short break,
-- next wave] forever. Death is FORGIVING — you respawn after a short delay and keep your cash/weapons/
-- upgrades; there is no team-wipe game over. The match idles back to Lobby only when everyone leaves.
--
-- Owns the ephemeral per-match state (cash, owned weapons, ammo, upgrades) keyed by userId.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local ZombieConfig = require(Config.ZombieConfig)
local Remotes = require(Modules.Remotes)

-- Required lazily in Start() to break the cycle (Match -> Zombie -> PlayerState -> Match).
local ZombieService

local MatchService = {}

-- ===== TUNABLES =====
local RESPAWN_DELAY = 4   -- seconds before a dead player respawns

-- ===== EPHEMERAL MATCH STATE =====
local state = {
	phase = "Lobby",       -- Lobby | Starting | Playing | RoundBreak
	round = 0,             -- the current wave
	zombiesRemaining = 0,
	zombiesAlive = 0,
	players = {},          -- [userId] = PlayerMatchState
	startedAt = 0,
}
MatchService.State = state

local matchRunning = false
local tryStartMatch  -- forward declaration

-- ===== INTERNAL =====
local function setPhase(phase: string)
	state.phase = phase
	Remotes.Get("MatchStateChanged"):FireAllClients(phase, state.round)
	print(("[MatchService] phase -> %s (wave %d)"):format(phase, state.round))
end

local function makePlayerState(player: Player)
	local pistol = WeaponConfig.pistol
	return {
		userId = player.UserId,
		points = GameConfig.StartingPoints,      -- "cash"
		ownedWeapons = { "pistol" },
		equippedWeapon = "pistol",
		ammo = { pistol = { mag = pistol.magSize, reserve = pistol.reserveAmmo } },
		upgrades = {},                            -- [weaponId] = upgrade level (shop)
		perks = {},                               -- (unused now; kept for the effect plumbing)
		packAPunched = {},                        -- (unused now)
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

-- (Re)spawn a player at a PlayerSpawn and arm the respawn-on-death loop. Cash/weapons/upgrades persist.
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

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Once(function()
			local p = state.players[player.UserId]
			if p then
				p.isDead = true
			end
			task.delay(RESPAWN_DELAY, function()
				if player.Parent then
					spawnCharacter(player)
				end
			end)
		end)
	end
end

-- Zombies owed this wave (CLAUDE.md §8).
local function computeCount(round: number, playerCount: number): number
	local c = GameConfig.BaseZombiesPerRound
		* (GameConfig.RoundZombieGrowth ^ (round - 1))
		* (1 + (math.max(1, playerCount) - 1) * GameConfig.PlayerCountScale)
	return math.max(1, math.floor(c))
end

local function noPlayers(): boolean
	return #Players:GetPlayers() == 0
end

-- ===== THE MATCH (endless) =====
local function runMatch()
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

	while not noPlayers() do
		local count = computeCount(state.round, #Players:GetPlayers())
		state.zombiesRemaining = count
		ZombieService.BeginRound(state.round, count)

		-- Every BossInterval waves (10, 20, ...): one boss joins the wave. It counts toward the clear, so
		-- the wave can't end until the boss is dead.
		if state.round % ZombieConfig.BossInterval == 0 then
			ZombieService.SpawnBoss(state.round)
		end

		while not ZombieService.IsRoundCleared() do
			if noPlayers() then
				break
			end
			state.zombiesAlive = ZombieService.GetAliveCount()
			state.zombiesRemaining = ZombieService.GetRemaining()
			task.wait(0.3)
		end
		if noPlayers() then
			break
		end

		setPhase("RoundBreak")
		task.wait(GameConfig.RoundBreakSeconds)
		state.round += 1
		Remotes.Get("RoundChanged"):FireAllClients(state.round)
		setPhase("Playing")
	end

	-- Everyone left: clear the field and idle back to Lobby until someone joins.
	ZombieService.ClearAll()
	state.round = 0
	state.zombiesAlive = 0
	state.zombiesRemaining = 0
	matchRunning = false
	setPhase("Lobby")
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

function MatchService.AdvanceRound()
	state.round += 1
	Remotes.Get("RoundChanged"):FireAllClients(state.round)
	Remotes.Get("MatchStateChanged"):FireAllClients(state.phase, state.round)
end

function MatchService.SetPhase(phase: string)
	setPhase(phase)
end

-- ===== LIFECYCLE =====
function MatchService.Start()
	ZombieService = require(script.Parent.ZombieService)
	Players.CharacterAutoLoads = false -- manual respawn control

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
	print("[MatchService] started (endless waves)")
end

return MatchService
