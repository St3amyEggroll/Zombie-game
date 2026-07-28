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
local EventService

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
	map = nil,             -- which world this run is (e.g. "forest") — the ONLY difficulty knob now
	extractMult = 1,       -- the CASH OUT payout multiplier; +MultPerStage per declined extraction window
	zombiesRemaining = 0,
	zombiesAlive = 0,
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

-- Zombies owed this wave (CLAUDE.md §8) — scaled by player count. One curve for everyone now (the old
-- per-difficulty earlyBonus front-loading went with the difficulty system).
local function computeCount(round: number, playerCount: number): number
	local c = GameConfig.BaseZombiesPerRound
		* (GameConfig.RoundZombieGrowth ^ (round - 1))
		* (1 + (math.max(1, playerCount) - 1) * GameConfig.PlayerCountScale)
	-- Deep waves would otherwise owe thousands of zombies and never clear.
	return math.clamp(math.floor(c), 1, GameConfig.MaxZombiesPerWave or math.huge)
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

-- Spawn a player into the arena and arm the death->spectate handoff. resetRunState already reset their cash.
-- Death does NOT end the run — the player drops into SPECTATE; the run only ends when the whole team is dead.
spawnCharacter = function(player: Player)
	player:LoadCharacter()
	local char = player.Character or player.CharacterAdded:Wait()
	local root = char:WaitForChild("HumanoidRootPart", 5)

	-- FALL-THROUGH GUARD: fresh arrivals could drop through the map in the first second (the client
	-- hasn't streamed the ground in yet). Ask the engine to stream the spawn area, and hold the
	-- character anchored for a beat while the world settles under their feet.
	if root then
		root.Anchored = true
		task.spawn(function()
			pcall(function()
				player:RequestStreamAroundAsync(root.Position, 2)
			end)
			task.wait(1.25)
			if root.Parent then
				root.Anchored = false
			end
		end)
	end

	-- Cartoon BLACK OUTLINE on every player (matches the zombies' look).
	if not char:FindFirstChild("Outline") then
		local hl = Instance.new("Highlight")
		hl.Name = "Outline"
		hl.FillTransparency = 1
		hl.OutlineColor = Color3.new(0, 0, 0)
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Adornee = char
		hl.Parent = char
	end

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
			p.isDead = true -- stays inMatch so they count toward the wipe check + ride the run to the lobby
			Remotes.Get("DownedChanged"):FireAllClients(player.UserId, true, 0) -- → client SpectateController
			MatchService.CheckTeamWipe() -- last one standing just died? end the run for everyone
		end)
	end
end

-- ===== RUN END ===== a team wipe (or everyone leaving) pays the BASE Coins only — the extraction
-- multiplier is the reward for CASHING OUT alive (see extractPlayer). No victory: waves never end.
local wipeToken = 0 -- bumping this cancels any pending wipe-grace timer (revive bought / run already over)
local function endRun()
	wipeToken += 1
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			ps.inMatch = false
			local summary = bankRun(player, ps)
			if LIVE then
				teleportToLobby(player, summary) -- published: back to the lobby place
			else
				task.delay(STUDIO_RESTART_DELAY, function() -- Studio: restart a fresh run so you can keep testing
					if player.Parent then
						startRunFor(player)
					end
				end)
			end
		end
	end
end

-- CASH OUT: bank the run's Coins × the current multiplier (the bonus part is granted here — the base was
-- already earned live), count it as a WIN (overhead tag + leaderboard), and send them home. The run keeps
-- going for anyone who doubled down.
local function extractPlayer(player: Player, ps)
	if not ps.inMatch then
		return
	end
	ps.inMatch = false
	local bonus = math.floor((ps.lobbyEarned or 0) * (state.extractMult - 1))
	if bonus > 0 then
		DataService.AddMoney(player, bonus)
	end
	DataService.AddWin(player) -- extracting alive IS the win now
	local summary = bankRun(player, ps)
	summary.win = true
	summary.money = (summary.money or 0) + bonus
	local extractRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if extractRoot then
		Remotes.Get("WorldVFX"):FireAllClients("coins", { pos = extractRoot.Position }) -- the payoff sparkle
	end
	print(("[MatchService] %s CASHED OUT at wave %d (x%.1f, +%d bonus)"):format(player.Name, state.round, state.extractMult, bonus))
	if LIVE then
		task.spawn(teleportToLobby, player, summary)
	else
		task.delay(STUDIO_RESTART_DELAY, function()
			if player.Parent then
				startRunFor(player)
			end
		end)
	end
	MatchService.CheckTeamWipe() -- the stayers might all be dead spectators — don't strand them
