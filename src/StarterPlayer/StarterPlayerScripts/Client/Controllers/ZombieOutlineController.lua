--!nonstrict
-- ZombieOutlineController.lua — the zombies' cartoon outlines AND the at-a-distance THREAT read.
-- Roblox renders at most ~31 Highlights at once; the server used to put one on EVERY zombie, so with a
-- horde most outlines silently dropped while still costing memory. This controller owns a small POOL of
-- Highlights on each client and keeps them adorned to the most IMPORTANT zombies — dangerous archetypes
-- first (colored by threat), then the nearest grunts (plain black) — reassigning on a timer.
--
-- Why threat colors: many high-threat types (bomb/lead/leaper/ghost/speedy/tanks) are NOT flagged
-- isSpecial, so before this they looked identical to grunts until they were on top of you. Each type
-- now carries a ZType attribute (set server-side); we map it to a threat color + priority so a Bomb
-- Zombie reads as a RED silhouette from across the map and always wins an outline slot.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ZombieOutlineController = {}

-- ===== TUNABLES =====
local MAX_OUTLINES  = 20    -- pool size (players + these must stay under Roblox's ~31 Highlight cap)
local REFRESH_EVERY = 0.4   -- seconds between reassignments
local FOLDER_NAME   = "Zombies" -- ZombieService's workspace folder

local GRUNT_COLOR = Color3.fromRGB(0, 0, 0) -- the default cartoon outline

-- typeId -> { color, priority }. Higher priority ALWAYS claims an outline before lower ones, so a
-- dangerous enemy is never a hidden grunt in a horde. Anything unlisted = a plain black grunt (prio 0).
-- CHANGED (owner call): EVERY normal zombie wears the same BLACK cartoon outline — speedies, tanks,
-- lead, ghosts, all of them. Color is reserved for the SPECIAL threats: bosses, the bomb zombie
-- (it explodes on you — must read from across the map), and event zombies (the Bloodhound pack).
-- Priorities stay: dangerous types still always WIN an outline slot, they just wear black.
local THREAT = {
	-- MUST-IDENTIFY: explodes on you. Brightest red, top priority (also named from spawn, server-side).
	bombzombie  = { color = Color3.fromRGB(255, 60, 30), prio = 4 },
	-- BOSSES: deep red, always outlined.
	boss        = { color = Color3.fromRGB(255, 24, 24), prio = 5 },
	lumberjack  = { color = Color3.fromRGB(255, 24, 24), prio = 5 },
	necromancer = { color = Color3.fromRGB(255, 24, 24), prio = 5 },
	-- EVENT ZOMBIES: the Bloodhound pack (roller event) reads in its event's color.
	hound       = { color = Color3.fromRGB(200, 120, 60), prio = 3 },
	-- Dangerous-but-normal types: BLACK like everyone else, but they still claim outline slots first.
	tank        = { color = GRUNT_COLOR, prio = 3 },
	speedytank  = { color = GRUNT_COLOR, prio = 3 },
	leapertank  = { color = GRUNT_COLOR, prio = 3 },
	leadtank    = { color = GRUNT_COLOR, prio = 3 },
	brinebrute  = { color = GRUNT_COLOR, prio = 3 },
	lead        = { color = GRUNT_COLOR, prio = 2 },
	speedy      = { color = GRUNT_COLOR, prio = 2 },
	lurker      = { color = GRUNT_COLOR, prio = 2 },
	leaper      = { color = GRUNT_COLOR, prio = 2 },
	angler      = { color = GRUNT_COLOR, prio = 2 },
	ghost       = { color = GRUNT_COLOR, prio = 2 },
}

local localPlayer = Players.LocalPlayer

local pool: { Highlight } = {}

local function makeHighlight(): Highlight
	local hl = Instance.new("Highlight")
	hl.Name = "ZOutline"
	hl.FillTransparency = 1
	hl.OutlineColor = GRUNT_COLOR
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Enabled = false
	hl.Parent = Workspace -- adornee-based; parent just needs to exist
	return hl
end

local function refresh()
	local folder = Workspace:FindFirstChild(FOLDER_NAME)
	if not folder then
		for _, hl in pool do
			hl.Enabled = false
			hl.Adornee = nil
		end
		return
	end
	-- Distance from the CAMERA (what you're looking at matters more than where you're standing).
	local cam = Workspace.CurrentCamera
	local origin = cam and cam.CFrame.Position
	if not origin then
		local char = localPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		origin = root and root.Position
	end
	if not origin then
		return
	end
	local candidates = {}
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("ZDead") ~= true then
			local root = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart")
			if root then
				local threat = THREAT[m:GetAttribute("ZType")]
				table.insert(candidates, {
					model = m,
					d = (root.Position - origin).Magnitude,
					prio = threat and threat.prio or 0,
					color = threat and threat.color or GRUNT_COLOR,
				})
			end
		end
	end
	-- Dangerous types first (so they never lose a slot to a nearer grunt), then nearest-first within a tier.
	table.sort(candidates, function(a, b)
		if a.prio ~= b.prio then
			return a.prio > b.prio
		end
		return a.d < b.d
	end)
	for i, hl in pool do
		local entry = candidates[i]
		if entry then
			if hl.Adornee ~= entry.model then
				hl.Adornee = entry.model
			end
			if hl.OutlineColor ~= entry.color then
				hl.OutlineColor = entry.color
			end
			hl.Enabled = true
		else
			hl.Enabled = false
			hl.Adornee = nil
		end
	end
end

function ZombieOutlineController.Start()
	for _ = 1, MAX_OUTLINES do
		table.insert(pool, makeHighlight())
	end
	task.spawn(function()
		while true do
			refresh()
			task.wait(REFRESH_EVERY)
		end
	end)
	print(("[ZombieOutlineController] started (%d-outline pool, threat-colored, dangerous types win)"):format(MAX_OUTLINES))
end

return ZombieOutlineController
