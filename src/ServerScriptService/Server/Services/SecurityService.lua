--!nonstrict
-- SecurityService.lua — shared anti-exploit foundation: a per-player token-bucket rate limiter
-- plus small validation helpers. Every service that handles a client remote calls into here.
-- (Same rigor as the Duck Game weapon remotes — see CLAUDE.md §14.) Started right after DataService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local GameConfig = require(Config.GameConfig)

local SecurityService = {}

-- buckets[userId][action] = { tokens: number, last: number }
local buckets: { [number]: { [string]: { tokens: number, last: number } } } = {}

-- ===== TOKEN-BUCKET RATE LIMITER =====
-- Returns true if `player` is allowed to perform `action` right now (and consumes a token).
-- Bucket capacity = the per-second limit in GameConfig.RateLimits (so a 1s burst is permitted),
-- refilling continuously at that same rate. Unlisted actions are unlimited.
function SecurityService.Allow(player: Player, action: string): boolean
	local rate = GameConfig.RateLimits[action]
	if not rate then
		return true
	end

	local now = os.clock()
	local byUser = buckets[player.UserId]
	if not byUser then
		byUser = {}
		buckets[player.UserId] = byUser
	end

	local bucket = byUser[action]
	if not bucket then
		bucket = { tokens = rate, last = now }
		byUser[action] = bucket
	end

	-- Refill since last check, capped at capacity.
	local elapsed = now - bucket.last
	bucket.last = now
	bucket.tokens = math.min(rate, bucket.tokens + elapsed * rate)

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

-- ===== VALIDATION HELPERS =====

function SecurityService.IsFiniteNumber(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function SecurityService.IsFiniteVector3(v: any): boolean
	return typeof(v) == "Vector3"
		and SecurityService.IsFiniteNumber(v.X)
		and SecurityService.IsFiniteNumber(v.Y)
		and SecurityService.IsFiniteNumber(v.Z)
end

-- Is `direction` a usable aim vector? (finite + non-zero, so it can be unit-ized server-side.)
function SecurityService.IsValidDirection(v: any): boolean
	return SecurityService.IsFiniteVector3(v) and v.Magnitude > 0.001
end

-- Combat origin sanity: the claimed shot origin must be near the server's known player position.
-- Returns true if within `maxStuds` of the player's HumanoidRootPart. (CLAUDE.md §14.3)
function SecurityService.OriginNearPlayer(player: Player, origin: Vector3, maxStuds: number): boolean
	if not SecurityService.IsFiniteVector3(origin) then
		return false
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	return (origin - hrp.Position).Magnitude <= maxStuds
end

-- Is the player currently alive and spawned? (gate for fire/interact/etc.)
function SecurityService.IsAlive(player: Player): boolean
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- ===== LIFECYCLE =====
function SecurityService.Start()
	Players.PlayerRemoving:Connect(function(player)
		buckets[player.UserId] = nil
	end)
	print("[SecurityService] started")
end

return SecurityService
