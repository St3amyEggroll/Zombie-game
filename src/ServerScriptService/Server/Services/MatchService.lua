--!nonstrict
-- MatchService.lua — match lifecycle + wave manager (Zombie Rush + LOBBY). **THE core service.**
--
-- MENU LOBBY + shared co-op run. Players sit in the LOBBY (a full-screen menu — they have NO character)
-- until they press PLAY. PLAY drops them into the shared, endless wave run (drop-in co-op):
--   Playing (wave N) -> clear the wave -> short break -> wave N+1 ... forever.
-- The wave counter is SHARED by everyone currently in the run.
--
-- Death ENDS your run (not forgiving): your results bank into your persistent profile (best wave, lobby
-- money, matches played via DataService) and you return to the lobby menu. Press PLAY for a fresh run.
-- The shared run keeps going while ANYONE is still alive in it; it idles back to Lobby only when the last
-- player dies or leaves.
--
-- Two currencies (CLAUDE.md §6): in-wave CASH (ephemeral `ps.points`, reset every run, spent at the shop)
-- and LOBBY MONEY (persistent, banked at run-end, spent in the lobby) — DataService owns the persistent side.
-- Owns the ephemeral per-run state (cash, owned weapons, ammo, upgrades) keyed by userId.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local ZombieConfig = require(Config.ZombieConfig)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)

-- Required lazily in Start() to break the cycle (Match -> Zombie -> PlayerState -> Match).
local ZombieService

local MatchService = {}

-- ===== TUNABLES =====
local LOBBY_MONEY_PER_WAVE = 25  -- persistent lobby money banked per wave reached on a run
local LOBBY_MONEY_PER_KILL = 1   -- persistent lobby money banked per kill on a run

-- ===== EPHEMERAL MATCH STATE =====
local state = {
	phase = "Lobby",       -- Lobby | Playing | RoundBreak
	round = 0,             -- the current SHARED wave
	zombiesRemaining = 0,
	zombiesAlive = 0,
	players = {},          -- [userId] = PlayerMatchState
	startedAt = 0,
}
MatchService.State = state

local matchRunning = false

-- ===== INTERNAL =====
local function setPhase(phase: string)
	state.phase = phase
	Remotes.Get("MatchStateChanged"):FireAllClients(phase, state.round)
	print(("[MatchService] phase -> %s (wave %d)"):format(phase, state.round))
end

local function makePlayerState(player: Player)
	local pistol = WeaponConfig.pistol
	-- TEST: own every weapon (GameConfig.DebugUnlockAllWeapons), pistol always in slot 1.
	local owned = { "pistol" }
	if GameConfig.DebugUnlockAllWeapons then
		for id in WeaponConfig do
			if id ~= "pistol" then
				table.insert(owned, id)
			end
		end
	end
	return {
		userId = player.UserId,
		inMatch = false,                          -- false = sitting in the lobby menu; true = in the run
		points = GameConfig.StartingPoints,       -- in-wave "cash" (ephemeral, reset every run)
		ownedWeapons = owned,
		equippedWeapon = "pistol",
		ammo = { pistol = { mag = pistol.magSize, reserve = pistol.reserveAmmo } },
		upgrades = {},                            -- [weaponId] = upgrade (tier) level — per-run, resets
		isDown = false,
		isDead = false,
		health = GameConfig.PlayerMaxHealth,
		maxHealth = GameConfig.PlayerMaxHealth,
		kills = 0,
		specialKills = 0,
		revives = 0,
	}
end

-- Reset a player's PER-RUN ephemeral state (called the moment they press PLAY). Owned weapons persist;
-- in-wave cash, upgrades (tiers), kills and ammo all reset so every run starts from the base weapon again.
local function resetRunState(player: Player, ps)
	ps.points = GameConfig.StartingPoints
	ps.upgrades = {}
	ps.kills = 0
	ps.specialKills = 0
	ps.revives = 0
	ps.isDead = false
	ps.isDown = false
	ps.health = GameConfig.PlayerMaxHealth
	ps.maxHealth = GameConfig.PlayerMaxHealth
	ps.equippedWeapon = ps.ownedWeapons[1] or "pistol"
	ps.ammo = {}
	for _, id in ps.ownedWeapons do
		local w = WeaponConfig[id]
		if w then
			ps.ammo[id] = { mag = w.magSize, reserve = w.reserveAmmo }
		end
	end
end

-- Zombies owed this wave (CLAUDE.md §8) — scaled by how many players are in the run.
local function computeCount(round: number, playerCount: number): number
	local c = GameConfig.BaseZombiesPerRound
		* (GameConfig.RoundZombieGrowth ^ (round - 1))
		* (1 + (math.max(1, playerCount) - 1) * GameConfig.PlayerCountScale)
	return math.max(1, math.floor(c))
end

-- Forward declarations (mutual references between the lobby/run helpers below).
local bankRun, enterLobby, spawnCharacter, runMatch, startMatchIfNeeded

-- How many players are currently IN the run (vs sitting in the lobby menu).
local function inMatchCount(): number
	local n = 0
	for _, ps in state.players do
		if ps.inMatch then
			n += 1
		end
	end
	return n
end

local function anyInMatch(): boolean
	return inMatchCount() > 0
