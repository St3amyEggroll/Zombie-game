--!nonstrict
-- TrapService.lua — buyable map hazards (electric floor, fire trap, spinning blades, ...).
--
-- HOW TO MAKE A TRAP (data-driven, no code): build a Part that defines the DAMAGE ZONE (e.g. a floor
-- tile), tag it "Trap" (CollectionService), and set these Attributes on it:
--   Cost      (number)  cash to trigger it                                   [default 500]
--   Damage    (number)  damage PER SECOND to zombies in the zone            [default 150]
--   Duration  (number)  seconds it stays active                            [default 5]
--   Cooldown  (number)  seconds before it can be triggered again           [default 15]
--   Height    (number)  studs ABOVE the part the zone reaches (so it hits zombies standing on it) [default 8]
--   TrapType  (string)  "Electric" / "Fire" / "Blades" — only drives the client VFX colour [default "Electric"]
-- A player presses E (Interact) while standing within ACTIVATE_DIST of the trap to trigger it. The SERVER
-- owns the cash, the damage, and the cooldown (anti-exploit). You build the model + VFX; this runs it.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)
local ZombieService = require(script.Parent.ZombieService)
local PointsService = require(script.Parent.PointsService)

local TrapService = {}

-- ===== TUNABLES =====
local ACTIVATE_DIST = 12     -- studs the player must be within to trigger a trap
local TICK          = 0.25   -- seconds between damage ticks while active
local DEFAULTS = { Cost = 500, Damage = 150, Duration = 5, Cooldown = 15, Height = 8, TrapType = "Electric" }

-- traps[taggedInstance] = { zone = BasePart, active = bool, cooldownUntil = serverTime }
local traps: { [Instance]: any } = {}

local function attr(part: BasePart, name: string)
	local v = part:GetAttribute(name)
	if v == nil then
		return DEFAULTS[name]
	end
	return v
end

-- A zombie is in the zone if it's inside the part's box (XZ) and within Height studs above it.
local function inZone(part: BasePart, height: number, pos: Vector3): boolean
	local rel = part.CFrame:PointToObjectSpace(pos)
	local half = part.Size * 0.5
	return math.abs(rel.X) <= half.X
		and math.abs(rel.Z) <= half.Z
		and rel.Y >= -half.Y and rel.Y <= half.Y + height
end

-- Damage a zombie; credit the activating player with the kill cash if it dies.
local function damageZombie(player: Player, record, amount: number)
	local hum = record.hum
	if not hum or hum.Health <= 0 then
		return
	end
	hum.Health = math.max(0, hum.Health - amount)
	if hum.Health <= 0 then
		local model = hum.Parent
		local mult = (model and model:GetAttribute("PointsMult")) or 1
		PointsService.Award(player, GameConfig.PointsPerKill * mult)
		local ps = MatchService.GetPlayerState(player)
		if ps then
			ps.kills += 1
			if model and model:GetAttribute("IsSpecial") then
				ps.specialKills += 1
			end
		end
	end
end

local function activate(inst: Instance, player: Player)
	local st = traps[inst]
	if not st or not st.zone or not st.zone.Parent then
		return
	end
	local zone = st.zone
	local now = Workspace:GetServerTimeNow()
	if st.active or now < st.cooldownUntil then
		return -- already running or still cooling down
	end
	if not PointsService.TrySpend(player, attr(zone, "Cost")) then
		return -- can't afford
	end

	st.active = true
	local duration = attr(zone, "Duration")
	local damage = attr(zone, "Damage")
	local height = attr(zone, "Height")
	zone:SetAttribute("ActiveUntil", now + duration)
	Remotes.Get("TrapActivated"):FireAllClients(zone, attr(zone, "TrapType"), duration)

	task.spawn(function()
		local endT = now + duration
		while Workspace:GetServerTimeNow() < endT and zone.Parent do
			for _, record in ZombieService.GetActive() do
				if record.root and inZone(zone, height, record.root.Position) then
					damageZombie(player, record, damage * TICK)
				end
			end
			task.wait(TICK)
		end
		st.active = false
		st.cooldownUntil = Workspace:GetServerTimeNow() + attr(zone, "Cooldown")
		zone:SetAttribute("CooldownUntil", st.cooldownUntil)
		zone:SetAttribute("ActiveUntil", 0)
		Remotes.Get("TrapDeactivated"):FireAllClients(zone)
	end)
end

local function nearestTrap(pos: Vector3): Instance?
	local best, bestDist = nil, ACTIVATE_DIST
	for inst, st in traps do
		if st.zone and st.zone.Parent then
			local d = (st.zone.Position - pos).Magnitude
			if d <= bestDist then
				best, bestDist = inst, d
			end
		end
	end
	return best
end

-- ===== REGISTRATION (tag-driven) =====
-- The tagged thing can be the zone Part itself, or a Model (its PrimaryPart / first part is the zone).
local function zonePartOf(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

local function register(inst: Instance)
	if traps[inst] then
		return
	end
	local zone = zonePartOf(inst)
	if zone then
		traps[inst] = { zone = zone, active = false, cooldownUntil = 0 }
		zone:SetAttribute("CooldownUntil", 0)
		zone:SetAttribute("ActiveUntil", 0)
	end
end

-- ===== LIFECYCLE =====
function TrapService.Start()
	for _, inst in CollectionService:GetTagged("Trap") do
		register(inst)
	end
	CollectionService:GetInstanceAddedSignal("Trap"):Connect(register)
	CollectionService:GetInstanceRemovedSignal("Trap"):Connect(function(inst)
		traps[inst] = nil
	end)

	-- Player presses E (Interact) near a trap -> trigger the nearest one.
	Remotes.Get("Interact").OnServerEvent:Connect(function(player)
		if not SecurityService.Allow(player, "Interact") then
			return
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end
		local inst = nearestTrap(root.Position)
		if inst then
			activate(inst, player)
		end
	end)

	print("[TrapService] started")
end

return TrapService
