--!nonstrict
-- BadgeAwardService.lua — Roblox BADGES (launch pass). Badges show on player profiles and in the
-- experience's Badges tab — free discovery + a reason to push one more wave.
--
-- Ids live in GameConfig.BadgeIds (0 = skipped). Award(player, key) is idempotent per session (one
-- UserHasBadgeAsync + at most one AwardBadge per badge per player), fully pcall'd, and runs off the
-- main thread. Wave + event badges hook MatchService.WaveCleared here so no other service changes.

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config").GameConfig)

local MatchService = require(script.Parent.MatchService)

local BadgeAwardService = {}

-- ===== TUNABLES =====
-- Clearing wave N (alive at the clear) awards badge key K. Every threshold at or below the cleared wave
-- is checked, so a late joiner who clears wave 25 still gets wave5/wave10.
local WAVE_BADGES = {
	{ wave = 5, key = "wave5" },
	{ wave = 10, key = "wave10" },
	{ wave = 25, key = "wave25" },
	{ wave = 50, key = "wave50" },
}
-- Surviving a whole wave under this roller outcome awards the badge with the same key.
local EVENT_BADGES = { bloodmoon = true, apocalypse = true }

-- ===== STATE =====
local done: { [number]: { [string]: boolean } } = {} -- userId -> badge key -> handled this session

local function idFor(key: string): number
	local ids = GameConfig.BadgeIds
	return (typeof(ids) == "table" and tonumber(ids[key])) or 0
end

-- Award badge `key` to `player` (no-op when the id is 0 or already handled this session).
function BadgeAwardService.Award(player: Player, key: string)
	local id = idFor(key)
	if id <= 0 or typeof(player) ~= "Instance" then
		return
	end
	local uid = player.UserId
	local mine = done[uid]
	if not mine then
		mine = {}
		done[uid] = mine
	end
	if mine[key] then
		return
	end
	mine[key] = true -- optimistic: never spam the API for the same badge twice in one session
	task.spawn(function()
		local okHas, owned = pcall(BadgeService.UserHasBadgeAsync, BadgeService, uid, id)
		if okHas and owned == true then
			return
		end
		local ok, err = pcall(BadgeService.AwardBadge, BadgeService, uid, id)
		if ok then
			print(("[BadgeAwardService] awarded %s to %s"):format(key, player.Name))
		else
			mine[key] = nil -- let a later trigger retry (transient API failure)
			warn(("[BadgeAwardService] %s for %s failed: %s"):format(key, player.Name, tostring(err)))
		end
	end)
end

-- ===== LIFECYCLE =====
function BadgeAwardService.Start()
	Players.PlayerRemoving:Connect(function(player)
		done[player.UserId] = nil
	end)

	-- WaveCleared fires BEFORE the reinforcement respawn, so ps.isDead still says who survived it.
	MatchService.WaveCleared:Connect(function(round: number)
		local ev = MatchService.GetState().waveEvent
		MatchService.ForEachPlayer(function(player, ps)
			if ps.isDead then
				return
			end
			for _, b in WAVE_BADGES do
				if round >= b.wave then
					BadgeAwardService.Award(player, b.key)
				end
			end
			if typeof(ev) == "string" and EVENT_BADGES[ev] then
				BadgeAwardService.Award(player, ev)
			end
		end)
	end)

	local live = 0
	for key in EVENT_BADGES do
		if idFor(key) > 0 then live += 1 end
	end
	for _, b in WAVE_BADGES do
		if idFor(b.key) > 0 then live += 1 end
	end
	print(("[BadgeAwardService] started (%d badge ids set)"):format(live))
end

return BadgeAwardService
