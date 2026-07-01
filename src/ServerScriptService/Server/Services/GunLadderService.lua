--!nonstrict
-- GunLadderService.lua — the in-run gun progression. Your lobby loadout (tier slots, in order) is the
-- LADDER; you start every run holding the FIRST gun on it and buy your way up with in-run cash via the
-- client's single "NEXT GUN" button. Buying REPLACES your current gun with the next one (exactly one gun
-- owned/equipped at a time). Ladder progress is per-run only — it is never saved.
--
-- Prices come from GameConfig.NextGunPrices keyed by the tier of the gun being BOUGHT.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local GameConfig = require(Config.GameConfig)
local WeaponConfig = require(Config.WeaponConfig)
local Remotes = require(Modules.Remotes)

local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)
local PointsService = require(script.Parent.PointsService)
local CombatService = require(script.Parent.CombatService)

local GunLadderService = {}

-- ===== TUNABLES =====
local FALLBACK_PRICE = 5000 -- used if a bought gun's tier has no NextGunPrices entry (shouldn't happen)

-- The next gun on the player's ladder, or nil when they're holding the last one.
local function nextInfo(ps)
	local idx = ps.ladderIndex or 1
	local nextId = ps.gunLadder and ps.gunLadder[idx + 1]
	local weapon = nextId and WeaponConfig[nextId]
	if not weapon then
		return nil
	end
	return {
		id = nextId,
		name = weapon.name,
		price = GameConfig.NextGunPrices[weapon.tier] or FALLBACK_PRICE,
	}
end

-- Tell the client what its NEXT GUN button should show ({ name, price }, or nil = maxed/not in a run).
local function push(player: Player)
	local ps = MatchService.GetPlayerState(player)
	local info = (ps and ps.inMatch) and nextInfo(ps) or nil
	Remotes.Get("GunLadder"):FireClient(player, info and { name = info.name, price = info.price } or nil)
end
GunLadderService.Push = push

local function onBuy(player: Player)
	if not SecurityService.Allow(player, "Buy") then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return
	end
	local info = nextInfo(ps)
	if not info then
		return -- already at the top of the ladder
	end
	if not PointsService.TrySpend(player, info.price) then
		return -- can't afford (client grays the button, but always re-validate)
	end
	-- Advance the ladder: the new gun REPLACES the old one (one gun at a time).
	ps.ladderIndex += 1
	ps.ownedWeapons = { info.id }
	CombatService.SetEquipped(player, info.id) -- syncs LoadoutChanged + re-attaches the in-hand model
	push(player)
end

function GunLadderService.Start()
	Remotes.Get("BuyNextGun").OnServerEvent:Connect(onBuy)

	-- Seed the button whenever a character spawns into a run (state is set before spawnCharacter fires).
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(push, player)
		end)
		if player.Character then
			task.defer(push, player)
		end
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)

	print("[GunLadderService] started (start at tier 1, buy up the ladder)")
end

return GunLadderService
