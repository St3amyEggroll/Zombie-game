--!nonstrict
-- DataService.lua — persistent account data (DataStore-backed). THE only module that touches a player's
-- saved profile. Stores the META layer (CLAUDE.md §6): lobby money (persistent currency), XP/level, owned
-- weapons + the equipped loadout, unopened crates, best wave, lifetime stats, settings.
--
-- NOT stored here: in-wave cash (per-run, resets) and per-run weapon tier levels — those live in match state.
--
-- Robust by design: every DataStore call is pcall'd + retried; data is session-cached; saved on leave, on
-- shutdown (BindToClose), and on a periodic autosave; and if DataStores are unavailable (e.g. Studio with
-- "API Services" off, or a new save) it falls back to a fresh template so the GAME NEVER BREAKS — you just
-- don't get persistence until it's available.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Config = Shared:WaitForChild("Config")

local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)
local ProgressionConfig = require(Config.ProgressionConfig)

local DataService = {}

-- ===== TUNABLES =====
local STORE_NAME    = "PlayerData_v2" -- bump this string to wipe everyone's save (new schema epoch)
local SAVE_RETRIES  = 4               -- attempts per load/save before giving up
local AUTOSAVE_SECS = 120             -- periodic background save interval

-- ===== PROFILE TEMPLATE (meta-progression ONLY) =====
local TEMPLATE = {
	dataVersion  = 2,
	xp           = 0,
	level        = 1,
	lobbyMoney   = 0,                 -- persistent currency (spent in the lobby on crates/cosmetics)
	ownedWeapons = { "pistol" },      -- weapons you own (pistol = free starter; the rest come from cases)
	-- ===== LOBBY INVENTORY (managed by the LOBBY place; the game just preserves these on save) =====
	loadout      = { "pistol" },      -- the up-to-2 guns you carry into runs (picked in the lobby inventory)
	cases        = { common = 3 },    -- unopened cases by RARITY id -> count (3 free Common Cases to start)
	potions      = {},                -- owned potions by id -> count (usable in-run)
	gunLevels    = { pistol = 1 },    -- [weaponId] = persistent level 1..10 (Clash-Royale copies system;
	gunCopies    = {},                --   upgraded in the LOBBY — the game only READS these for combat stats)
	bestWave     = 0,
	completed    = {},                -- ["forest:easy"] = true — difficulties beaten (drives unlocks)
	stats        = { totalKills = 0, matchesPlayed = 0 },
	cosmetics    = {},
	settings     = { sfx = true, music = true, lowGfx = false },
}

local store = DataStoreService:GetDataStore(STORE_NAME)

-- userId -> { data, dirty, saving }
local sessions: { [number]: any } = {}

local readyEvent = Instance.new("BindableEvent")
DataService.Ready = readyEvent.Event -- fires (player) when their data is loaded

-- ===== HELPERS =====
local function keyFor(player: Player): string
	return "Player_" .. player.UserId
end

-- Fill any keys missing from a loaded save with template defaults (forward migration for new fields).
local function reconcile(data: any)
	for k, v in TEMPLATE do
		if data[k] == nil then
			data[k] = (typeof(v) == "table") and Util.DeepCopy(v) or v
		end
	end
	if typeof(data.stats) == "table" then
		for k, v in TEMPLATE.stats do
			if data.stats[k] == nil then
				data.stats[k] = v
			end
		end
	end
	-- Legacy potion ids (pre-tier era) migrate to the common tier.
	if typeof(data.potions) == "table" then
		for old, new in { damage = "damage_common", regen = "regen_common" } do
			local n = tonumber(data.potions[old])
			if n and n > 0 then
				data.potions[new] = (tonumber(data.potions[new]) or 0) + math.floor(n)
			end
			data.potions[old] = nil
		end
	end
	return data
end

local function getData(player: Player): any?
	local s = sessions[player.UserId]
	return s and s.data or nil
end

