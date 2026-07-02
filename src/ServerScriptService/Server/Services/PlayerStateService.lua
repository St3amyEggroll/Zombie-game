--!nonstrict
-- PlayerStateService.lua — server-authoritative player health, regen, movement, and sprint stamina.
-- This is the foundation Juggernog (max health) and Stamin-Up (move speed) plug into later (Phase 5).
-- Health is server-owned: nothing reduces it except PlayerStateService.Damage() from a validated source.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

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

-- Base walk speed × the in-run Move Speed buff (BuffService). Sprint multiplies this on top (see heartbeat).
local function computeMoveSpeed(player: Player): number
	local ps = MatchService.GetPlayerState(player)
	local buff = (ps and ps.buffs and ps.buffs.walkspeed) or 0
	return GameConfig.PlayerWalkSpeed * (1 + buff)
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

-- ===== PLAYER-PLAYER COLLISION OFF =====
-- All player parts share a collision group that doesn't collide with itself (you can't be body-blocked
-- by a teammate). Zombies/world still collide normally.
local PLAYER_GROUP = "Players"
pcall(function()
	PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
	PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, PLAYER_GROUP, false)
end)

local function setCollisionGroup(character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = PLAYER_GROUP
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = PLAYER_GROUP
		end
	end)
end

-- ===== CHARACTER SETUP =====
local function onCharacterAdded(player: Player, character: Model)
	setCollisionGroup(character)
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

