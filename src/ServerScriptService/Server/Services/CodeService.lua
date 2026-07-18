--!nonstrict
-- CodeService.lua — in-game REDEEM CODES (the HUD dock's CODES button). Mirrors the lobby's redeem
-- bar exactly: same code list, same once-per-player rule, latched through the SHARED profile field
-- `redeemed` (DataService.MarkRedeemed) so a code used in either place is used in both.
--
-- ⚠ KEEP `CODES` IN SYNC with the lobby's table (lobby-src/ServerScriptService/LobbyServer.server.lua,
-- "REDEEM CODES" section). Add/retire codes in BOTH places.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local DataService = require(script.Parent.DataService)

local CodeService = {}

-- ===== TUNABLES =====
-- Each pays coins and/or crates ONCE per player. Keys UPPERCASE, no spaces.
local CODES = {
	WELCOME = { coins = 500 },
	ROTTEN  = { case = "rare", caseCount = 1 },
}
local ATTEMPT_COOLDOWN = 0.6 -- seconds between redeem attempts per player (guess-spam brake)

local lastAttempt: { [number]: number } = {}

local function onRedeem(player: Player, code: any)
	local remote = Remotes.Get("RedeemCode")
	local function reply(ok: boolean, msg: string)
		remote:FireClient(player, { ok = ok, msg = msg })
	end
	local now = os.clock()
	if now - (lastAttempt[player.UserId] or 0) < ATTEMPT_COOLDOWN then
		return
	end
	lastAttempt[player.UserId] = now
	if typeof(code) ~= "string" or #code < 1 or #code > 32 then
		return reply(false, "INVALID CODE")
	end
	local clean = code:upper():gsub("%s", "")
	local def = CODES[clean]
	if not def then
		return reply(false, "INVALID CODE")
	end
	if not DataService.MarkRedeemed(player, clean) then
		return reply(false, "ALREADY REDEEMED")
	end
	local parts = {}
	if typeof(def.coins) == "number" and def.coins > 0 then
		-- RAW grant (codes are a fixed gift — the 2x Coins pass must not double them), same as the lobby.
		local total = DataService.GrantPurchasedCoins(player, def.coins)
		Remotes.Get("LobbyMoneyChanged"):FireClient(player, total)
		table.insert(parts, def.coins .. " COINS")
	end
	if typeof(def.case) == "string" and def.case ~= "" then
		local n = tonumber(def.caseCount) or 1
		DataService.AddCase(player, def.case, n)
		table.insert(parts, (n > 1 and (n .. "x ") or "") .. def.case:upper() .. " CRATE")
	end
	reply(true, "REDEEMED!  +" .. table.concat(parts, "  +"))
	print(("[CodeService] %s redeemed %s"):format(player.Name, clean))
end

function CodeService.Start()
	Remotes.Get("RedeemCode").OnServerEvent:Connect(onRedeem)
	Players.PlayerRemoving:Connect(function(player)
		lastAttempt[player.UserId] = nil
	end)
	print("[CodeService] started (in-game redeem, shared profile latch)")
end

return CodeService
