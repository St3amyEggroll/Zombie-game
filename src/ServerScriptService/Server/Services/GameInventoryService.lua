--!nonstrict
-- GameInventoryService.lua — the IN-GAME window into the player's persistent inventory that the LOBBY
-- manages: the 2-gun loadout, owned guns, cases, and potions. In-game you can only LOOK at weapons/cases
-- (equip + open in the lobby) — but you CAN use potions here.
--
-- Also owns the PHYSICAL DROPS:
--  * ELITE POTIONS — an elite (yellow) zombie's death pops a potion that homes to the NEAREST player.
--  * WAVE CASES  — every GameConfig.CaseDropEvery-th wave cleared, EVERY player gets their own case drop
--    (pops out at their feet, homes to them). Rarity is rolled per player: Common..Divine, with the odds
--    shifting toward higher tiers the deeper the wave (GameConfig.CaseWeightsBase/CaseWeightGrowth).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local GameConfig = require(Config.GameConfig)
local BuffConfig = require(Config.BuffConfig)
local PotionConfig = require(Config.PotionConfig)
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)
local CombatService = require(script.Parent.CombatService)
local MatchService = require(script.Parent.MatchService)
local BuffService = require(script.Parent.BuffService)
local ZombieService = require(script.Parent.ZombieService)

local GameInventoryService = {}

