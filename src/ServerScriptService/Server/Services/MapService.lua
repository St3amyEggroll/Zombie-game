--!nonstrict
-- MapService.lua — shows the ONE selected world's map and tucks every OTHER map away, so multiple maps can
-- live in the same GAME place without overlapping. Called by MatchService at run start (before players spawn).
--
-- A "map" is a Model or Folder in Workspace/ServerStorage that is EITHER:
--   • named "<world>Map"  — case/space/dash insensitive: "ForestMap", "islands map", "islands_map"
--   • OR tagged "Map" (CollectionService) with a string attribute `World` = the world id.
-- The selected map is parented into Workspace; the others are parented to ServerStorage, which makes their
-- geometry, SpawnLocations, ZombieSpawn points, and Fog boundaries all go inert (they're no longer in the
-- world). If NOTHING matches the requested world, the scene is left untouched — single-map greyboxing still
-- works exactly as before.

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local MapService = {}

local function norm(s: any): string
	return (tostring(s):lower():gsub("[%s%-_]", ""))
end

local containers: { [string]: Instance } = {} -- normalized world id -> its map container

local function scan()
	containers = {}
	for _, root in { Workspace, ServerStorage } do
		for _, c in root:GetChildren() do
			if c:IsA("Model") or c:IsA("Folder") then
				local w = norm(c.Name):match("^(.-)map$") -- "forestmap" -> "forest"
				if w and w ~= "" then
					containers[w] = c
				end
			end
		end
	end
	for _, inst in CollectionService:GetTagged("Map") do
		local w = inst:GetAttribute("World")
		if typeof(w) == "string" and w ~= "" then
			containers[norm(w)] = inst
		end
	end
end

-- Show `world`'s map, hide the rest. Idempotent (safe to call once per joining player).
function MapService.Activate(world: string?)
	scan() -- re-scan so maps added/synced after boot are picked up
	local key = norm(world)
	if not containers[key] then
		return -- unknown world or single-map greybox: don't touch the scene
	end
	for w, inst in containers do
		local dest = (w == key) and Workspace or ServerStorage
		if inst.Parent ~= dest then
			inst.Parent = dest
		end
	end
end

function MapService.Start()
	scan()
	local n = 0
	for _ in containers do
		n += 1
	end
	print(("[MapService] started (%d map container(s) found)"):format(n))
end

return MapService