-- ===== LOAD / SAVE (pcall + retry) =====
local function loadAsync(player: Player): any
	for attempt = 1, SAVE_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(player))
		end)
		if ok then
			if typeof(result) == "table" then
				return reconcile(result)
			end
			return Util.DeepCopy(TEMPLATE) -- no save yet → fresh profile
		end
		if attempt == 1 then
			warn(("[DataService] load failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(result)))
		end
		task.wait(attempt) -- backoff
	end
	-- Gave up (likely API access off in Studio, or DataStore down): run in-memory so the game still works.
	warn(("[DataService] using a NON-persisted profile for %s (DataStore unavailable)"):format(player.Name))
	local data = Util.DeepCopy(TEMPLATE)
	data._noPersist = true
	return data
end

-- MERGE-style write: the GAME place only owns some fields; the LOBBY place owns the inventory fields
-- (selectedWeapon/cases/ownedWeapons). Writing the whole cached blob with SetAsync could clobber a lobby
-- write that landed while our save was still retrying (case dupes / lost weapons) — so we UpdateAsync
-- and only assign the fields this place actually mutates. Shared fields the game adds to during a run
-- (lobbyMoney, potions) are ours to write here because a player is only ever in ONE place at a time and
-- the lobby saves them before teleporting the player to us.
local GAME_OWNED_FIELDS = {
	"dataVersion", "xp", "level", "bestWave", "completed", "stats", "cosmetics", "settings",
	"lobbyMoney", "potions", "cases", -- cases: wave/boss case drops earned in-run must reach the lobby
}

local function saveAsync(player: Player): boolean
	local s = sessions[player.UserId]
	if not s or s.data._noPersist then
		return true
	end
	-- A save is already in flight: WAIT for it instead of silently doing nothing — callers like the
	-- before-teleport SaveNow depend on the data actually being written when this returns. Capped at 10s
	-- so a hung DataStore call can never indefinitely delay a death/victory teleport.
	local waited = 0
	while s.saving and waited < 10 do
		task.wait(0.1)
		waited += 0.1
	end
	if not s.dirty then
		return true -- the in-flight save (or an earlier one) already wrote everything current
	end
	s.saving = true
	s.dirty = false
	local data = s.data
	for attempt = 1, SAVE_RETRIES do
		local ok, err = pcall(function()
			store:UpdateAsync(keyFor(player), function(old)
				old = (typeof(old) == "table") and old or {}
				for _, field in GAME_OWNED_FIELDS do
					old[field] = data[field]
				end
				return old
			end)
		end)
		if ok then
			s.saving = false
			return true
		end
		warn(("[DataService] save failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(err)))
		task.wait(attempt)
	end
	s.saving = false
	s.dirty = true -- failed; try again next autosave/leave
	return false
end

local function markDirty(player: Player)
	local s = sessions[player.UserId]
	if s then
		s.dirty = true
	end
end

local function pushSnapshot(player: Player)
	local data = getData(player)
	if data then
		Remotes.Get("DataReady"):FireClient(player, data)
	end
end
DataService.PushSnapshot = pushSnapshot

local function onPlayerAdded(player: Player)
	local data = loadAsync(player)
	sessions[player.UserId] = { data = data, dirty = false, saving = false }
	pushSnapshot(player)
	readyEvent:Fire(player)
end

local function onPlayerRemoving(player: Player)
	saveAsync(player)
	sessions[player.UserId] = nil
end

-- ===== PUBLIC API =====
function DataService.Get(player: Player): any?
	return getData(player)
end

function DataService.IsReady(player: Player): boolean
	return sessions[player.UserId] ~= nil
end

function DataService.WaitFor(player: Player): any?
	while not sessions[player.UserId] and player.Parent do
		task.wait()
	end
	return getData(player)
end

-- Force a save now (e.g. at the end of a run). Safe to call often (no-ops if not dirty / not persisted).
function DataService.Save(player: Player)
	task.spawn(saveAsync, player)
end

-- BLOCKING save — runs in the caller's thread and returns when the data is actually written (it waits out
-- any in-flight save first, then flushes anything still dirty). Use right before teleporting a player to
-- another place so the destination never loads a stale profile. Returns false if every attempt failed.
function DataService.SaveNow(player: Player): boolean
	return saveAsync(player)
end

-- ----- XP / level -----
-- Returns (newLevel, levelsGained).
function DataService.AddXP(player: Player, amount: number): (number, number)
	local data = getData(player)
	if not data then
		return 1, 0
	end
	local oldLevel = data.level
	data.xp += math.max(0, math.floor(amount))
	local newLevel = ProgressionConfig.LevelForXP(data.xp)
	data.level = newLevel
	markDirty(player)
	return newLevel, math.max(0, newLevel - oldLevel)
end

-- ----- lobby money (persistent currency) -----
function DataService.GetMoney(player: Player): number
	local data = getData(player)
	return data and data.lobbyMoney or 0
end

function DataService.AddMoney(player: Player, amount: number)
	local data = getData(player)
	if data then
		data.lobbyMoney = math.max(0, data.lobbyMoney + math.floor(amount))
		markDirty(player)
	end
end

function DataService.TrySpendMoney(player: Player, amount: number): boolean
	local data = getData(player)
	if not data or amount < 0 or data.lobbyMoney < amount then
		return false
	end
	data.lobbyMoney -= amount
	markDirty(player)
	return true
end

-- ----- owned weapons -----
function DataService.OwnsWeapon(player: Player, weaponId: string): boolean
	local data = getData(player)
	return data ~= nil and Util.Contains(data.ownedWeapons, weaponId)
end

function DataService.AddWeapon(player: Player, weaponId: string)
	local data = getData(player)
	if data and not Util.Contains(data.ownedWeapons, weaponId) then
		table.insert(data.ownedWeapons, weaponId)
		markDirty(player)
	end
end

-- ----- cases (granted in-run every 10th wave; opened in the LOBBY) -----
function DataService.AddCase(player: Player, rarity: string, count: number?)
	local data = getData(player)
	if not data then
		return
	end
	if typeof(data.cases) ~= "table" then
		data.cases = {}
	end
	data.cases[rarity] = (data.cases[rarity] or 0) + (count or 1)
	markDirty(player)
end

-- ----- potions (dropped by elite zombies; usable in-game/lobby) -----
function DataService.GetPotions(player: Player): { [string]: number }
	local data = getData(player)
	return (data and typeof(data.potions) == "table") and data.potions or {}
end

function DataService.AddPotion(player: Player, potionId: string, count: number?)
	local data = getData(player)
	if not data then
		return
	end
	if typeof(data.potions) ~= "table" then
		data.potions = {}
	end
	data.potions[potionId] = (data.potions[potionId] or 0) + (count or 1)
	markDirty(player)
end

-- Consume one potion. Returns true if the player had one (and it was removed).
function DataService.TryConsumePotion(player: Player, potionId: string): boolean
	local data = getData(player)
	if not data or typeof(data.potions) ~= "table" then
		return false
	end
	local have = data.potions[potionId] or 0
	if have < 1 then
		return false
	end
	have -= 1
	if have <= 0 then
		data.potions[potionId] = nil
	else
		data.potions[potionId] = have
	end
	markDirty(player)
	return true
end

-- ----- stats / best wave / settings -----
function DataService.UpdateBestWave(player: Player, wave: number): boolean
	local data = getData(player)
	if not data then
		return false
	end
	if wave > (data.bestWave or 0) then
		data.bestWave = wave
		markDirty(player)
		return true
	end
	return false
end

-- Mark a (world, difficulty) as beaten — this is what unlocks the next difficulty / next world.
function DataService.MarkCompleted(player: Player, world: string, difficulty: string)
	local data = getData(player)
	if data then
		if typeof(data.completed) ~= "table" then
			data.completed = {}
		end
		data.completed[world .. ":" .. difficulty] = true
		markDirty(player)
	end
end

function DataService.IncrementStat(player: Player, statKey: string, amount: number)
	local data = getData(player)
	if data then
		data.stats[statKey] = (data.stats[statKey] or 0) + amount
		markDirty(player)
	end
end

function DataService.SetSetting(player: Player, key: string, value: any)
	local data = getData(player)
	if data then
		data.settings[key] = value
		markDirty(player)
	end
end

-- ===== LIFECYCLE =====
function DataService.Start()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Client can pull a fresh snapshot on demand.
	Remotes.Get("GetData").OnServerInvoke = function(player: Player)
		return getData(player)
	end

	-- Periodic autosave of dirty sessions.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECS)
			for _, player in Players:GetPlayers() do
				task.spawn(saveAsync, player)
			end
		end
	end)

	-- Save everyone on shutdown (don't return until saves attempt to finish).
	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		for _, player in Players:GetPlayers() do
			task.spawn(saveAsync, player)
		end
		task.wait(3)
	end)

	print(("[DataService] started (DataStore '%s', persistent profiles)"):format(STORE_NAME))
end

return DataService