-- ===== DOWN / REVIVE =====
-- At 0 HP with a teammate still UP, a player goes DOWNED instead of dying: crawl speed, untargetable
-- (zombies skip the character's "Downed" attribute), bleeding out over GameConfig.BleedoutSeconds unless
-- a teammate holds E within ReviveRange for ReviveSeconds. Solo deaths (or bleedout / team wipe) die
-- normally, which banks the run and teleports to the lobby (MatchService's Died handler).

-- reviveHolds[reviverUserId] = { target = Player, progress = seconds held so far }
local reviveHolds: { [number]: any } = {}

local function setDowned(player: Player, downed: boolean, bleedSecs: number?)
	local character = player.Character
	if character then
		character:SetAttribute("Downed", downed and true or nil)
	end
	Remotes.Get("DownedChanged"):FireAllClients(player.UserId, downed, bleedSecs or 0)
end

local function clearDownedHighlight(player: Player)
	local char = player.Character
	local hl = char and char:FindFirstChild("DownedHighlight")
	if hl then
		hl:Destroy()
	end
end

local function enterDowned(player: Player, ps, humanoid: Humanoid)
	ps.isDowned = true
	ps.downedUntil = os.clock() + GameConfig.BleedoutSeconds
	humanoid.Health = 1
	humanoid.JumpHeight = 0
	humanoid.JumpPower = 0
	getRuntime(player).lastWalkSpeed = -1 -- heartbeat re-applies at crawl speed
	-- Red glow so teammates can find them through the horde.
	local char = player.Character
	if char then
		clearDownedHighlight(player)
		local hl = Instance.new("Highlight")
		hl.Name = "DownedHighlight"
		hl.FillColor = Color3.fromRGB(230, 60, 60)
		hl.OutlineColor = Color3.fromRGB(255, 90, 90)
		hl.FillTransparency = 0.55
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = char
	end
	setDowned(player, true, GameConfig.BleedoutSeconds)
	MatchService.CheckTeamWipe() -- if this down means nobody is up, the run ends for everyone
end

local function reviveNow(player: Player, ps)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	ps.isDowned = false
	ps.downedUntil = 0
	if humanoid then
		humanoid.Health = math.max(1, humanoid.MaxHealth * GameConfig.ReviveHealthPct)
		humanoid.JumpHeight = 7.2 -- Roblox defaults
		humanoid.JumpPower = 50
	end
	getRuntime(player).lastWalkSpeed = -1
	clearDownedHighlight(player)
	setDowned(player, false)
end

-- Bleed out (or team wipe): leave the downed state and die for real — MatchService's Died handler then
-- banks the run and returns them to the lobby.
local function bleedOut(player: Player, ps)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	ps.isDowned = false
	clearDownedHighlight(player)
	setDowned(player, false)
	if humanoid then
		humanoid.Health = 0
	end
end

-- ===== PUBLIC API =====

-- Apply `amount` damage to a player from a validated source (zombies use this).
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
	local ps = MatchService.GetPlayerState(player)
	if ps and ps.isDowned then
		return -- downed players can't be hit (they're already out of the fight)
	end
	getRuntime(player).lastDamage = os.clock()

	-- The killing blow with a teammate still up → go DOWNED instead of dying (co-op only).
	if ps and ps.inMatch and (humanoid.Health - amount) <= 0 and MatchService.HasUpTeammate(player) then
		Remotes.Get("DamageTaken"):FireClient(player, amount, sourcePos)
		damagedEvent:Fire(player, amount, source)
		enterDowned(player, ps, humanoid)
		return
	end

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

	-- Players currently being revived: their bleedout timer is PAUSED while a teammate holds E on them.
	local beingRevived: { [number]: boolean } = {}
	for _, hold in reviveHolds do
		if hold.target then
			beingRevived[hold.target.UserId] = true
		end
	end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			local r = getRuntime(player)
			local ps = MatchService.GetPlayerState(player)

			if ps and ps.isDowned then
				-- Downed: crawl speed, no regen, bleeding out on a timer (frozen while being revived).
				if math.abs(GameConfig.DownedWalkSpeed - r.lastWalkSpeed) > 0.01 then
					humanoid.WalkSpeed = GameConfig.DownedWalkSpeed
					r.lastWalkSpeed = GameConfig.DownedWalkSpeed
				end
				if beingRevived[player.UserId] then
					ps.downedUntil += step -- pause: push the deadline forward by exactly the elapsed time
				elseif now >= ps.downedUntil then
					bleedOut(player, ps)
				end
			else
				-- Health regen after a quiet period (Regen Potion multiplies the rate for the run).
				if humanoid.Health < humanoid.MaxHealth and (now - r.lastDamage) >= GameConfig.HealthRegenDelay then
					local regenMult = (ps and ps.regenMult) or 1
					humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + GameConfig.HealthRegenRate * regenMult * step)
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

	-- Revive holds: advance each active hold; validate every tick (both alive, target still downed, range).
	for reviverUserId, hold in reviveHolds do
		local reviver = Players:GetPlayerByUserId(reviverUserId)
		local target = hold.target
		local targetPs = target and target.Parent and MatchService.GetPlayerState(target)
		local rChar = reviver and reviver.Character
		local tChar = target and target.Character
		local rRoot = rChar and rChar:FindFirstChild("HumanoidRootPart")
		local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
		local rHum = rChar and rChar:FindFirstChildOfClass("Humanoid")
		local rPs = reviver and MatchService.GetPlayerState(reviver)

		local valid = reviver and targetPs and targetPs.isDowned
			and rHum and rHum.Health > 0 and rPs and not rPs.isDowned
			and rRoot and tRoot and (rRoot.Position - tRoot.Position).Magnitude <= GameConfig.ReviveRange
		if not valid then
			reviveHolds[reviverUserId] = nil
			if reviver then
				Remotes.Get("ReviveProgress"):FireClient(reviver, target and target.UserId or 0, 0)
			end
			if target and target.Parent then
				Remotes.Get("ReviveProgress"):FireClient(target, target.UserId, 0)
				-- The bleedout was paused during the hold — resync the target's countdown display.
				if targetPs and targetPs.isDowned then
					Remotes.Get("DownedChanged"):FireAllClients(target.UserId, true, math.max(0, targetPs.downedUntil - os.clock()))
				end
			end
		else
			hold.progress += step
			local frac = math.clamp(hold.progress / GameConfig.ReviveSeconds, 0, 1)
			Remotes.Get("ReviveProgress"):FireClient(reviver, target.UserId, frac)
			Remotes.Get("ReviveProgress"):FireClient(target, target.UserId, frac)
			if hold.progress >= GameConfig.ReviveSeconds then
				reviveHolds[reviverUserId] = nil
				reviveNow(target, targetPs)
			end
		end
	end
end

-- ===== REVIVE REMOTE ===== (targetUserId, holding) — start/stop holding E on a downed teammate.
local function onRevive(player: Player, targetUserId: any, holding: any)
	if not SecurityService.Allow(player, "Revive") then
		return
	end
	if holding ~= true then
		reviveHolds[player.UserId] = nil
		return
	end
	if typeof(targetUserId) ~= "number" then
		return
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == player then
		return
	end
	local targetPs = MatchService.GetPlayerState(target)
	local myPs = MatchService.GetPlayerState(player)
	if not targetPs or not targetPs.isDowned or not myPs or myPs.isDowned then
		return
	end
	local myRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local tRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not myRoot or not tRoot or (myRoot.Position - tRoot.Position).Magnitude > GameConfig.ReviveRange then
		return
	end
	reviveHolds[player.UserId] = { target = target, progress = 0 }
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
	Remotes.Get("Revive").OnServerEvent:Connect(onRevive)
	RunService.Heartbeat:Connect(onHeartbeat)

	Players.PlayerRemoving:Connect(function(player)
		reviveHolds[player.UserId] = nil
	end)

	print("[PlayerStateService] started (down/revive enabled)")
end

return PlayerStateService
