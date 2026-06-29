-- init.server.lua — server bootstrap. Builds remotes, then requires + Start()s every Service in
-- dependency order. Services declared in START_ORDER start first (and in that order); any other
-- *Service module dropped into Services/ later auto-starts after them. One bad Start() is caught
-- and logged so it can't take down the whole boot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

-- Build every RemoteEvent/Function up front so services can Get() them synchronously.
Remotes.Init()

local servicesFolder = script:WaitForChild("Services")

-- Explicit dependency order (CLAUDE.md §4): Data -> Security -> PlayerState -> Match -> everything.
local START_ORDER = {
	"DataService",
	"SecurityService",
	"PlayerStateService",
	"MatchService",
	"CombatService",
	"ZombieService",
	"PointsService",
	"ShopService",
	"WeaponModelService",
	-- Later phases append here as their services land:
	-- "ReviveService", "ProgressionService", "LeaderboardService",
}

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

-- 2) Start any remaining services not named in START_ORDER (future-proofing).
for _, module in servicesFolder:GetChildren() do
	if module:IsA("ModuleScript") then
		startService(module)
	end
end

print("[bootstrap] server services started")
