--!nonstrict
-- GunShopService.lua — guns unlock by ACCOUNT LEVEL only (in ladder order; WeaponConfig.unlock).
-- GrantUnlocks(player) adds every gun the player's level has reached to the PROFILE (permanent) and to
-- the LIVE run state, then fires LoadoutChanged — which is what pops the client's NEW GUN UNLOCKED
-- showcase. ProgressionService calls this after every XP award, so unlocks land mid-run, live.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConfig = require(Shared.Config.WeaponConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Remotes = require(Shared.Modules.Remotes)
local Util = require(Shared.Modules.Util)

local DataService = require(script.Parent.DataService)
local MatchService = require(script.Parent.MatchService)

local GunShopService = {}

function GunShopService.GrantUnlocks(player: Player)
	local data = DataService.Get(player)
	if not data then
		return
	end
	if typeof(data.ownedWeapons) ~= "table" then
		data.ownedWeapons = { "pistol" }
	end
	local level = ProgressionConfig.LevelForXP(tonumber(data.xp) or 0)
	local granted = false
	for id, w in WeaponConfig do
		if (w.unlock or 0) <= level and not Util.Contains(data.ownedWeapons, id) then
			table.insert(data.ownedWeapons, id)
			granted = true
		end
	end
	if not granted then
		return
	end
	DataService.MarkDirty(player)
	local ps = MatchService.GetPlayerState(player)
	if ps then
		for _, id in data.ownedWeapons do
			if not Util.Contains(ps.ownedWeapons, id) then
				table.insert(ps.ownedWeapons, id)
			end
		end
		Remotes.Get("LoadoutChanged"):FireClient(player, ps.ownedWeapons, ps.equippedWeapon)
	end
end

function GunShopService.Start()
	-- Sweep everyone shortly after boot (profiles load async) so saved levels grant retroactively.
	task.spawn(function()
		task.wait(5)
		for _, player in Players:GetPlayers() do
			pcall(GunShopService.GrantUnlocks, player)
		end
	end)
	print("[GunShopService] started (XP-level unlocks)")
end

return GunShopService