end

-- If NOBODY in the run is still alive (everyone's dead/spectating), the run is over for everyone.
function MatchService.CheckTeamWipe()
	local anyInRun, anyAlive = false, false
	for _, player in Players:GetPlayers() do
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			anyInRun = true
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if not ps.isDead and hum and hum.Health > 0 then
				anyAlive = true
			end
		end
	end
	if anyInRun and not anyAlive then
		-- CHANGED: with a ROBUX REVIVE product set up, a full wipe doesn't end the run instantly — it
		-- HOLDS for ReviveGraceSeconds (clients show the countdown + the revive button) and only ends
		-- if nobody buys back in. Without a product id, the old instant wipe stands.
		local reviveId = tonumber(GameConfig.ReviveProductId) or 0
		if reviveId <= 0 then
			endRun() -- team wipe: bank + back to the lobby
			return
		end
		wipeToken += 1
		local myToken = wipeToken
		local secs = math.max(3, math.floor(tonumber(GameConfig.ReviveGraceSeconds) or 12))
		Remotes.Get("WipeCountdown"):FireAllClients(secs)
		task.delay(secs, function()
			if myToken ~= wipeToken then
				return -- a revive landed (or the run already ended) — this wipe is stale
			end
			for _, plr in Players:GetPlayers() do -- re-verify nobody bought back in
				local p2 = state.players[plr.UserId]
				if p2 and p2.inMatch and not p2.isDead then
					local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
					if hum and hum.Health > 0 then
						return
					end
				end
			end
			endRun() -- still a wipe: bank + back to the lobby
		end)
	end
end

-- NEW: ROBUX REVIVE (ProductService receipt lands here): a dead player buys straight back into the
-- live run — fresh character, any pending wipe countdown cancelled. Returns false when there's nothing
-- to revive (purchase landed after the run ended) so the caller can log it.
function MatchService.RobuxRevive(player: Player): boolean
	local ps = state.players[player.UserId]
	if not ps or not ps.inMatch or not ps.isDead then
		return false
	end
	wipeToken += 1 -- cancel the wipe-grace timer, if one is running
	Remotes.Get("WipeCountdown"):FireAllClients(0)
	ps.isDead = false
	Remotes.Get("DownedChanged"):FireAllClients(player.UserId, false, 0) -- client leaves the death screen
	spawnCharacter(player)
	print(("[MatchService] %s bought a ROBUX REVIVE — back in the run"):format(player.Name))
	return true
end

-- ===== THE RUN (endless, shared) =====
-- No victory wave anymore: the run goes until everyone extracts (cash out) or the team wipes.
runMatch = function()
	-- ONE difficulty: the world's own tuning row (GameConfig.Maps) on top of the WaveMult baseline.
	local world = GameConfig.Maps[state.map or GameConfig.DefaultMap] or GameConfig.Maps[GameConfig.DefaultMap]
	ZombieService.SetDifficulty({
		mult = GameConfig.WaveMult * (world.mult or 1),
		speedMult = world.speedMult or 1,
	})
	ZombieService.SetMap(state.map or GameConfig.DefaultMap) -- roster + how zombies emerge (grave vs water)

	state.extractMult = 1

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

	-- ===== WAVES + THE EVENT WHEEL (the loop — owner call, back from the continuous experiment) =====
	-- Kill the wave to clear it; every wave break the EVENT WHEEL visibly spins and lands on NEXT
	-- wave's modifier (calm / blood moon / fog / meteors — whole-wave events, EventService). Waves
	-- scale forever; a team wipe ends the run; Coins bank live.
	-- Wave 1 gets its spin right after the start countdown (a short beat before the first zombie).
	local pendingEvent = EventService.SpinForWave(state.round)
	task.wait(GameConfig.Events.SpinSeconds)
	while anyInMatch() do
		-- The roller's outcome runs for the WHOLE wave — started FIRST because some events resize or
		-- re-mix the wave (Purge triples the count, Bodyguards thins it, Bomb Squad biases the spawns).
		state.waveEvent = pendingEvent -- readable all wave (TitleService's event trophies key off it)
		EventService.BeginWaveEvent(pendingEvent, state.round)

		local count = math.max(1, math.floor(computeCount(state.round, inMatchCount()) * EventService.GetCountMult()))
		state.zombiesRemaining = count
		ZombieService.BeginRound(state.round, count)
		local waveTotal = count               -- this wave's owed count (denominator for the count bar)
		local lastRemaining = -1
		Remotes.Get("WaveProgress"):FireAllClients(count, waveTotal)

		-- A boss every BossEvery-th wave, cycling the roster forever. Boss HP scales × players.
		if GameConfig.BossEvery > 0 and state.round % GameConfig.BossEvery == 0 then
			local roster = GameConfig.BossRoster
			local bossId = roster[math.floor(state.round / GameConfig.BossEvery - 1) % #roster + 1]
			ZombieService.SpawnBoss(state.round, bossId, inMatchCount())
		end

		while not ZombieService.IsRoundCleared() do
			if not anyInMatch() then
				break
			end
			state.zombiesAlive = ZombieService.GetAliveCount()
			state.zombiesRemaining = ZombieService.GetRemaining()
			local left = ZombieService.GetLeft() -- remaining + alive → drops on every KILL, not just on spawn
			if left ~= lastRemaining then
				lastRemaining = left
				Remotes.Get("WaveProgress"):FireAllClients(left, waveTotal)
			end
			task.wait(0.1) -- tight poll so the break starts right when the last zombie dies
		end
		EventService.EndWaveEvent() -- wave over: blood moon lifts, fog burns off, meteors stop
		if not anyInMatch() then
			break
		end

		waveClearedEvent:Fire(state.round) -- GameInventoryService drops wave-clear cases off this

		-- THE BREAK (RoundBreakSeconds): the wheel spins NEXT wave's event a beat in, so the reveal
		-- lands mid-break and the dread has time to sink in before the wave starts.
		setPhase("RoundBreak")
		pendingEvent = EventService.SpinForWave(state.round + 1)
		task.wait(GameConfig.RoundBreakSeconds)
		if not anyInMatch() then
			break
		end
		state.round += 1
		Remotes.Get("RoundChanged"):FireAllClients(state.round)
		setPhase("Playing")
	end

	-- Run ended (everyone extracted/left, or the wipe banked them): clear the field and idle back to Lobby.
	EventService.StopAll()
	ZombieService.ClearAll()
	state.round = 0
	state.map = nil
	state.extractMult = 1
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
-- Server-side unlock re-validation. Teleport data is client-visible + tamperable, so NEVER trust the map
-- it claims — verify the arriving player actually unlocked it. Worlds gate by ACCOUNT LEVEL now (the old
-- "beat Nightmare to unlock the next world" chain went with the difficulty system).
local function indexOf(list, v)
	for i, x in list do
		if x == v then
			return i
		end
	end
	return nil
end
local function accountLevel(totalXP: number): number
	local ProgressionConfig = require(Config.ProgressionConfig)
	local level, remaining = 1, math.max(0, totalXP or 0)
	while level < (ProgressionConfig.MaxLevel or 100) do
		local need = math.floor(ProgressionConfig.BaseLevelXP * (ProgressionConfig.LevelGrowth ^ (level - 1)))
		if remaining < need then
			break
		end
		remaining -= need
		level += 1
	end
	return level
end
local function worldUnlocked(prof, world): boolean
	if not indexOf(GameConfig.Worlds, world) then
		return false
	end
	if GameConfig.AllWorldsOpen then
		return true -- every (known) map open for now — matches the lobby's ALL_WORLDS_OPEN
	end
	local needLevel = (GameConfig.WorldUnlockLevel or {})[world] or 0
	local xp = (typeof(prof) == "table" and tonumber(prof.xp)) or 0
	return accountLevel(xp) >= needLevel
end

local function handleArrival(player: Player)
	local startRun = false
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if ok and typeof(joinData) == "table" and typeof(joinData.TeleportData) == "table" then
		startRun = joinData.TeleportData.startRun == true
		-- The lobby sends the chosen map; the FIRST player to start the run sets it — but only after
		-- re-validating against their real unlocks (a tampered teleport payload can't unlock content).
		if startRun and not state.map and typeof(joinData.TeleportData.map) == "string" then
			local prof = DataService.WaitFor(player)
			local reqMap = joinData.TeleportData.map
			if not worldUnlocked(prof, reqMap) then
				reqMap = GameConfig.DefaultMap
			end
			state.map = reqMap
		end
		-- How many players the lobby teleported together — the pre-run countdown waits for all of them.
		if startRun and typeof(joinData.TeleportData.partySize) == "number" then
			state.expectedPlayers = math.max(state.expectedPlayers or 1, math.floor(joinData.TeleportData.partySize))
		end
	end
	if startRun then
		startRunFor(player)
	elseif game.PrivateServerId ~= "" then
		-- RESERVED server = the lobby teleported them here, even if the TeleportData got lost in transit
		-- (Roblox drops it sometimes — this was the "my friend never joined the run" bug: legit party
		-- members were being bounced back to the lobby). On a reserved game server, everyone plays.
		warn(("[MatchService] %s arrived on a reserved server without TeleportData — joining the run anyway"):format(player.Name))
		startRunFor(player)
	elseif state.map ~= nil or anyInMatch() then
		-- A run is already configured/underway on this server: treat the data-less arrival as a joiner.
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
	EventService = require(script.Parent.EventService)
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
		-- FIX: a disconnect must bank the run (so matchesPlayed/best wave count) AND re-check team-wipe —
		-- otherwise the LAST living player quitting strands the dead spectators and the wave loop spins
		-- forever. Mirror what LEAVE does, minus the teleport (they're already gone).
		local ps = state.players[player.UserId]
		if ps and ps.inMatch then
			ps.inMatch = false
			bankRun(player, ps)
		end
		state.players[player.UserId] = nil
		MatchService.CheckTeamWipe()
	end)

	-- CASH OUT (the extraction window's green button): only honored while a window is actually open
	-- (the RoundBreak right after an extraction wave) — a stray/forged fire outside one does nothing.
	Remotes.Get("ExtractChoice").OnServerEvent:Connect(function(player)
		local ex = GameConfig.Extraction
		local ps = state.players[player.UserId]
		if not ps or not ps.inMatch then
			return
		end
		if state.phase ~= "RoundBreak" or ex.Every <= 0 or state.round % ex.Every ~= 0 then
			return
		end
		extractPlayer(player, ps)
	end)

	-- LEAVE (the small HUD button beside the wave readout): bank THIS player's run and send them home.
	-- The run keeps going for everyone else; if they were the last one alive, the wipe check ends it.
	Remotes.Get("LeaveRun").OnServerEvent:Connect(function(player)
		local ps = state.players[player.UserId]
		if not ps or not ps.inMatch then
			return
		end
		ps.inMatch = false
		local summary = bankRun(player, ps)
		MatchService.CheckTeamWipe()
		if LIVE then
			task.spawn(teleportToLobby, player, summary)
		else
			print("[MatchService] LEAVE pressed (Studio: teleports disabled — restarting a run)")
			task.delay(1, function()
				if player.Parent then
					startRunFor(player)
				end
			end)
		end
	end)

	print(("[MatchService] started (%s)"):format(LIVE and "game place, teleport flow" or "studio, direct run"))
end

return MatchService
