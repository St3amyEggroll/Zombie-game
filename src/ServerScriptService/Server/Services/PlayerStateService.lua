--!nonstrict
-- PlayerStateService.lua — server-authoritative player health, regen, movement, and sprint stamina.
-- This is the foundation Juggernog (max health) and Stamin-Up (move speed) plug into later (Phase 5).
-- Health is server-owned: nothing reduces it except PlayerStateService.Damage() from a validated source.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local MatchService = require(script.Parent.MatchService)
local SecurityService = require(script.Parent.SecurityService)

local PlayerStateService = {}

-- ===== SIGNALS (other services subscribe) =====
local damagedEvent = Instance.new("BindableEvent")
PlayerStateService.Damaged = damagedEvent.Event -- (player, amount, source) — fired when a player takes damage

-- ===== TUNABLES (most live in GameConfig; these are local feel knobs) =====
local REGEN_TICK = 0.1   -- how often regen/sprint math runs (seconds); cosmetic granularity only

-- ===== STATE (per userId) =====
-- runtime[userId] = { lastDamage, sprintWanted, stamina, lastWalkSpeed }
local runtime: { [number]: any } = {}

-- ===== HELPERS =====
local function getRuntime(player: Player)
	local r = runtime[player.UserId]
	if not r then
		r = {
			lastDamage = 0,
			sprintWanted = false,
			stamina = GameConfig.SprintStaminaMax,
			lastWalkSpeed = -1,
			lastSentHealth = -1,     -- for coalescing HealthChanged pushes
			lastSentMaxHealth = -1,
		}
		runtime[player.UserId] = r
	end
	return r
end

-- Base walk speed / max health. (Hooks for future buffs — currently just the GameConfig values.)
local function computeMoveSpeed(_player: Player): number
	return GameConfig.PlayerWalkSpeed
end

local function computeMaxHealth(_player: Player): number
	return GameConfig.PlayerMaxHealth
end

local function fireHealth(player: Player, humanoid: Humanoid)
	-- Always keep match state exact.
	local ps = MatchService.GetPlayerState(player)
	if ps then
		ps.health = humanoid.Health
		ps.maxHealth = humanoid.MaxHealth
	end
	-- Coalesce the network push: only send when the DISPLAYED (integer) HP/MaxHealth changes, or at a
	-- 0/full boundary. Avoids ~10 redundant HealthChanged RemoteEvents/sec while a player regenerates.
	local r = getRuntime(player)
	local h = math.floor(humanoid.Health + 0.5)
	local mh = math.floor(humanoid.MaxHealth + 0.5)
	local atBoundary = humanoid.Health <= 0 or humanoid.Health >= humanoid.MaxHealth
	if r.lastSentHealth == h and r.lastSentMaxHealth == mh and not atBoundary then
		return
	end
	r.lastSentHealth = h
	r.lastSentMaxHealth = mh
	Remotes.Get("HealthChanged"):FireClient(player, humanoid.Health, humanoid.MaxHealth)
end

-- ===== CHARACTER SETUP =====
local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	local maxHealth = computeMaxHealth(player)
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	humanoid.WalkSpeed = computeMoveSpeed(player)

	local r = getRuntime(player)
	r.lastDamage = 0
	r.stamina = GameConfig.SprintStaminaMax
	r.sprintWanted = false
	r.lastWalkSpeed = humanoid.WalkSpeed

	fireHealth(player, humanoid)

	-- Track external health changes (e.g. future scripted damage) so the regen timer resets on damage.
	humanoid.HealthChanged:Connect(function(newHealth)
		fireHealth(player, humanoid)
	end)

	humanoid.Died:Connect(function()
		local ps = MatchService.GetPlayerState(player)
		if ps then
			ps.isDead = true
		end
		-- Phase 6 routes this to down/revive + all-down game over. Phase 1: just record it.
	end)
end

-- ===== PUBLIC API =====

-- Apply `amount` damage to a player from a validated source (zombies use this in Phase 2).
-- `sourcePos` (optional) is where the hit came from — sent to the client so it can draw a directional
-- hurt indicator pointing at the attacker.
function PlayerStateService.Damage(player: Player, amount: number, source: string?, sourcePos: Vector3?)
	if amount <= 0 then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	getRuntime(player).lastDamage = os.clock()
	humanoid.Health = math.max(0, humanoid.Health - amount)
	-- HealthChanged connection fires the remote + syncs match state.
	Remotes.Get("DamageTaken"):FireClient(player, amount, sourcePos)
	damagedEvent:Fire(player, amount, source)
end

-- Heal a player by `amount` (capped at MaxHealth). Used by Quick Revive / pickups later.
function PlayerStateService.Heal(player: Player, amount: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + amount)
end

-- Recompute and apply max health (e.g. after buying Juggernog). Keeps current HP ratio sane.
function PlayerStateService.RefreshMaxHealth(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local newMax = computeMaxHealth(player)
	local delta = newMax - humanoid.MaxHealth
	humanoid.MaxHealth = newMax
	if delta > 0 then
		humanoid.Health = math.min(newMax, humanoid.Health + delta) -- gain the new headroom as HP
	else
		humanoid.Health = math.min(humanoid.Health, newMax)
	end
end

-- Recompute and apply walk speed (e.g. after buying Stamin-Up).
function PlayerStateService.RefreshMoveSpeed(player: Player)
	getRuntime(player).lastWalkSpeed = -1 -- force the heartbeat to re-apply
end

function PlayerStateService.GetHealth(player: Player): number
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid and humanoid.Health or 0
end

-- ===== HEARTBEAT: regen + sprint stamina + walk speed =====
local accum = 0
local function onHeartbeat(dt: number)
	accum += dt
	if accum < REGEN_TICK then
		return
	end
	local step = accum
	accum = 0

	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			local r = getRuntime(player)

			-- Health regen after a quiet period.
			if humanoid.Health < humanoid.MaxHealth and (now - r.lastDamage) >= GameConfig.HealthRegenDelay then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + GameConfig.HealthRegenRate * step)
			end

			-- Sprint stamina.
			local moving = humanoid.MoveDirection.Magnitude > 0.05
			local baseSpeed = computeMoveSpeed(player)
			local sprinting = r.sprintWanted and moving and r.stamina > 0
			if sprinting then
				r.stamina = math.max(0, r.stamina - GameConfig.SprintDrainPerSec * step)
			else
				r.stamina = math.min(GameConfig.SprintStaminaMax, r.stamina + GameConfig.SprintRegenPerSec * step)
			end

			local targetSpeed = sprinting and (baseSpeed * GameConfig.SprintMultiplier) or baseSpeed
			if math.abs(targetSpeed - r.lastWalkSpeed) > 0.01 then
				humanoid.WalkSpeed = targetSpeed
				r.lastWalkSpeed = targetSpeed
			end
		end
	end
end

-- ===== SPRINT REMOTE =====
local function onSprint(player: Player, wantSprint: any)
	if not SecurityService.Allow(player, "Sprint") then
		return
	end
	getRuntime(player).sprintWanted = wantSprint == true
end

-- ===== LIFECYCLE =====
local function hookPlayer(player: Player)
	getRuntime(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function PlayerStateService.Start()
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		runtime[player.UserId] = nil
	end)

	Remotes.Get("Sprint").OnServerEvent:Connect(onSprint)
	RunService.Heartbeat:Connect(onHeartbeat)

	print("[PlayerStateService] started")
end

return PlayerStateService
