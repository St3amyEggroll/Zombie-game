--!strict
-- Util.lua — small, dependency-free helpers shared by every system.
-- Home of: weighted-random (spawns + box rolls), number/time formatting, table copy.

local Util = {}

-- ===== WEIGHTED RANDOM =====
-- Pick a key from a { key = weight } table, proportional to weight.
-- Used by the zombie spawner (spawnWeight) and the Mystery Box roll (Pool). Returns nil if empty.
function Util.WeightedChoice(weights: { [string]: number }): string?
	local total = 0
	for _, w in weights do
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = math.random() * total
	local acc = 0
	for key, w in weights do
		if w > 0 then
			acc += w
			if roll <= acc then
				return key
			end
		end
	end
	return nil
end

-- Same idea, but with a filter so callers can gate by minRound, alive caps, etc.
function Util.WeightedChoiceFiltered(weights: { [string]: number }, allow: (string) -> boolean): string?
	local filtered: { [string]: number } = {}
	for key, w in weights do
		if w > 0 and allow(key) then
			filtered[key] = w
		end
	end
	return Util.WeightedChoice(filtered)
end

-- ===== FORMATTING =====
-- 1234567 -> "1,234,567" (points/score display).
function Util.FormatNumber(n: number): string
	local neg = n < 0
	local s = tostring(math.floor(math.abs(n)))
	local out = ""
	local count = 0
	for i = #s, 1, -1 do
		out = s:sub(i, i) .. out
		count += 1
		if count % 3 == 0 and i > 1 then
			out = "," .. out
		end
	end
	return (neg and "-" or "") .. out
end

-- 83 -> "1:23" (timers).
function Util.FormatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local m = math.floor(seconds / 60)
	local s = seconds % 60
	return string.format("%d:%02d", m, s)
end

-- ===== TABLES =====
-- Recursive copy. Used by DataService to instance the meta TEMPLATE without aliasing it.
function Util.DeepCopy<T>(tbl: T): T
	local function copy(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local out = {}
		for k, val in pairs(v) do
			out[k] = copy(val)
		end
		return out
	end
	return copy(tbl) :: T
end

-- Is `value` present in array `t`?
function Util.Contains<T>(t: { T }, value: T): boolean
	for _, v in t do
		if v == value then
			return true
		end
	end
	return false
end

-- Round to N decimal places.
function Util.Round(n: number, places: number?): number
	local m = 10 ^ (places or 0)
	return math.floor(n * m + 0.5) / m
end

-- ===== CHARACTER HELPERS =====
-- Safely fetch a player's HumanoidRootPart (nil if not spawned).
function Util.GetRootPart(player: Player): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Safely fetch a player's Humanoid.
function Util.GetHumanoid(player: Player): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

return Util
