--!nonstrict
-- DataService.lua — meta-progression data layer.
--
-- ⚠ IN-MEMORY STUB (no persistence yet, by design). Data lives in server memory for the
-- session and is lost when the server shuts down. The PUBLIC API below is final, so when we
-- wire ProfileStore later we only swap the internals of load()/save()/PlayerRemoving — every
-- caller stays the same. This is the ONLY module that touches a player's meta Data table.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Config = Shared:WaitForChild("Config")

local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)
local ProgressionConfig = require(Config.ProgressionConfig)

local DataService = {}

-- ===== TEMPLATE (meta-progression ONLY — never match state, see CLAUDE.md §6) =====
local TEMPLATE = {
	dataVersion = 1,
	accountXP = 0,
	accountLevel = 1,
	unlockTokens = 0,                          -- spent to unlock weapons/perks for future runs
	unlockedWeapons = { "pistol", "smg" },     -- starting loadout pool
	unlockedPerks = { "jug", "revive" },
	cosmetics = {},
	stats = {
		bestRound = 0,
		totalKills = 0,
		totalRevives = 0,
		matchesPlayed = 0,
	},
	settings = { firstPerson = true, sfx = true, music = true, lowGfx = false },
}

-- userId -> data table (deep copy of TEMPLATE). Cleared on leave.
local store: { [number]: any } = {}
local ready: { [number]: boolean } = {}

-- Fires (player) once that player's data is available. Other services can wait on this.
local readyEvent = Instance.new("BindableEvent")
DataService.Ready = readyEvent.Event

-- ===== INTERNAL =====
local function load(player: Player)
	-- (ProfileStore swap-in point: StartSessionAsync + dataVersion migration would go here.)
	local data = Util.DeepCopy(TEMPLATE)
	store[player.UserId] = data
	ready[player.UserId] = true

	-- Push a snapshot so the client UI can render meta immediately.
	Remotes.Get("DataReady"):FireClient(player, data)
	readyEvent:Fire(player)
end

local function unload(player: Player)
	-- (ProfileStore swap-in point: :Save() / :EndSession() would go here.)
	store[player.UserId] = nil
	ready[player.UserId] = nil
end

-- ===== PUBLIC API =====

-- Immediate accessor (may be nil if data not loaded yet).
function DataService.Get(player: Player): any?
	return store[player.UserId]
end

function DataService.IsReady(player: Player): boolean
	return ready[player.UserId] == true
end

-- Yields until the player's data is ready (or they leave). Returns the data table or nil.
function DataService.WaitFor(player: Player): any?
	while not ready[player.UserId] and player.Parent do
		task.wait()
	end
	return store[player.UserId]
end

-- ----- mutators (the ONLY writers to Data; always mutate in place, never replace) -----

-- Add account XP and recompute level. Grants unlock tokens per level gained.
-- Returns (newLevel, levelsGained, tokensGranted).
function DataService.AddXP(player: Player, amount: number): (number, number, number)
	local data = store[player.UserId]
	if not data then
		return 1, 0, 0
	end
	local oldLevel = data.accountLevel
	data.accountXP += math.max(0, math.floor(amount))
	local newLevel = ProgressionConfig.LevelForXP(data.accountXP)
	data.accountLevel = newLevel
	local gained = math.max(0, newLevel - oldLevel)
	local tokens = gained * ProgressionConfig.TokensPerLevel
	if tokens > 0 then
		data.unlockTokens += tokens
	end
	return newLevel, gained, tokens
end

-- Try to spend unlock tokens. Returns true on success.
function DataService.SpendTokens(player: Player, amount: number): boolean
	local data = store[player.UserId]
	if not data or data.unlockTokens < amount then
		return false
	end
	data.unlockTokens -= amount
	return true
end

-- Has this player unlocked the given weapon/perk? kind = "weapon" | "perk".
function DataService.HasUnlock(player: Player, kind: string, id: string): boolean
	local data = store[player.UserId]
	if not data then
		return false
	end
	local list = (kind == "perk") and data.unlockedPerks or data.unlockedWeapons
	return Util.Contains(list, id)
end

-- Add an unlock (no token charge here — callers charge via SpendTokens first). Idempotent.
function DataService.AddUnlock(player: Player, kind: string, id: string)
	local data = store[player.UserId]
	if not data then
		return
	end
	local list = (kind == "perk") and data.unlockedPerks or data.unlockedWeapons
	if not Util.Contains(list, id) then
		table.insert(list, id)
	end
end

-- Increment a lifetime stat (stats.totalKills, stats.totalRevives, stats.matchesPlayed, ...).
function DataService.IncrementStat(player: Player, statKey: string, amount: number)
	local data = store[player.UserId]
	if not data then
		return
	end
	data.stats[statKey] = (data.stats[statKey] or 0) + amount
end

-- Record a higher best round if beaten. Returns true if it was a new record.
function DataService.UpdateBestRound(player: Player, round: number): boolean
	local data = store[player.UserId]
	if not data then
		return false
	end
	if round > (data.stats.bestRound or 0) then
		data.stats.bestRound = round
		return true
	end
	return false
end

-- Update a settings flag.
function DataService.SetSetting(player: Player, key: string, value: any)
	local data = store[player.UserId]
	if not data then
		return
	end
	data.settings[key] = value
end

-- ===== LIFECYCLE =====
function DataService.Start()
	-- Remotes are built by the bootstrap before services start, but stay defensive.
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerAdded:Connect(load)
	Players.PlayerRemoving:Connect(unload)

	-- Client UI can pull a fresh snapshot on demand.
	Remotes.Get("GetData").OnServerInvoke = function(player: Player)
		return store[player.UserId]
	end

	print("[DataService] started (in-memory stub — no persistence)")
end

return DataService
