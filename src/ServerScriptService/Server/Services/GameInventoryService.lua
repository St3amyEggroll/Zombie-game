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
	luck = { name = "Luck Potion", desc = "Use in a run → better buff-draft odds (+Luck)" },
	xp   = { name = "XP Potion",   desc = "Use in a run → 2× run XP" },
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
	return {
		catalog = CATALOG,
		tierLoadout = (data and typeof(data.tierLoadout) == "table") and data.tierLoadout or { "pistol", "", "", "", "" },
		owned = (data and typeof(data.ownedWeapons) == "table") and data.ownedWeapons or { "pistol" },
		cases = (data and typeof(data.cases) == "table") and data.cases or {},
		potions = (data and typeof(data.potions) == "table") and data.potions or {},
	}
end

local function push(player: Player)
	if DataService.IsReady(player) then
		Remotes.Get("InvSnapshot"):FireClient(player, snapshotFor(player))
	end
end
GameInventoryService.Push = push

-- Elite kill → drop a potion to the killer.
local function onKill(player: Player, humanoid: Instance)
	if not player or typeof(humanoid) ~= "Instance" then
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
	DataService.AddPotion(player, potionId, 1)
	DataService.Save(player) -- persist soon so the lobby sees it (teleport-back also does a blocking save)
	Remotes.Get("PotionDropped"):FireClient(player, potionId)
	push(player)
end

local function onConsume(player: Player, potionId: any)
	if typeof(potionId) ~= "string" or not POTIONS[potionId] then
		return
	end
	-- Potions take effect DURING a run (they boost the run's XP / Luck). Don't burn one otherwise.
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return
	end
	if DataService.TryConsumePotion(player, potionId) then
		BuffService.ApplyPotion(player, potionId) -- apply the run effect
		push(player)
	end
end

function GameInventoryService.Start()
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
