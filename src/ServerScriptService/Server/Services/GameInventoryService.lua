--!nonstrict
-- GameInventoryService.lua — the IN-GAME (view-only) window into the player's persistent inventory that the
-- LOBBY manages: which weapons they have equipped, which cases they own, and their potions. In-game you can
-- only LOOK at weapons/cases (you equip weapons + open cases in the lobby) — but you CAN use potions here.
--
-- Also handles ELITE ZOMBIE POTION DROPS: when a player lands the killing blow on an elite (buffed) zombie
-- (model attribute "IsElite"), they get a random potion (GameConfig.PotionDrops) added to their persistent
-- inventory, which the lobby then reads. Potion effects are not implemented yet — consuming one just removes
-- it (the hook is here for later).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)
local BuffService = require(script.Parent.BuffService)

local GameInventoryService = {}

-- ===== DISPLAY CATALOG (in-game view) =====
-- Weapons come from WeaponConfig; cases/potions get friendly names here (the game doesn't have the lobby's
-- catalog). Keep the potion ids in sync with GameConfig.PotionDrops + the lobby POTIONS.
local CASES = {
	standard = { name = "Standard Case" },
}
local POTIONS = {
	damage = { name = "Damage Potion", desc = "+15% damage for the rest of the run (once per run)" },
	regen  = { name = "Regen Potion",  desc = "+50% health regen speed for the rest of the run (once per run)" },
}

local CATALOG = {
	weapons = (function()
		local t = {}
		for id, w in WeaponConfig do
			t[id] = { name = w.name, damage = w.damage, fireRate = w.fireRate, range = w.range, pellets = w.pellets }
		end
		return t
	end)(),
	cases = CASES,
	potions = POTIONS,
}

local function snapshotFor(player: Player)
	local data = DataService.Get(player)
	local ps = MatchService.GetPlayerState(player)
	return {
		catalog = CATALOG,
		selected = (data and typeof(data.selectedWeapon) == "string") and data.selectedWeapon or "pistol",
		owned = (data and typeof(data.ownedWeapons) == "table") and data.ownedWeapons or { "pistol" },
		cases = (data and typeof(data.cases) == "table") and data.cases or {},
		potions = (data and typeof(data.potions) == "table") and data.potions or {},
		used = (ps and ps.usedPotions) or {}, -- potion types already drunk THIS run (grays their Use button)
	}
end

local function push(player: Player)
	if DataService.IsReady(player) then
		Remotes.Get("InvSnapshot"):FireClient(player, snapshotFor(player))
	end
end
GameInventoryService.Push = push

-- ===== PHYSICAL POTION DROPS ===== an elite death spawns a glowing potion that pops out of the corpse,
-- then homes to the NEAREST player and is collected on contact (they get the potion + the overhead toast).
local POTION_COLOR = {
	damage = Color3.fromRGB(235, 100, 90),  -- red = damage
	regen  = Color3.fromRGB(110, 225, 130), -- green = regen
}
local POP_TIME      = 0.45  -- seconds the potion arcs out of the corpse before the magnet kicks in
local POP_UP        = 24    -- initial upward pop speed
local POP_OUT       = 9     -- initial sideways scatter speed
local GRAVITY       = 70    -- pop-phase gravity
local MAGNET_START  = 24    -- magnet speed at the start of the pull
local MAGNET_ACCEL  = 90    -- magnet acceleration (studs/s²) — snappier the longer it flies
local MAGNET_MAX    = 220
local PICKUP_RADIUS = 4.5   -- studs from a player to collect
local MAX_LIFETIME  = 20    -- seconds before a stranded potion despawns

local dropsFolder: Folder
local drops: { any } = {}

local function nearestPlayer(pos: Vector3): (Player?, BasePart?)
	local bestPlayer, bestRoot, bestDist = nil, nil, math.huge
	for _, pl in Players:GetPlayers() do
		local ps = MatchService.GetPlayerState(pl)
		local char = pl.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 and ps and ps.inMatch then
			local d = (root.Position - pos).Magnitude
			if d < bestDist then
				bestDist, bestPlayer, bestRoot = d, pl, root
			end
		end
	end
	return bestPlayer, bestRoot
end

local function grantPotion(player: Player, potionId: string)
	DataService.AddPotion(player, potionId, 1)
	DataService.Save(player) -- persist soon so the lobby sees it (teleport-back also does a blocking save)
	Remotes.Get("PotionDropped"):FireClient(player, potionId) -- overhead toast
	push(player)
end

