--!nonstrict
-- GunShopService.lua — MID-RUN gun buying (press B / the SHOP button in-game). Same Coins and the same
-- WeaponConfig.price as the lobby: the purchase is PERMANENT (written to the profile; ownedWeapons is a
-- game-owned save field so it survives the run and reaches the lobby).
-- Validation per CLAUDE.md §14: rate-limited, price/ownership checked server-side, Coins deducted here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConfig = require(Shared.Config.WeaponConfig)
local Remotes = require(Shared.Modules.Remotes)
local Util = require(Shared.Modules.Util)

local DataService = require(script.Parent.DataService)
local SecurityService = require(script.Parent.SecurityService)
local MatchService = require(script.Parent.MatchService)

local GunShopService = {}

function GunShopService.Start()
	Remotes.Get("BuyGun").OnServerEvent:Connect(function(player, req)
		if not SecurityService.Allow(player, "Buy") then
			return
		end
		if typeof(req) ~= "table" then
			return
		end
		local weaponId = tostring(req.weaponId or "")
		local weapon = WeaponConfig[weaponId]
		if not weapon then
			return
		end
		local price = tonumber(weapon.price) or 0
		if price <= 0 then
			return -- starter / not for sale
		end
		local data = DataService.Get(player)
		if not data then
			return
		end
		if typeof(data.ownedWeapons) ~= "table" then
			data.ownedWeapons = { "pistol" }
		end
		if Util.Contains(data.ownedWeapons, weaponId) then
			return -- already owned
		end
		if (data.lobbyMoney or 0) < price then
			return
		end
		data.lobbyMoney -= price
		table.insert(data.ownedWeapons, weaponId)
		DataService.MarkDirty(player)

		-- Make it usable THIS run: the live player state drives equip/fire validation and the hotbar.
		local ps = MatchService.GetPlayerState(player)
		if ps then
			if not Util.Contains(ps.ownedWeapons, weaponId) then
				table.insert(ps.ownedWeapons, weaponId)
			end
			Remotes.Get("LoadoutChanged"):FireClient(player, ps.ownedWeapons, ps.equippedWeapon)
		end
		Remotes.Get("LobbyMoneyChanged"):FireClient(player, data.lobbyMoney)
	end)
	print("[GunShopService] started")
end

return GunShopService
