--!nonstrict
-- MapService.lua — clones the SELECTED world's map into Workspace and removes the previously-active one, so
-- every map can live as a TEMPLATE in storage. Called by MatchService at run start (before players spawn).
--
-- A map template is a Model or Folder that is EITHER:
--   • named "<world>Map"  — case/space/dash insensitive, and singular/plural tolerant:
--       "ForestMap" → forest, "IslandsMap"/"islandMap"/"islands map" → islands
--   • OR tagged "Map" (CollectionService) with a String attribute `World` = the world id.
-- Keep templates in ServerStorage or ReplicatedStorage — loose, or nested in a "Maps"/"Assets/Maps" folder
-- (any depth up to 3 is scanned). ServerStorage is leaner (ReplicatedStorage copies replicate to clients).
--
-- Activate() clones the chosen template into Workspace as "ActiveMap" and destroys the previous ActiveMap, so
-- exactly one map is live at a time. The clone carries its tags (PlayerSpawn/ZombieSpawn/Fog) and its
-- SpawnLocation, which is why players + zombie spawns work from it.

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local MapService = {}

local ACTIVE_NAME = "ActiveMap"
-- Folders we never descend into while hunting for map templates (perf + avoid false positives).
local SKIP = {
	Shared = true, Server = true, Remotes = true, Zombies = true, Graves = true, Splashes = true,
	GunDisplay = true, CrateDisplay = true, Weapons = true, Terrain = true, Camera = true,
}

local function norm(s: any): string
	return (tostring(s):lower():gsub("[%s%-_]", ""))
end

local templates: { [string]: Instance } = {} -- normalized world id -> its template instance

local function consider(inst: Instance)
	if not (inst:IsA("Model") or inst:IsA("Folder")) then
		return
	end
	local world
	local attr = inst:GetAttribute("World")
	if typeof(attr) == "string" and attr ~= "" then
		world = norm(attr)
	else
		local w = norm(inst.Name):match("^(.-)map$") -- "forestmap" -> "forest"
		if w and w ~= "" then
			world = w
		end
	end
	if world then
		templates[world] = inst
	end
end

local function scan()
	templates = {}
	local function recurse(inst: Instance, depth: number)
		for _, c in inst:GetChildren() do
			consider(c)
			if depth < 3 and c:IsA("Folder") and not SKIP[c.Name] then
				recurse(c, depth + 1)
			end
		end
	end
	recurse(ServerStorage, 0)
	recurse(ReplicatedStorage, 0)
	for _, inst in CollectionService:GetTagged("Map") do
		consider(inst)
	end
end

-- Tolerates a singular/plural mismatch (islandMap ↔ islands) so the map name doesn't have to be exact.
local function lookup(world: string?): Instance?
	local w = norm(world)
	return templates[w] or templates[(w:gsub("s$", ""))] or templates[w .. "s"]
end

function MapService.Activate(world: string?)
	scan()
	local tmpl = lookup(world)
	if not tmpl then
		warn(("[MapService] no map template for world '%s' — name one '<world>Map' (or tag it 'Map' with a "
			.. "World attribute) in ServerStorage/ReplicatedStorage."):format(tostring(world)))
		return
	end
	local existing = Workspace:FindFirstChild(ACTIVE_NAME)
	if existing then
		existing:Destroy()
	end
	local clone = tmpl:Clone()
	clone.Name = ACTIVE_NAME
	clone.Parent = Workspace
end

function MapService.Start()
	scan()
	local names = {}
	for w in templates do
		table.insert(names, w)
	end
	print(("[MapService] started (%d map template(s): %s)"):format(#names, table.concat(names, ", ")))
end

return MapService
