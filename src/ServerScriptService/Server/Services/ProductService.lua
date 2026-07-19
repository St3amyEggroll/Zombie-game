--!nonstrict
-- ProductService.lua — Robux DEVELOPER PRODUCTS. Roblox allows exactly ONE ProcessReceipt callback per
-- game, and it lives here. Add a product = paste its id into GameConfig + add a granter below.
--
-- CURRENT PRODUCTS:
--   NUKE (GameConfig.SkipWaveProductId — same product, renamed with the continuous pivot) — the small
--   gold button beside the power-clock bar. Vaporizes the horde: everything still owed is cancelled and
--   every live zombie drops dead (no cash/XP credited — there's no shooter). The horde immediately
--   starts refilling; the buy is a panic button, not a pause.
--   REVIVE (GameConfig.ReviveProductId) — the gold button on the death screen. Puts a dead player
--   straight back into the live run and cancels a pending team-wipe countdown (MatchService.RobuxRevive).

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Remotes"))

local MatchService = require(script.Parent.MatchService)
local ZombieService = require(script.Parent.ZombieService)
local DataService = require(script.Parent.DataService)

local ProductService = {}

local function grantSkipWave(player: Player) -- the NUKE (kept the old name — the receipt path is wired to it)
	if MatchService.State.phase ~= "Playing" then
		-- No live horde right now (purchase landed outside a run) — still consume the purchase below;
		-- letting it retry forever would re-fire mid-next-run unexpectedly.
		warn(("[ProductService] %s bought NUKE outside a live run — consumed with no effect"):format(player.Name))
		return
	end
	ZombieService.SkipWave()
	print(("[ProductService] %s bought NUKE — horde wiped at threat %d"):format(player.Name, MatchService.State.round))
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
		local reviveId = tonumber(GameConfig.ReviveProductId) or 0
		if reviveId > 0 and receipt.ProductId == reviveId then
			local ok, revived = pcall(MatchService.RobuxRevive, player)
			if ok and not revived then
				-- Nothing to revive (the run ended while the prompt was up) — consume anyway; letting it
				-- retry forever would resurrect them out of nowhere mid-run next session.
				warn(("[ProductService] %s bought REVIVE with no live run — consumed with no effect"):format(player.Name))
			end
			return ok and Enum.ProductPurchaseDecision.PurchaseGranted
				or Enum.ProductPurchaseDecision.NotProcessedYet
		end
		-- NEW: COIN BUNDLES (bought in-game via the HUD "+" card; same products as the lobby shop).
		-- RAW grant — never doubled by the 2x Coins pass — then the counter updates live.
		for _, b in GameConfig.CoinBundleProducts or {} do
			local bid = tonumber(b.id) or 0
			if bid > 0 and receipt.ProductId == bid then
				local ok, total = pcall(DataService.GrantPurchasedCoins, player, b.coins)
				if ok then
					Remotes.Get("LobbyMoneyChanged"):FireClient(player, total)
					print(("[ProductService] %s bought a coin bundle (+%d)"):format(player.Name, b.coins))
				end
				return ok and Enum.ProductPurchaseDecision.PurchaseGranted
					or Enum.ProductPurchaseDecision.NotProcessedYet
			end
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet -- unknown product: leave it pending
	end
	print("[ProductService] started (ProcessReceipt armed)")
end

return ProductService
