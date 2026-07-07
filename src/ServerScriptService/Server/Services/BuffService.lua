--!nonstrict
-- BuffService.lua — in-run POTION buffs (tiered, TIMED, STACKING — PotionConfig).
-- CHANGED: the level-up buff draft (run XP -> pick-a-buff cards) was REMOVED; potions are the only
-- in-run power-up now. ps.buffs still exists (always zeros) so CombatService's buffOf math is untouched.
--
-- ps.potionBuffs is keyed by POTION ID (one entry per tier):
--   * drinking the SAME potion again EXTENDS its timer (2x common damage = 60s of +10%)
--   * DIFFERENT tiers of one type run side by side and their effects ADD (divine 75% + common 10% = 85%
--     until one of them runs out). No cap — drop rates are the balance lever.
-- CombatService/PlayerStateService SUM the active entries; this pushes the HUD's chip list.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local PotionConfig = require(Config.PotionConfig)
local Remotes = require(Modules.Remotes)

local MatchService = require(script.Parent.MatchService)

local BuffService = {}

-- Sync the client's "active potion buffs" strip (above the HP bar): { {id, type, rarity, pct, remaining} }.
local function pushPotionBuffs(player: Player, ps)
	local now = os.clock()
	local list = {}
	for id, b in ps.potionBuffs or {} do
		if b.expiresAt > now then
			table.insert(list, {
				id = id, type = b.type, rarity = b.rarity, pct = b.pct,
				remaining = b.expiresAt - now,
			})
		end
	end
	Remotes.Get("PotionBuffsChanged"):FireClient(player, list)
end
BuffService.PushPotionBuffs = pushPotionBuffs

-- The summed bonus of every ACTIVE buff of a type ("damage" / "regen").
function BuffService.PotionBonus(ps, ptype: string): number
	local total = 0
	if ps and ps.potionBuffs then
		local now = os.clock()
		for _, b in ps.potionBuffs do
			if b.type == ptype and b.expiresAt > now then
				total += b.pct
			end
		end
	end
	return total
end

function BuffService.ApplyPotion(player: Player, potionId: string): boolean
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return false
	end
	local stats = PotionConfig.Stats(potionId)
	if not stats then
		return false
	end
	ps.potionBuffs = ps.potionBuffs or {}
	local now = os.clock()
	local cur = ps.potionBuffs[potionId]
	if cur and cur.expiresAt > now then
		cur.expiresAt += stats.duration -- same potion while running: EXTEND the timer
	else
		ps.potionBuffs[potionId] = {
			type = stats.type,
			rarity = stats.rarity,
			pct = stats.pct,
			expiresAt = now + stats.duration,
		}
	end
	pushPotionBuffs(player, ps)
	return true
end

-- ===== LIFECYCLE =====
function BuffService.Start()
	-- Resync the HUD chip strip when the run's character spawns.
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(function()
				local ps = MatchService.GetPlayerState(player)
				if ps then
					pushPotionBuffs(player, ps)
				end
			end)
		end)
	end
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerAdded:Connect(hook)

	-- Potion buff expiry sweep: once a second, drop finished buffs and resync that player's HUD strip.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for _, p in Players:GetPlayers() do
				local ps = MatchService.GetPlayerState(p)
				if ps and ps.potionBuffs then
					local changed = false
					for id, b in ps.potionBuffs do
						if b.expiresAt <= now then
							ps.potionBuffs[id] = nil
							changed = true
						end
					end
					if changed then
						pushPotionBuffs(p, ps)
					end
				end
			end
		end
	end)

	print("[BuffService] started (potions only — buff draft removed)")
end

return BuffService
