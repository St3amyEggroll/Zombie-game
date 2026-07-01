--!nonstrict
-- MatchService.lua — wave manager (Zombie Rush) + the GAME-place side of the two-place lobby. **THE core
-- service.** Runs in the GAME place (and Studio); the lobby place never starts it (see init.server.lua).
--
-- TWO-PLACE FLOW (published game): a fresh joiner lands here (this is the start place) with NO character →
-- the server teleports them to the LOBBY place. Press PLAY there → they teleport BACK here flagged to start
-- a run, and drop into the shared, drop-in co-op endless run (wave N → clear → short break → N+1 …). On
-- death the run is banked (best wave, lobby money, matches played via DataService — DataStores are shared
-- across both places) and they're teleported back to the lobby with a run summary.
--
-- STUDIO: TeleportService doesn't work in Studio, so we skip the routing and just drop you straight into a
-- run (and restart a fresh one a few seconds after death) so the whole loop stays testable solo.
--
-- Two currencies (CLAUDE.md §6): in-wave CASH (ephemeral ps.points, resets every run, spent at the shop)
-- and LOBBY MONEY (persistent, banked at run-end) — DataService owns the persistent side.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local ZombieConfig = require(Config.ZombieConfig)
local Places = require(Config.Places)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)

-- Required lazily in Start() to break the cycle (Match -> Zombie -> PlayerState -> Match).
local ZombieService

local MatchService = {}

-- ===== TUNABLES =====
local TELEPORT_RETRIES     = 4   -- attempts per teleport before giving up
local STUDIO_RESTART_DELAY = 3   -- Studio only: seconds after death before a fresh run auto-starts
-- (Lobby "Coins" are earned LIVE in ProgressionService — GameConfig.LobbyMoneyPerKill/PerWave — not here.)

-- Teleports only work in a published, running game — never in Studio. Published: route through the lobby
-- place. Studio: skip teleports and just run the game in-place so it's testable solo.
local LIVE = not RunService:IsStudio()

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

local function safeTeleport(placeId: number, player: Player, options: TeleportOptions?): boolean
	for attempt = 1, TELEPORT_RETRIES do
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(placeId, { player }, options)
		end)
		if ok then
			return true
		end
		warn(("[MatchService] teleport failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(err)))
		task.wait(attempt)
	end
	return false
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
		inMatch = false,                          -- false = lobby/menu; true = in the run
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
		lobbyEarned = 0,                          -- persistent "Coins" earned THIS run (for the end screen)
		-- In-run buff draft (BuffService) — all per-run, reset every run:
		runXP = 0,
		runLevel = 1,
		draftsOwed = 0,
		pendingDraft = nil,
		buffs = { damage = 0, attackspeed = 0, walkspeed = 0, range = 0, critchance = 0, critdamage = 0, luck = 0 },
	}
end

-- Reset a player's PER-RUN ephemeral state (the moment a run begins). Owned weapons persist; in-wave cash,
-- upgrades (tiers), kills and ammo all reset so every run starts from the base weapon again.
local function resetRunState(player: Player, ps)
	ps.points = GameConfig.StartingPoints
	ps.upgrades = {}
	ps.kills = 0
	ps.specialKills = 0
	ps.revives = 0
	ps.lobbyEarned = 0
	ps.runXP = 0
	ps.runLevel = 1
	ps.draftsOwed = 0
	ps.pendingDraft = nil
	ps.buffs = { damage = 0, attackspeed = 0, walkspeed = 0, range = 0, critchance = 0, critdamage = 0, luck = 0 }
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

-- Forward declarations (mutual references between the run helpers below).
local bankRun, spawnCharacter, runMatch, startMatchIfNeeded, startRunFor

-- How many players are currently IN the run (vs sitting in the lobby/menu).
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
	-- Coins were already granted live (ProgressionService); here we just record best wave + match count and
	-- report what this run earned. Save makes sure it all persists.
	DataService.UpdateBestWave(player, wave)
	DataService.IncrementStat(player, "matchesPlayed", 1)
	DataService.Save(player)
	return { wave = wave, kills = ps.kills, money = ps.lobbyEarned or 0 }
end

-- Send a player back to the lobby PLACE (published only): blocking-save so the bank lands first, then
-- teleport carrying the run summary for the lobby menu to show.
local function teleportToLobby(player: Player, summary)
	DataService.SaveNow(player) -- make sure the bank is written before we leave this server
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ summary = summary })
	safeTeleport(Places.Lobby, player, options)
end

-- Spawn a player into the arena and arm the death->lobby handoff. resetRunState already reset their cash/
-- upgrades/ammo. Death ENDS the run (banks, returns to the lobby) — there is no respawn-in-place.
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
				return -- already left the run (e.g. disconnected / teleporting)
			end
			p.isDead = true
			p.inMatch = false
			local summary = bankRun(player, p)
			if LIVE then
				teleportToLobby(player, summary) -- published: back to the lobby place
			else
				-- Studio: no teleport — restart a fresh run shortly so you can keep testing.
				task.delay(STUDIO_RESTART_DELAY, function()
					if player.Parent then
						startRunFor(player)
					end
				end)
			end
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

	-- Last player died / left: clear the field and idle back to Lobby until someone starts a run again.
	ZombieService.ClearAll()
	state.round = 0
	state.zombiesAlive = 0
	state.zombiesRemaining = 0
	matchRunning = false
	setPhase("Lobby")
end

-- Kick off the shared run if it isn't already going (first player into the run starts it).
startMatchIfNeeded = function()
	if matchRunning or not anyInMatch() then
		return
	end
	matchRunning = true
	task.spawn(runMatch)
end

-- Put a player into the run: reset their per-run state, spawn them, and start the run loop if needed.
startRunFor = function(player: Player)
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

-- Published game place: decide what to do with a player who is on this server. If they arrived from the
-- lobby flagged to play, start their run; otherwise they joined the start place fresh → send them to the
-- lobby. (Studio never calls this — it uses the in-place menu.)
local function handleArrival(player: Player)
	local startRun = false
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if ok and typeof(joinData) == "table" and typeof(joinData.TeleportData) == "table" then
		startRun = joinData.TeleportData.startRun == true
	end
	if startRun then
		startRunFor(player)
	else
		local options = Instance.new("TeleportOptions")
		if not safeTeleport(Places.Lobby, player, options) then
			startRunFor(player) -- teleport unavailable: don't strand them, just drop them into a run
		end
	end
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

-- Iterate only players currently IN the run (lobby/menu players are skipped).
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
	Players.CharacterAutoLoads = false -- characters spawn only when a run starts

	local function onJoin(player: Player)
		state.players[player.UserId] = makePlayerState(player)
		Remotes.Get("MatchStateChanged"):FireClient(player, state.phase, state.round)
		if LIVE then
			handleArrival(player) -- published: route to the lobby, or start a run if they came to play
		else
			startRunFor(player) -- Studio: drop straight into a run for testing
		end
	end

	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onJoin, player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		state.players[player.UserId] = nil
	end)

	print(("[MatchService] started (%s)"):format(LIVE and "game place, teleport flow" or "studio, direct run"))
end

return MatchService
