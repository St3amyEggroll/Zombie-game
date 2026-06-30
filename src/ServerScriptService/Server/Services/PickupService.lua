--!nonstrict
-- PickupService.lua — ammo pickups. A model named "Ammo1" (any "Ammo*" model in Assets, Assets/Ammo, or
-- Assets/Pickups) is cloned AMMO_PER_WAVE times each wave at random spots near players. Walk into one to
-- add AMMO_FRACTION of every owned gun's full reserve back. Server-authoritative; spins for visibility.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)

local PickupService = {}

-- ===== TUNABLES =====
local AMMO_FRACTION = 0.2    -- fraction of each gun's FULL reserve granted per pickup
local AMMO_PER_WAVE = 3      -- pickups spawned each wave
local PICKUP_RADIUS = 6      -- studs a player must be within to grab it
local SPAWN_MIN     = 18     -- min studs from a random player to drop a pickup
local SPAWN_MAX     = 45     -- max studs
local FLOAT_HEIGHT  = 2.5    -- studs above the ground the pickup hovers
local SPIN_SPEED    = 1.5    -- radians/sec it spins

local ammoTemplates: { Model } = {}
local pickupFolder: Folder
local pickups: { [Model]: any } = {} -- model -> { spin }

-- ===== ASSET LOOKUP =====
local function ciFind(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	local exact = parent:FindFirstChild(name)
	if exact then
		return exact
	end
	local l = name:lower()
	for _, c in parent:GetChildren() do
		if c.Name:lower() == l then
			return c
		end
	end
	return nil
end

local function asModel(inst: Instance?): Model?
	if not inst then
		return nil
	end
	if inst:IsA("Model") then
		return inst
	end
	return inst:FindFirstChildWhichIsA("Model")
end

local function loadTemplates()
	local list, seen = {}, {}
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		if assets then
			for _, place in { assets, ciFind(assets, "Ammo"), ciFind(assets, "Pickups") } do
				if place then
					for _, c in place:GetChildren() do
						local m = asModel(c)
						if m and not seen[m] and m.Name:lower():match("^ammo") then
							seen[m] = true
							table.insert(list, m)
						end
					end
				end
			end
		end
	end
	ammoTemplates = list
end

-- ===== SPAWN =====
local function findGround(x: number, z: number, fallbackY: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local filter: { Instance } = { pickupFolder }
	for _, n in { "Zombies", "Graves" } do
		local f = Workspace:FindFirstChild(n)
		if f then
			table.insert(filter, f)
		end
	end
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(filter, pl.Character)
		end
	end
	params.FilterDescendantsInstances = filter
	local hit = Workspace:Raycast(Vector3.new(x, fallbackY + 8, z), Vector3.new(0, -120, 0), params)
	return hit and hit.Position.Y or fallbackY
end

local function randomPlayerRoot(): BasePart?
	local cands = {}
	for _, pl in Players:GetPlayers() do
		local r = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
		if r then
			table.insert(cands, r)
		end
	end
	if #cands == 0 then
		return nil
	end
	return cands[math.random(#cands)]
end

local function spawnOne()
	if #ammoTemplates == 0 then
		return
	end
	local root = randomPlayerRoot()
	if not root then
		return
	end
	local angle = math.random() * 2 * math.pi
	local dist = SPAWN_MIN + math.random() * (SPAWN_MAX - SPAWN_MIN)
	local x = root.Position.X + math.cos(angle) * dist
	local z = root.Position.Z + math.sin(angle) * dist
	local groundY = findGround(x, z, root.Position.Y)

	local model = ammoTemplates[math.random(#ammoTemplates)]:Clone()
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false -- shots / raycasts pass through it
		end
	end
	local cf, size = model:GetBoundingBox()
	local baseY = cf.Position.Y - size.Y * 0.5
	model:PivotTo(model:GetPivot() + Vector3.new(x - cf.Position.X, (groundY + FLOAT_HEIGHT) - baseY, z - cf.Position.Z))
	model.Parent = pickupFolder
	pickups[model] = { spin = 0 }
end

local function clearAll()
	for model in pickups do
		model:Destroy()
	end
	pickups = {}
end

local function spawnWave()
	clearAll()
	for _ = 1, AMMO_PER_WAVE do
		spawnOne()
	end
end

-- ===== HEARTBEAT: spin + proximity pickup =====
local function onHeartbeat(dt: number)
	for model, data in pickups do
		if not model.Parent then
			pickups[model] = nil
		else
			data.spin += dt * SPIN_SPEED
			local pos = model:GetPivot().Position
			model:PivotTo(CFrame.new(pos) * CFrame.Angles(0, data.spin, 0))
			for _, pl in Players:GetPlayers() do
				local char = pl.Character
				local r = char and char:FindFirstChild("HumanoidRootPart")
				local h = char and char:FindFirstChildOfClass("Humanoid")
				if r and h and h.Health > 0 and (r.Position - pos).Magnitude <= PICKUP_RADIUS then
					CombatService.GiveAmmoFraction(pl, AMMO_FRACTION)
					Remotes.Get("AmmoPickup"):FireClient(pl, AMMO_FRACTION)
					model:Destroy()
					pickups[model] = nil
					break
				end
			end
		end
	end
end

-- ===== LIFECYCLE =====
function PickupService.Start()
	pickupFolder = Instance.new("Folder")
	pickupFolder.Name = "Pickups"
	pickupFolder.Parent = Workspace

	loadTemplates()
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Spawn a fresh batch of ammo each time a new wave starts playing; clear on return to lobby.
	task.spawn(function()
		local lastRound = 0
		while true do
			local round = MatchService.GetRound()
			if round > lastRound and MatchService.GetPhase() == "Playing" then
				lastRound = round
				spawnWave()
			elseif round < lastRound then
				lastRound = round
				clearAll()
			end
			task.wait(0.5)
		end
	end)

	print("[PickupService] started"
		.. (#ammoTemplates == 0 and " (no 'Ammo*' model found in Assets — pickups disabled)" or ""))
end

return PickupService
