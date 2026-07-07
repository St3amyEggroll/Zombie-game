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
-- Two currencies (CLAUDE.md §6): in-wave CASH (ephemeral ps.points, resets every run, spent on traps)
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
local MapService = require(script.Parent.MapService)

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
	difficulty = nil,      -- "easy" | "medium" | "hard" | "nightmare" (set when the run starts)
	map = nil,             -- which world this run is (e.g. "forest")
	maxWave = 0,           -- the difficulty's final wave — clearing it wins the run
	zombiesRemaining = 0,
	zombiesAlive = 0,
	waveDowned = false,    -- did ANYONE go down during the current wave (breaks the flawless streak)
	flawlessStreak = 0,    -- consecutive waves cleared with nobody downed (drives the Coin multiplier)
	players = {},          -- [userId] = PlayerMatchState
	startedAt = 0,
}
MatchService.State = state

local matchRunning = false

-- Fired with (round) each time a wave is fully cleared (before the victory check / next-wave break).
local waveClearedEvent = Instance.new("BindableEvent")
MatchService.WaveCleared = waveClearedEvent.Event

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

-- The UP-TO-2 guns a player brings into a run = their lobby LOADOUT (data.loadout, slots 1-2).
-- Migration: old saves fall back to selectedWeapon, then the pistol. Read from the persisted profile
-- (DataService), which the lobby wrote before teleport. Debug: own every weapon for Studio testing.
local function runWeaponsFor(player: Player): { string }
	if GameConfig.DebugUnlockAllWeapons then
		local all = { "pistol" }
		for id in WeaponConfig do
			if id ~= "pistol" then
				table.insert(all, id)
			end
		end
		return all
	end
	-- Just teleported in: WAIT for the profile (DataService.WaitFor always resolves — on DataStore failure
	-- it falls back to a template — so this can't hang).
	local data = DataService.Get(player) or DataService.WaitFor(player)
	local list, seen = {}, {}
	if data and typeof(data.loadout) == "table" then
		for slot = 1, 2 do
			local id = data.loadout[slot]
			if typeof(id) == "string" and WeaponConfig[id] and not seen[id] then
				seen[id] = true
				table.insert(list, id)
			end
		end
	end
	if #list == 0 then
		-- Legacy migration: single selectedWeapon, else pistol.
		local sel = data and data.selectedWeapon
		list = { (typeof(sel) == "string" and WeaponConfig[sel]) and sel or "pistol" }
	end
	return list
end

local function makePlayerState(player: Player)
	local weapons = runWeaponsFor(player) -- the up-to-2 guns equipped in the lobby
	return {
		userId = player.UserId,
		inMatch = false,                          -- false = lobby/menu; true = in the run
		points = GameConfig.StartingPoints,       -- in-wave "cash" (ephemeral; reserved for traps)
		ownedWeapons = weapons,
		equippedWeapon = weapons[1] or "pistol",
		isDead = false,
		isDowned = false,                         -- at 0 HP with teammates up: crawling, waiting for a revive
		downedUntil = 0,                          -- os.clock() the bleedout ends
		health = GameConfig.PlayerMaxHealth,
		maxHealth = GameConfig.PlayerMaxHealth,
		kills = 0,
		specialKills = 0,
		lobbyEarned = 0,                          -- persistent "Coins" earned THIS run (for the end screen)
		-- In-run buff draft (BuffService) — all per-run, reset every run:
		runXP = 0,
		runLevel = 1,
		draftsOwed = 0,
		pendingDraft = nil,

		buffs = { damage = 0, attackspeed = 0, walkspeed = 0, range = 0, critchance = 0, critdamage = 0, luck = 0 },
	}
end

-- Reset a player's PER-RUN ephemeral state (the moment a run begins): in-wave cash, kills, XP, buffs and
-- potions all reset; the gun is re-read from the lobby selection.
local function resetRunState(player: Player, ps)
	ps.points = GameConfig.StartingPoints
	ps.kills = 0
	ps.specialKills = 0
	ps.lobbyEarned = 0
	ps.runXP = 0
	ps.runLevel = 1
	ps.draftsOwed = 0
	ps.pendingDraft = nil
	ps.buffs = { damage = 0, attackspeed = 0, walkspeed = 0, range = 0, critchance = 0, critdamage = 0, luck = 0 }
	ps.isDead = false
	ps.isDowned = false
	ps.downedUntil = 0
	ps.health = GameConfig.PlayerMaxHealth
	ps.maxHealth = GameConfig.PlayerMaxHealth
	ps.equippedWeapon = ps.ownedWeapons[1] or "pistol"
end

-- Zombies owed this wave (CLAUDE.md §8) — scaled by how many players are in the run.
local function computeCount(round: number, playerCount: number): number
	local c = GameConfig.BaseZombiesPerRound
		* (GameConfig.RoundZombieGrowth ^ (round - 1))
		* (1 + (math.max(1, playerCount) - 1) * GameConfig.PlayerCountScale)
	-- Deep Endless waves would otherwise owe thousands of zombies and never clear.
	return math.clamp(math.floor(c), 1, GameConfig.MaxZombiesPerWave or math.huge)
end

-- PlayerStateService calls this the moment anyone goes down — it breaks the wave's flawless streak.
function MatchService.MarkWaveDowned()
	state.waveDowned = true
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
	-- Coins were already granted live (ProgressionService); here we just record best wave + match count.
	-- No async save here: the LIVE path does a BLOCKING SaveNow right before the teleport (an async save
	-- here would just be an in-flight write that SaveNow has to wait out). Studio saves via autosave.
	DataService.UpdateBestWave(player, wave)
	DataService.IncrementStat(player, "matchesPlayed", 1)
	if not LIVE then
		DataService.Save(player)
	end
	return { wave = wave, kills = ps.kills, money = ps.lobbyEarned or 0 }
end

-- Send a player back to the lobby PLACE (published only): blocking-save so the bank lands first, then
-- teleport carrying the run summary for the lobby menu to show.
local function teleportToLobby(player: Player, summary)
	DataService.SaveNow(player) -- blocking (10s-capped): the bank is written before we leave this server
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ summary = summary })
	-- Up to 3 ROUNDS of safeTeleport (each itself retries with backoff) before giving up — a transient
	-- teleport outage must not quietly dump a dead player back into a run (that reads as "the lobby
	-- return is broken"). Only after everything fails do we restart a run so they're never soft-locked.
	for round = 1, 3 do
		if not player.Parent then
			return -- they left
		end
		if safeTeleport(Places.Lobby, player, options) then
			return
		end
		warn(("[MatchService] lobby teleport round %d failed for %s"):format(round, player.Name))
		task.wait(2)
	end
	warn(("[MatchService] ALL lobby teleports failed for %s — restarting a run as a last resort"):format(player.Name))
	if player.Parent then
		startRunFor(player)
	end
end

-- Spawn a player into the arena and arm the death->lobby handoff. resetRunState already reset their cash/
-- buffs. Death ENDS the run (banks, returns to the lobby) — there is no respawn-in-place.
spawnCharacter = function(player: Player)
	player:LoadCharacter()
	local char = player.Character or player.CharacterAdded:Wait()
	char:WaitForChild("HumanoidRootPart", 5)

	local ps = state.players[player.UserId]
	if ps then
		ps.isDead = false
	end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Once(function()
			local p = state.players[player.UserId]
			if not p or not p.inMatch then
				return -- already left the run (e.g. disconnected / teleporting)
			end
			p.isDead = true
			p.isDowned = false
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
			-- If everyone left is DOWNED, nobody can revive them — end the run for them too.
			MatchService.CheckTeamWipe()
		end)
	end
end

-- ===== DOWN / REVIVE SUPPORT ===== (the downed state itself lives in PlayerStateService)
-- "Up" = in the run, alive, and not downed — i.e. capable of reviving someone.
local function isUp(player: Player): boolean
	local ps = state.players[player.UserId]
	if not ps or not ps.inMatch or ps.isDowned then
		return false
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- Does `player` have ANY other up teammate in the run? (Decides downed-vs-dead at 0 HP.)
function MatchService.HasUpTeammate(player: Player): boolean
	for _, other in Players:GetPlayers() do
		if other ~= player and isUp(other) then
			return true
		end
	end
	return false
end

-- If NOBODY in the run is up (everyone downed/dead), nobody can revive anyone: force-kill the downed so
-- their normal death path (bank + teleport to lobby) runs. Called when someone goes down or dies for real.
function MatchService.CheckTeamWipe()
	local anyInRun = false
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			anyInRun = true
			if isUp(player) then
				return -- someone can still fight/revive; no wipe
			end
		end
	end
	if not anyInRun then
		return
	end
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			ps.isDowned = false
			local char = player.Character
			if char then
				char:SetAttribute("Downed", nil)
			end
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				hum.Health = 0 -- Died fires -> banks the run + teleports them to the lobby
			end
		end
	end
end

-- ===== THE RUN (endless, shared) =====
-- Run cleared its difficulty's final wave → VICTORY: bank everyone (+ a Coins bonus) and send them to the
-- lobby with a win summary.
local function winRun()
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			ps.inMatch = false
			DataService.AddMoney(player, GameConfig.VictoryBonusCoins)
			DataService.MarkCompleted(player, state.map or GameConfig.DefaultMap, state.difficulty) -- unlock the next difficulty/world
			local summary = bankRun(player, ps)
			summary.win = true
			summary.money = (summary.money or 0) + GameConfig.VictoryBonusCoins
			if LIVE then
				teleportToLobby(player, summary)
			else
				task.delay(STUDIO_RESTART_DELAY, function()
					if player.Parent then
						startRunFor(player)
					end
				end)
			end
		end
	end
end

runMatch = function()
	-- Difficulty (from the lobby, else the default) sets the final wave; clearing it wins the run.
	state.difficulty = state.difficulty or GameConfig.DefaultDifficulty
	local diff = GameConfig.Difficulties[state.difficulty] or GameConfig.Difficulties[GameConfig.DefaultDifficulty]
	state.maxWave = diff.maxWave
	ZombieService.SetDifficultyMult(diff.mult or 1) -- the mode's stat scale (HP + zombie damage)
	ZombieService.SetMap(state.map or GameConfig.DefaultMap) -- roster + how zombies emerge (grave vs water)

	state.waveDowned = false
	state.flawlessStreak = 0

	-- TEST: jump straight to GameConfig.DebugStartWave (0 = normal start at wave 1).
	state.round = (GameConfig.DebugStartWave and GameConfig.DebugStartWave > 0) and GameConfig.DebugStartWave or 1
	state.startedAt = os.clock()

	-- PRE-RUN COUNTDOWN: wait for the whole party to load in (up to StartCountdownSeconds); the moment
	-- everyone expected is present, the countdown snaps down to StartCountdownQuick. No zombies until zero.
	local expected = state.expectedPlayers or 1
	local deadline = os.clock() + GameConfig.StartCountdownSeconds
	local snapped = false
	local lastSent = -1
	while os.clock() < deadline do
		if not anyInMatch() then
			break
		end
		if not snapped and inMatchCount() >= expected then
			snapped = true
			deadline = math.min(deadline, os.clock() + GameConfig.StartCountdownQuick)
		end
		local secs = math.ceil(deadline - os.clock())
		if secs ~= lastSent then
			lastSent = secs
			Remotes.Get("StartCountdown"):FireAllClients(secs)
		end
		task.wait(0.2)
	end
	Remotes.Get("StartCountdown"):FireAllClients(0) -- clear the banner

	setPhase("Playing")
	Remotes.Get("RoundChanged"):FireAllClients(state.round)

	while anyInMatch() do
		local count = computeCount(state.round, inMatchCount())
		state.zombiesRemaining = count
		ZombieService.BeginRound(state.round, count)
		local waveTotal = count               -- this wave's owed count (denominator for the count bar)
		local lastRemaining = -1
		Remotes.Get("WaveProgress"):FireAllClients(count, waveTotal)

		-- Boss waves (10 = Boss, 20 = Lumberjack, 30 = Necromancer) — the boss counts toward the clear.
		-- Past the scheduled list (Endless depth), every 10th wave cycles the roster so the boss-kill
		-- case drops keep flowing forever. Boss HP scales × the number of players in the run.
		local bossId = ZombieConfig.BossWaves[state.round]
		if not bossId and state.round % 10 == 0 then
			local roster = { "boss", "lumberjack", "necromancer" }
			bossId = roster[math.floor(state.round / 10 - 1) % #roster + 1]
		end
		if bossId then
			ZombieService.SpawnBoss(state.round, bossId, inMatchCount())
		end

		while not ZombieService.IsRoundCleared() do
			if not anyInMatch() then
				break
			end
			state.zombiesAlive = ZombieService.GetAliveCount()
			state.zombiesRemaining = ZombieService.GetRemaining()
			if state.zombiesRemaining ~= lastRemaining then
				lastRemaining = state.zombiesRemaining
				Remotes.Get("WaveProgress"):FireAllClients(state.zombiesRemaining, waveTotal)
			end
			task.wait(0.1) -- tight poll so the break starts right when the last zombie dies
		end
		if not anyInMatch() then
			break
		end

		-- Flawless accounting: nobody downed all wave -> the streak (and the team's wave Coin payout
		-- multiplier in ProgressionService) climbs; any down resets it. Updated BEFORE WaveCleared fires
		-- so the payout uses this wave's streak.
		if state.waveDowned then
			state.flawlessStreak = 0
		else
			state.flawlessStreak += 1
			local mult = math.min(1 + state.flawlessStreak * GameConfig.FlawlessBonusPerWave, GameConfig.FlawlessMaxMult)
			Remotes.Get("FlawlessWave"):FireAllClients(state.flawlessStreak, mult)
		end
		state.waveDowned = false

		waveClearedEvent:Fire(state.round) -- GameInventoryService drops wave-clear cases off this

		-- Cleared the difficulty's FINAL wave → victory.
		if state.round >= state.maxWave then
			winRun()
			break
		end

		setPhase("RoundBreak")
		task.wait(GameConfig.RoundBreakSeconds)
		state.round += 1
		Remotes.Get("RoundChanged"):FireAllClients(state.round)
		setPhase("Playing")
	end

	-- Run ended (victory, or everyone left): clear the field and idle back to Lobby.
	ZombieService.ClearAll()
	state.round = 0
	state.difficulty = nil
	state.map = nil
	state.maxWave = 0
	state.expectedPlayers = nil
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
	ps.ownedWeapons = runWeaponsFor(player) -- re-read the lobby selection (it may have changed between runs)
	resetRunState(player, ps)
	MapService.Activate(state.map or GameConfig.DefaultMap) -- show the chosen world's map BEFORE the player spawns onto it
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
		-- The lobby sends the chosen map + difficulty; the first player to start the run sets them.
		if startRun and not state.difficulty and typeof(joinData.TeleportData.difficulty) == "string" then
			state.difficulty = joinData.TeleportData.difficulty
			if typeof(joinData.TeleportData.map) == "string" then
				state.map = joinData.TeleportData.map
			end
		end
		-- How many players the lobby teleported together — the pre-run countdown waits for all of them.
		if startRun and typeof(joinData.TeleportData.partySize) == "number" then
			state.expectedPlayers = math.max(state.expectedPlayers or 1, math.floor(joinData.TeleportData.partySize))
		end
	end
	if startRun then
		startRunFor(player)
	elseif game.PlaceId == Places.Lobby then
		-- SAFETY: this place is configured as the lobby but is running the GAME code. Never teleport a
		-- player to the place they're already on (that's the self-teleport loop). Just start their run.
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
