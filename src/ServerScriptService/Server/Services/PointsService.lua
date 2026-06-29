--!nonstrict
-- PointsService.lua — per-player, match-scoped points (CoD-Zombies economy). The server is the ONLY
-- writer. Points are awarded on hit/kill from CombatService's Hit/Kill signals (CLAUDE.md §8) and spent
-- through TrySpend() by BuyService/PerkService. The zombie's pointsMult rides on a model Attribute set
-- at spawn, so we never reach across into ZombieService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)

local PointsService = {}

-- ===== CORE =====
local function fire(player: Player, points: number)
	Remotes.Get("PointsChanged"):FireClient(player, points)
end

-- Add (or, with a negative amount, remove) points. Awards funnel through here.
function PointsService.Award(player: Player, amount: number)
	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return
	end
	ps.points = math.max(0, ps.points + math.floor(amount))
	fire(player, ps.points)
end

function PointsService.GetPoints(player: Player): number
	local ps = MatchService.GetPlayerState(player)
	return ps and ps.points or 0
end

function PointsService.CanAfford(player: Player, cost: number): boolean
	local ps = MatchService.GetPlayerState(player)
	return ps ~= nil and ps.points >= cost
end

-- Atomically spend `cost` if affordable. Returns true on success. This is the ONLY spend path.
function PointsService.TrySpend(player: Player, cost: number): boolean
	local ps = MatchService.GetPlayerState(player)
	if not ps or cost < 0 or ps.points < cost then
		return false
	end
	ps.points -= cost
	fire(player, ps.points)
	return true
end

-- ===== AWARD HOOKS =====
local function pointsMultOf(humanoid: Humanoid): number
	local model = humanoid.Parent
	local m = model and model:GetAttribute("PointsMult")
	return (typeof(m) == "number") and m or 1
end

local function onHit(player: Player, humanoid: Humanoid, _isHead: boolean, _weaponId: string, _damage: number)
	PointsService.Award(player, GameConfig.PointsPerHit * pointsMultOf(humanoid))
end

local function onKill(player: Player, humanoid: Humanoid, isHead: boolean, _weaponId: string)
	local base = isHead and GameConfig.PointsHeadshotKill or GameConfig.PointsPerKill
	PointsService.Award(player, base * pointsMultOf(humanoid))

	local ps = MatchService.GetPlayerState(player)
	if ps then
		ps.kills += 1
		local model = humanoid.Parent
		if model and model:GetAttribute("IsSpecial") then
			ps.specialKills += 1
		end
	end
end

-- ===== LIFECYCLE =====
local function pushInitial(player: Player)
	local ps = MatchService.GetPlayerState(player)
	if ps then
		fire(player, ps.points)
	end
end

function PointsService.Start()
	CombatService.Hit:Connect(onHit)
	CombatService.Kill:Connect(onKill)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			task.defer(pushInitial, player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		task.defer(pushInitial, player)
	end

	print("[PointsService] started")
end

return PointsService
