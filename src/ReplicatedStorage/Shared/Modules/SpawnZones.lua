--!nonstrict
-- SpawnZones.lua — keep-out volumes so NOTHING spawns out of bounds. Any BasePart under a folder named
-- "Fog" (e.g. Workspace.ForestMap.OutOffReach.Fog — the boundary walls) OR any BasePart tagged "NoSpawn"
-- becomes a no-spawn box. Every spawner (zombies, ammo pickups, and future item drops) checks
-- SpawnZones.IsBlocked(position) and picks somewhere else if it's true.
--
-- Server-side use. Folders are found once (re-searched only while none are known); the part list refreshes
-- on a slow timer so streamed-in/rebuilt map geometry is picked up without scanning every call.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local SpawnZones = {}

-- ===== TUNABLES =====
local MARGIN        = 4    -- extra studs of buffer kept clear around every keep-out box
local PART_RESCAN   = 3    -- seconds between refreshing the part list from the known Fog folders
local FOLDER_RESCAN = 5    -- seconds between re-searching for "Fog" folders WHILE none are known

-- Dynamic folders/models we never descend into when hunting for Fog folders (perf).
local SKIP = { Zombies = true, Graves = true, Pickups = true, CombatFX = true, Debris = true, Terrain = true }

local fogFolders: { Instance } = {}
local parts: { BasePart } = {}
local lastFolderScan = -math.huge
local lastPartScan = -math.huge

local function findFogFolders()
	local found = {}
	local function recurse(inst: Instance, depth: number)
		if depth > 8 then
			return
		end
		for _, c in inst:GetChildren() do
			if c:IsA("Folder") then
				if c.Name == "Fog" then
					table.insert(found, c)
				elseif not SKIP[c.Name] then
					recurse(c, depth + 1)
				end
			elseif c:IsA("Model") and not SKIP[c.Name] then
				recurse(c, depth + 1)
			end
		end
	end
	recurse(Workspace, 0)
	fogFolders = found
end

local function anyFolderAlive(): boolean
	for _, f in fogFolders do
		if f.Parent then
			return true
		end
	end
	return false
end

local function refreshParts()
	local list = {}
	for _, folder in fogFolders do
		if folder.Parent then
			for _, p in folder:GetDescendants() do
				if p:IsA("BasePart") then
					table.insert(list, p)
				end
			end
		end
	end
	for _, p in CollectionService:GetTagged("NoSpawn") do
		if p:IsA("BasePart") then
			table.insert(list, p)
		end
	end
	parts = list
end

-- True if `pos` is inside (within MARGIN of) any keep-out box.
function SpawnZones.IsBlocked(pos: Vector3): boolean
	local now = os.clock()
	if not anyFolderAlive() then
		if now - lastFolderScan > FOLDER_RESCAN then
			lastFolderScan = now
			findFogFolders()
			refreshParts()
			lastPartScan = now
		end
	elseif now - lastPartScan > PART_RESCAN then
		lastPartScan = now
		refreshParts()
	end

	for _, part in parts do
		if part.Parent then
			local rel = part.CFrame:PointToObjectSpace(pos)
			local s = part.Size * 0.5
			if math.abs(rel.X) <= s.X + MARGIN and math.abs(rel.Y) <= s.Y + MARGIN and math.abs(rel.Z) <= s.Z + MARGIN then
				return true
			end
		end
	end
	return false
end

return SpawnZones
