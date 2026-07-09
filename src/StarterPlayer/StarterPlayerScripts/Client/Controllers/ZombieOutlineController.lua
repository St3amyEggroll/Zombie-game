--!nonstrict
-- ZombieOutlineController.lua — the zombies' cartoon black outlines, done within Roblox's budget.
-- Roblox renders at most ~31 Highlights at once; the server used to put one on EVERY zombie, so with a
-- horde most outlines silently dropped while still costing memory. This controller owns a small POOL of
-- Highlights on each client and keeps them adorned to the NEAREST zombies only, reassigning on a timer.
-- (Player outlines are separate and always on — there are never enough players to threaten the budget.)

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ZombieOutlineController = {}

-- ===== TUNABLES =====
local MAX_OUTLINES  = 20    -- pool size (players + these must stay under Roblox's ~31 Highlight cap)
local REFRESH_EVERY = 0.4   -- seconds between nearest-zombie reassignments
local FOLDER_NAME   = "Zombies" -- ZombieService's workspace folder

local localPlayer = Players.LocalPlayer

local pool: { Highlight } = {}

local function makeHighlight(): Highlight
	local hl = Instance.new("Highlight")
	hl.Name = "ZOutline"
	hl.FillTransparency = 1
	hl.OutlineColor = Color3.new(0, 0, 0)
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
		if m:IsA("Model") then
			local root = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart")
			if root then
				table.insert(candidates, { model = m, d = (root.Position - origin).Magnitude })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.d < b.d
	end)
	for i, hl in pool do
		local entry = candidates[i]
		if entry then
			if hl.Adornee ~= entry.model then
				hl.Adornee = entry.model
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
	print(("[ZombieOutlineController] started (%d-outline pool, nearest zombies win)"):format(MAX_OUTLINES))
end

return ZombieOutlineController
