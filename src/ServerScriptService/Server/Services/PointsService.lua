--!nonstrict
-- PointsService.lua — per-player, match-scoped points (CoD-Zombies economy). The server is the ONLY
-- writer. Points are awarded on hit/kill from CombatService's Hit/Kill signals (CLAUDE.md §8) and spent
-- through TrySpend() by TrapService. The zombie's pointsMult rides on a model Attribute set
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
local PlayerStateService = require(script.Parent.PlayerStateService)

local PointsService = {}

-- ===== KILL STREAK ===== (chain kills WITHOUT taking damage for escalating cash + on-screen flair)
local streaks: { [number]: { count: number } } = {}

local function getStreak(player: Player)
	local s = streaks[player.UserId]
	if not s then
		s = { count = 0 }
		streaks[player.UserId] = s
	end
	return s
end

-- Reset a player's streak (taking damage / respawning) and tell the client to clear the flair.
local function resetStreak(player: Player)
	local s = getStreak(player)
	if s.count ~= 0 then
		s.count = 0
		Remotes.Get("KillStreak"):FireClient(player, 0, 1)
	end
end

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
-- Returns the zombie's points multiplier, or nil if this MODEL isn't a scorable zombie (no PointsMult
-- attribute). Only models ZombieService stamps mint points — a stray model can't be farmed.
-- (CUSTOM ENTITIES: CombatService passes the zombie MODEL now — zombies have no Humanoid.)
local function pointsMultOf(model: Model?): number?
	local m = model and model:GetAttribute("PointsMult")
	return (typeof(m) == "number") and m or nil
end

local function onHit(player: Player, model: Model, _isHead: boolean, _weaponId: string, _damage: number)
	local mult = pointsMultOf(model)
	if not mult then
		return
	end
	PointsService.Award(player, GameConfig.PointsPerHit * mult)
end

local function onKill(player: Player, model: Model, isHead: boolean, _weaponId: string)
	local mult = pointsMultOf(model)
	if not mult then
		return
	end
	-- Bump the streak, then pay out the kill scaled by the streak's cash multiplier.
	local s = getStreak(player)
	s.count += 1
	local streakMult = math.min(GameConfig.KillStreakMaxMult, 1 + s.count * GameConfig.KillStreakBonusPerKill)
	local base = isHead and GameConfig.PointsHeadshotKill or GameConfig.PointsPerKill
	PointsService.Award(player, base * mult * streakMult)
	Remotes.Get("KillStreak"):FireClient(player, s.count, streakMult)

	local ps = MatchService.GetPlayerState(player)
	if ps then
		ps.kills += 1
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

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		resetStreak(player) -- a fresh life starts with no streak
		task.defer(pushInitial, player)
	end)
	task.defer(pushInitial, player)
end

function PointsService.Start()
	CombatService.Hit:Connect(onHit)
	CombatService.Kill:Connect(onKill)
	PlayerStateService.Damaged:Connect(function(player)
		resetStreak(player) -- taking ANY damage breaks the chain
	end)

	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		streaks[player.UserId] = nil
	end)

	print("[PointsService] started")
end

return PointsService