-- ===== DISPLAY CATALOG (in-game view; keep names in sync with the lobby's catalog) =====
-- Rarity names/colors come from BuffConfig.Rarities (the same 7-tier ladder the buff draft uses).
local RARITIES = {}
for _, r in BuffConfig.Rarities do
	RARITIES[r.id] = { name = r.name, color = r.color }
end

local WEAPON_RARITY = { pistol = "common", shotgun = "uncommon", ak47 = "rare", minigun = "epic", raygun = "legendary" }

local CASES = {}
for _, rarity in GameConfig.CaseRarities do
	CASES[rarity] = { name = (RARITIES[rarity] and RARITIES[rarity].name or rarity) .. " Case", rarity = rarity }
end

-- 14 tiered potions (2 types × 7 rarities) straight from PotionConfig — name/desc/rarity per id.
local POTIONS = {}
for _, id in PotionConfig.AllIds() do
	local stats = PotionConfig.Stats(id)
	POTIONS[id] = {
		name = PotionConfig.DisplayName(id),
		desc = PotionConfig.Desc(id),
		rarity = stats.rarity,
		type = stats.type,
	}
end

local CATALOG = {
	weapons = (function()
		local t = {}
		for id, w in WeaponConfig do
			t[id] = {
				name = w.name, tier = w.tier, rarity = WEAPON_RARITY[id] or "common",
				damage = w.damage, fireRate = w.fireRate, range = w.range, pellets = w.pellets,
			}
		end
		return t
	end)(),
	rarities = RARITIES,
	rarityOrder = GameConfig.CaseRarities,
	cases = CASES,
	potions = POTIONS,
}

local function snapshotFor(player: Player)
	local data = DataService.Get(player)
	local ps = MatchService.GetPlayerState(player)
	return {
		catalog = CATALOG,
		loadout = (data and typeof(data.loadout) == "table") and data.loadout or { "pistol" },
		owned = (data and typeof(data.ownedWeapons) == "table") and data.ownedWeapons or { "pistol" },
		cases = (data and typeof(data.cases) == "table") and data.cases or {},
		potions = (data and typeof(data.potions) == "table") and data.potions or {},
		gunLevels = (data and typeof(data.gunLevels) == "table") and data.gunLevels or {},
		-- ACTIVE potion buffs by TYPE -> seconds remaining (grays the Use button for that type).
		active = (function()
			local out = {}
			local now = os.clock()
			for ptype, b in (ps and ps.potionBuffs) or {} do
				if b.expiresAt > now then
					out[ptype] = b.expiresAt - now
				end
			end
			return out
		end)(),
	}
end

local function push(player: Player)
	if DataService.IsReady(player) then
		Remotes.Get("InvSnapshot"):FireClient(player, snapshotFor(player))
	end
end
GameInventoryService.Push = push

-- ===== PHYSICAL DROPS ===== (potions home to the NEAREST player; cases home to a SPECIFIC player)
-- Physical potion drops glow with their RARITY color (the rarer the pull, the flashier the orb).
local POP_TIME      = 0.45  -- seconds a drop arcs upward before the magnet kicks in
local POP_UP        = 24    -- initial upward pop speed
local POP_OUT       = 9     -- initial sideways scatter speed
local GRAVITY       = 70    -- pop-phase gravity
local MAGNET_START  = 24    -- magnet speed at the start of the pull
local MAGNET_ACCEL  = 90    -- magnet acceleration (studs/s²) — snappier the longer it flies
local MAGNET_MAX    = 220
local PICKUP_RADIUS = 4.5   -- studs from a player to collect
local MAX_LIFETIME  = 20    -- seconds before a stranded drop despawns

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

-- The homing target for a drop: its dedicated player (case drops), else whoever is nearest (potions).
local function targetFor(drop, pos: Vector3): (Player?, BasePart?)
	local pl = drop.targetPlayer
	if pl then
		if not pl.Parent then
			return nil, nil -- their owner left; the drop just despawns via MAX_LIFETIME
		end
		local char = pl.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			return pl, root
		end
		return nil, nil
	end
	return nearestPlayer(pos)
end

local function grantDrop(player: Player, drop)
	if drop.kind == "case" then
		-- Boss cases are BANKED the moment the boss dies (see onBossDied) so a disconnect/despawn can
		-- never lose one — the flying drop is pure show, and pickup just fires the toast.
		Remotes.Get("CaseDropped"):FireClient(player, drop.rarity)
		return
	end
	DataService.AddPotion(player, drop.potionId, 1)
	Remotes.Get("PotionDropped"):FireClient(player, drop.potionId)
	DataService.Save(player) -- persist soon so the lobby sees it (teleport-back also does a blocking save)
	push(player)
end

-- A glowing drop that pops out at `pos` then homes in. opts: {kind="potion", potionId=} or
-- {kind="case", rarity=, targetPlayer=}.
local function spawnDrop(pos: Vector3, opts)
	local color, labelText
	if opts.kind == "case" then
		color = (RARITIES[opts.rarity] and RARITIES[opts.rarity].color) or Color3.fromRGB(220, 220, 230)
		labelText = "CASE"
	else
		local pstats = PotionConfig.Stats(opts.potionId or "")
		color = (pstats and RARITIES[pstats.rarity] and RARITIES[pstats.rarity].color) or Color3.fromRGB(220, 220, 230)
		labelText = "POTION"
	end

	local part = Instance.new("Part")
	part.Name = opts.kind == "case" and "CaseDrop" or "PotionDrop"
	part.Shape = opts.kind == "case" and Enum.PartType.Block or Enum.PartType.Ball
	part.Size = opts.kind == "case" and Vector3.new(1.4, 1.0, 1.4) or Vector3.new(1.1, 1.1, 1.1)
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
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(70, 22)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
	bb.AlwaysOnTop = true
	bb.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = color
	label.Text = labelText
	label.Parent = bb
	part.Parent = dropsFolder

	local ang = math.random() * math.pi * 2
	local vel = Vector3.new(math.cos(ang) * POP_OUT, POP_UP, math.sin(ang) * POP_OUT)
	local drop = {
		part = part,
		kind = opts.kind,
		potionId = opts.potionId,
		rarity = opts.rarity,
		targetPlayer = opts.targetPlayer,
		vel = vel,
		popUntil = os.clock() + POP_TIME,
		born = os.clock(),
		spin = 0,
		magnetSpeed = MAGNET_START,
	}
	table.insert(drops, drop)
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
				-- Pop phase: simple ballistic arc.
				d.vel = d.vel - Vector3.new(0, GRAVITY * dt, 0)
				local newPos = part.Position + d.vel * dt
				part.CFrame = CFrame.new(newPos) * CFrame.Angles(0, d.spin, 0)
			else
				-- Magnet phase: accelerate toward the target; collect on contact.
				local player, root = targetFor(d, part.Position)
				if player and root then
					local to = root.Position - part.Position
					local dist = to.Magnitude
					if dist <= PICKUP_RADIUS then
						grantDrop(player, d)
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

-- ===== ELITE POTION DROPS =====
local function onKill(_player: Player, humanoid: Instance)
	if typeof(humanoid) ~= "Instance" then
		return
	end
	local model = humanoid.Parent
	if not model or not model:GetAttribute("IsElite") then
		return
	end
	-- Random type, wave-weighted rarity — deeper waves drop better potions (PotionConfig).
	local potionId = PotionConfig.RollDropId(MatchService.State.round or 1)
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if ok and pivot then
		spawnDrop(pivot.Position + Vector3.new(0, 2, 0), { kind = "potion", potionId = potionId })
	end
end

-- ===== WAVE-CLEAR CASE DROPS =====
-- Rarity roll: weight(tier) = CaseWeightsBase[tier] * CaseWeightGrowth^((tier-1) * stage), where
-- stage = wave/CaseDropEvery - 1 (wave 10 = 0, wave 20 = 1, ...) — deeper waves favor higher tiers.
local function rollCaseRarity(wave: number): string
	local stage = math.max(0, math.floor(wave / GameConfig.CaseDropEvery) - 1)
	local weights, total = {}, 0
	for i, base in GameConfig.CaseWeightsBase do
		local w = base * (GameConfig.CaseWeightGrowth ^ ((i - 1) * stage))
		weights[i] = w
		total += w
	end
	local r = math.random() * total
	local acc = 0
	for i, w in weights do
		acc += w
		if r <= acc then
			return GameConfig.CaseRarities[i]
		end
	end
	return GameConfig.CaseRarities[1]
end

-- Cases drop the moment the BOSS DIES (not at wave end): everyone in the run gets one, bursting out of
-- the boss's corpse and homing to them. The case is BANKED (saved) immediately at the kill — the flying
-- drop is cosmetic and only fires the pickup toast — so leaving/dying mid-flight can never lose it. On
-- the difficulty's FINAL wave there's no drop at all (the victory teleport would race it): toast now.
local function onBossDied(deathPos)
	local round = MatchService.State.round
	local isFinal = round >= (MatchService.State.maxWave or math.huge)
	local origin = deathPos and (deathPos + Vector3.new(0, 3, 0)) or nil
	for _, player in Players:GetPlayers() do
		local ps = MatchService.GetPlayerState(player)
		if ps and ps.inMatch then
			local rarity = rollCaseRarity(math.max(round, GameConfig.CaseDropEvery))
			DataService.AddCase(player, rarity, 1)
			DataService.Save(player)
			push(player)
			if isFinal or not origin then
				Remotes.Get("CaseDropped"):FireClient(player, rarity)
			else
				spawnDrop(origin, { kind = "case", rarity = rarity, targetPlayer = player })
			end
		end
	end
end

-- ===== POTION CONSUME =====
local function onConsume(player: Player, potionId: any)
	if typeof(potionId) ~= "string" or not POTIONS[potionId] then
		return
	end
	-- Potions take effect DURING a run; one ACTIVE buff per TYPE — you can drink again after it expires.
	-- Check eligibility BEFORE consuming so an ineligible click never burns a potion from the inventory.
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return
	end
	local ptype = PotionConfig.Parse(potionId)
	if not ptype or BuffService.IsPotionTypeActive(player, ptype) then
		return
	end
	if DataService.TryConsumePotion(player, potionId) then
		BuffService.ApplyPotion(player, potionId) -- applies the run effect + marks the type as used
		push(player)
	end
end

function GameInventoryService.Start()
	dropsFolder = Instance.new("Folder")
	dropsFolder.Name = "Drops"
	dropsFolder.Parent = Workspace
	RunService.Heartbeat:Connect(updateDrops) -- flies + collects the physical drops

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

	CombatService.Kill:Connect(onKill)     -- elite zombies drop potions
	ZombieService.BossDied:Connect(onBossDied) -- killing a boss drops a case for every player

	print("[GameInventoryService] started (inventory view + potion/case drops)")
end

return GameInventoryService