end

-- Bank a finished run into the PERSISTENT profile: best wave, lobby money (per wave + per kill), match
-- count. Returns a small summary table for the lobby's end-of-run screen.
bankRun = function(player: Player, ps)
	local wave = state.round
	local money = wave * LOBBY_MONEY_PER_WAVE + ps.kills * LOBBY_MONEY_PER_KILL
	DataService.UpdateBestWave(player, wave)
	DataService.AddMoney(player, money)
	DataService.IncrementStat(player, "matchesPlayed", 1)
	DataService.Save(player)
	return { wave = wave, kills = ps.kills, money = money }
end

-- Send a player back to the lobby menu (no character). `summary` is the just-finished run's results, or nil
-- on a plain join. The client shows the lobby UI on EnterLobby.
enterLobby = function(player: Player, summary)
	local ps = state.players[player.UserId]
	if ps then
		ps.inMatch = false
	end
	Remotes.Get("EnterLobby"):FireClient(player, summary)
end

-- Spawn a player into the arena and arm the death->lobby handoff. resetRunState already reset their cash/
-- upgrades/ammo; death ENDS the run (banks results, returns to the lobby) — there is no respawn-in-place.
spawnCharacter = function(player: Player)
	player:LoadCharacter()
	local char = player.Character or player.CharacterAdded:Wait()
	char:WaitForChild("HumanoidRootPart", 5)

	local ps = state.players[player.UserId]
	if ps then
		ps.isDead = false
		ps.isDown = false
	end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Once(function()
			local p = state.players[player.UserId]
			if not p or not p.inMatch then
				return -- already left the run (e.g. disconnected)
			end
			p.isDead = true
			local summary = bankRun(player, p)
			enterLobby(player, summary)
		end)
	end
end

-- ===== THE RUN (endless, shared) =====
runMatch = function()
	-- TEST: jump straight to GameConfig.DebugStartWave (0 = normal start at wave 1).
	state.round = (GameConfig.DebugStartWave and GameConfig.DebugStartWave > 0) and GameConfig.DebugStartWave or 1
	state.startedAt = os.clock()
	setPhase("Playing")
	Remotes.Get("RoundChanged"):FireAllClients(state.round)

	while anyInMatch() do
		local count = computeCount(state.round, inMatchCount())
		state.zombiesRemaining = count
		ZombieService.BeginRound(state.round, count)

		-- Every BossInterval waves (10, 20, ...): one boss joins the wave (counts toward the clear).
		if state.round % ZombieConfig.BossInterval == 0 then
			ZombieService.SpawnBoss(state.round)
		end

		while not ZombieService.IsRoundCleared() do
			if not anyInMatch() then
				break
			end
			state.zombiesAlive = ZombieService.GetAliveCount()
			state.zombiesRemaining = ZombieService.GetRemaining()
			task.wait(0.3)
		end
		if not anyInMatch() then
			break
		end

		setPhase("RoundBreak")
		task.wait(GameConfig.RoundBreakSeconds)
		state.round += 1
		Remotes.Get("RoundChanged"):FireAllClients(state.round)
		setPhase("Playing")
	end

	-- Last player died / left: clear the field and idle back to Lobby until someone presses PLAY again.
	ZombieService.ClearAll()
	state.round = 0
	state.zombiesAlive = 0
	state.zombiesRemaining = 0
	matchRunning = false
	setPhase("Lobby")
end

-- Kick off the shared run if it isn't already going (first player to press PLAY starts it).
startMatchIfNeeded = function()
	if matchRunning or not anyInMatch() then
		return
	end
	matchRunning = true
	task.spawn(runMatch)
end

-- ===== PLAY (lobby -> run) =====
local function onRequestPlay(player: Player)
	local ps = state.players[player.UserId]
	if not ps then
		ps = makePlayerState(player)
		state.players[player.UserId] = ps
	end
	if ps.inMatch then
		return -- already in the run
	end
	ps.inMatch = true
	resetRunState(player, ps)
	spawnCharacter(player)
	startMatchIfNeeded()
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

-- Iterate only players currently IN the run (lobby players are skipped).
function MatchService.ForEachPlayer(fn: (Player, any) -> ())
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			fn(player, ps)
		end
	end
end

function MatchService.IsInMatch(player: Player): boolean
	local ps = state.players[player.UserId]
	return ps ~= nil and ps.inMatch == true
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
	Players.CharacterAutoLoads = false -- players spawn only when they press PLAY

	local function onJoin(player: Player)
		state.players[player.UserId] = makePlayerState(player)
		Remotes.Get("MatchStateChanged"):FireClient(player, state.phase, state.round)
		-- Land in the lobby menu (no character) until they press PLAY.
		enterLobby(player, nil)
	end

	for _, player in Players:GetPlayers() do
		onJoin(player)
	end

	Players.PlayerAdded:Connect(onJoin)

	Players.PlayerRemoving:Connect(function(player)
		state.players[player.UserId] = nil
		-- If that was the last player in the run, runMatch's anyInMatch() loop will wind it down.
	end)

	Remotes.Get("RequestPlay").OnServerEvent:Connect(onRequestPlay)

	print("[MatchService] started (menu lobby + shared run)")
end

return MatchService
