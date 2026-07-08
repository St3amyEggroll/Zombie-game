--!nonstrict
-- ProductService.lua — Robux DEVELOPER PRODUCTS. Roblox allows exactly ONE ProcessReceipt callback per
-- game, and it lives here. Add a product = paste its id into GameConfig + add a granter below.
--
-- CURRENT PRODUCTS:
--   SKIP WAVE (GameConfig.SkipWaveProductId) — the small gold button beside the enemies bar. Clears the
--   current wave instantly: everything still owed is cancelled and every live zombie drops dead, so the
--   wave completes through the normal cleared check (no cash/XP credited — there's no shooter).

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))

local MatchService = require(script.Parent.MatchService)
local ZombieService = require(script.Parent.ZombieService)

local ProductService = {}

local function grantSkipWave(player: Player)
	if MatchService.State.phase ~= "Playing" then
		-- Nothing to skip right now (purchase landed between waves) — still consume the purchase below;
		-- letting it retry forever would re-fire mid-next-wave unexpectedly.
		warn(("[ProductService] %s bought SKIP WAVE outside a live wave — consumed with no effect"):format(player.Name))
		return
	end
	ZombieService.SkipWave()
	print(("[ProductService] %s bought SKIP WAVE — wave %d cleared"):format(player.Name, MatchService.State.round))
end

function ProductService.Start()
	MarketplaceService.ProcessReceipt = function(receipt)
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet -- they left mid-purchase; retried on next join
		end
		local skipId = tonumber(GameConfig.SkipWaveProductId) or 0
		if skipId > 0 and receipt.ProductId == skipId then
			local ok = pcall(grantSkipWave, player)
			return ok and Enum.ProductPurchaseDecision.PurchaseGranted
				or Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet -- unknown product: leave it pending
	end
	print("[ProductService] started (ProcessReceipt armed)")
end

return ProductService