local function spawnPotionDrop(pos: Vector3, potionId: string)
	local color = POTION_COLOR[potionId] or Color3.fromRGB(220, 220, 230)
	local part = Instance.new("Part")
	part.Name = "PotionDrop"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(1.1, 1.1, 1.1)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(pos)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 4
	light.Range = 10
	light.Parent = part
	-- Floating label so it reads as a potion.
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(40, 40)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
	bb.AlwaysOnTop = true
	bb.Parent = part
	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.Text = "🧪"
	icon.TextScaled = true
	icon.Parent = bb
	part.Parent = dropsFolder

	-- Random pop-out velocity (up + a little scatter).
	local ang = math.random() * math.pi * 2
	local vel = Vector3.new(math.cos(ang) * POP_OUT, POP_UP, math.sin(ang) * POP_OUT)
	table.insert(drops, {
		part = part,
		potionId = potionId,
		vel = vel,
		popUntil = os.clock() + POP_TIME,
		born = os.clock(),
		spin = 0,
		magnetSpeed = MAGNET_START,
	})
end

local function updateDrops(dt: number)
	local now = os.clock()
	for i = #drops, 1, -1 do
		local d = drops[i]
		local part = d.part
		if not part or not part.Parent then
			table.remove(drops, i)
		elseif now - d.born > MAX_LIFETIME then
			part:Destroy()
			table.remove(drops, i)
		else
			d.spin += dt * 5
			if now < d.popUntil then
				-- Pop phase: simple ballistic arc out of the corpse.
				d.vel = d.vel - Vector3.new(0, GRAVITY * dt, 0)
				local newPos = part.Position + d.vel * dt
				part.CFrame = CFrame.new(newPos) * CFrame.Angles(0, d.spin, 0)
			else
				-- Magnet phase: accelerate toward the nearest player; collect on contact.
				local player, root = nearestPlayer(part.Position)
				if player and root then
					local to = root.Position - part.Position
					local dist = to.Magnitude
					if dist <= PICKUP_RADIUS then
						grantPotion(player, d.potionId)
						part:Destroy()
						table.remove(drops, i)
					else
						d.magnetSpeed = math.min(MAGNET_MAX, d.magnetSpeed + MAGNET_ACCEL * dt)
						local step = math.min(dist, d.magnetSpeed * dt)
						local newPos = part.Position + (to.Unit * step)
						part.CFrame = CFrame.new(newPos) * CFrame.Angles(0, d.spin, 0)
					end
				end
			end
		end
	end
end

-- Elite kill → drop a physical potion at the corpse (homes to the nearest player, who collects it).
local function onKill(_player: Player, humanoid: Instance)
	if typeof(humanoid) ~= "Instance" then
		return
	end
	local model = humanoid.Parent
	if not model or not model:GetAttribute("IsElite") then
		return
	end
	local pool = GameConfig.PotionDrops
	if not pool or #pool == 0 then
		return
	end
	local potionId = pool[math.random(1, #pool)]
	local pos
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if ok and pivot then
		pos = pivot.Position + Vector3.new(0, 2, 0)
	end
	if pos then
		spawnPotionDrop(pos, potionId)
	end
end

local function onConsume(player: Player, potionId: any)
	if typeof(potionId) ~= "string" or not POTIONS[potionId] then
		return
	end
	-- Potions take effect DURING a run, and each TYPE only works once per run. Check eligibility BEFORE
	-- consuming so an ineligible click never burns a potion from the inventory.
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch or (ps.usedPotions and ps.usedPotions[potionId]) then
		return
	end
	if DataService.TryConsumePotion(player, potionId) then
		BuffService.ApplyPotion(player, potionId) -- applies the run effect + marks the type as used
		push(player)
	end
end

function GameInventoryService.Start()
	dropsFolder = Instance.new("Folder")
	dropsFolder.Name = "PotionDrops"
	dropsFolder.Parent = Workspace
	RunService.Heartbeat:Connect(updateDrops) -- flies + collects physical potion drops

	-- Push a snapshot when data loads and on each (re)spawn.
	DataService.Ready:Connect(function(player)
		push(player)
	end)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			task.defer(push, player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		task.defer(push, player)
	end

	-- Client asks for a fresh snapshot (e.g. when opening the inventory) by firing InvSnapshot with no args.
	Remotes.Get("InvSnapshot").OnServerEvent:Connect(function(player)
		push(player)
	end)
	Remotes.Get("ConsumePotion").OnServerEvent:Connect(onConsume)

	-- Elite zombies drop potions to whoever kills them.
	CombatService.Kill:Connect(onKill)

	print("[GameInventoryService] started (in-game inventory view + elite potion drops)")
end

return GameInventoryService
