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
local LOADOUT_SLOTS = 6               -- max equipped weapons
local SAVE_RETRIES  = 4               -- attempts per load/save before giving up
local AUTOSAVE_SECS = 120             -- periodic background save interval

-- ===== PROFILE TEMPLATE (meta-progression ONLY) =====
local TEMPLATE = {
	dataVersion  = 2,
	xp           = 0,
	level        = 1,
	lobbyMoney   = 0,                 -- persistent currency (spent in the lobby on crates/cosmetics)
	ownedWeapons = { "pistol" },      -- weapons you own (pistol = free starter; the rest come from crates)
	loadout      = { "pistol" },      -- equipped, up to LOADOUT_SLOTS (slot 1 = your starter)
	crates       = {},                -- unopened crate rarities, e.g. { "common", "rare" }
	bestWave     = 0,
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

local function saveAsync(player: Player)
	local s = sessions[player.UserId]
	if not s or not s.dirty or s.saving or s.data._noPersist then
		return
	end
	s.saving = true
	s.dirty = false
	local data = s.data
	for attempt = 1, SAVE_RETRIES do
		local ok, err = pcall(function()
			store:SetAsync(keyFor(player), data)
		end)
		if ok then
			s.saving = false
			return
		end
		warn(("[DataService] save failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(err)))
		task.wait(attempt)
	end
	s.saving = false
	s.dirty = true -- failed; try again next autosave/leave
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

-- ----- owned weapons + loadout -----
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

function DataService.GetLoadout(player: Player): { string }
	local data = getData(player)
	return data and data.loadout or { "pistol" }
end

-- Set the equipped loadout (validated: <= LOADOUT_SLOTS, all owned). Returns true on success.
function DataService.SetLoadout(player: Player, list: { string }): boolean
	local data = getData(player)
	if not data or typeof(list) ~= "table" or #list == 0 or #list > LOADOUT_SLOTS then
		return false
	end
	for _, id in list do
		if not Util.Contains(data.ownedWeapons, id) then
			return false
		end
	end
	data.loadout = table.clone(list)
	markDirty(player)
	return true
end

-- ----- crates -----
function DataService.AddCrate(player: Player, rarity: string)
	local data = getData(player)
	if data then
		table.insert(data.crates, rarity)
		markDirty(player)
	end
end

function DataService.GetCrates(player: Player): { string }
	local data = getData(player)
	return data and data.crates or {}
end

-- Remove + return the crate at `index` (for opening it). Returns the rarity or nil.
function DataService.TakeCrate(player: Player, index: number): string?
	local data = getData(player)
	if not data or not data.crates[index] then
		return nil
	end
	local rarity = table.remove(data.crates, index)
	markDirty(player)
	return rarity
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
