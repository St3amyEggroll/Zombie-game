-- init.server.lua — server bootstrap. Builds remotes, then requires + Start()s every Service in
-- dependency order. Services declared in START_ORDER start first (and in that order); any other
-- *Service module dropped into Services/ later auto-starts after them. One bad Start() is caught
-- and logged so it can't take down the whole boot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Config = Shared:WaitForChild("Config")
local Remotes = require(Modules.Remotes)
local Places = require(Config.Places)

-- Build every RemoteEvent/Function up front so services can Get() them synchronously.
Remotes.Init()

local servicesFolder = script:WaitForChild("Services")

-- Two places, one codebase (see Config/Places). The LOBBY place runs only the lobby services; the GAME
-- place (and Studio testing of any place) runs the full game. Order = dependency order (CLAUDE.md §4).
local GAME_ORDER = {
	"DataService",
	"SecurityService",
	"PlayerStateService",
	"MatchService",
	"CombatService",
	"ZombieService",
	"PointsService",
	"ShopService",
	"WeaponModelService",
}
local LOBBY_ORDER = {
	"DataService",   -- shared profile (money/XP/best wave) for the menu
	"LobbyService",  -- shows the menu + PLAY -> teleport into the game
}

local IS_LOBBY = Places.IsLobby
local START_ORDER = IS_LOBBY and LOBBY_ORDER or GAME_ORDER

local started: { [string]: boolean } = {}

local function startService(moduleScript: ModuleScript)
	local name = moduleScript.Name
	if started[name] then
		return
	end
	started[name] = true

	local ok, service = pcall(require, moduleScript)
	if not ok then
		warn(("[bootstrap] failed to require %s: %s"):format(name, tostring(service)))
		return
	end
	if type(service) ~= "table" or type(service.Start) ~= "function" then
		warn(("[bootstrap] %s has no Start() — skipping"):format(name))
		return
	end

	local sOk, err = pcall(service.Start)
	if not sOk then
		warn(("[bootstrap] %s.Start() errored: %s"):format(name, tostring(err)))
	end
end

-- 1) Start ordered services that exist.
for _, name in START_ORDER do
	local module = servicesFolder:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		startService(module)
	end
end

-- 2) Start any remaining services not named in START_ORDER (future-proofing) — GAME place only. The lobby
-- place deliberately starts ONLY its LOBBY_ORDER so it never spins up MatchService/ZombieService/etc.
if not IS_LOBBY then
	for _, module in servicesFolder:GetChildren() do
		if module:IsA("ModuleScript") and module.Name ~= "LobbyService" then
			startService(module)
		end
	end
end

print(("[bootstrap] server services started (%s)"):format(IS_LOBBY and "lobby place" or "game place"))
