--!nonstrict
-- WindController.lua — subtle wind: faint thin streaks drift through the air in a BAND around the player, so
-- there's always a bit of atmospheric motion on screen without filling the whole map. Purely client-side and
-- cosmetic (parts live under the camera, never replicated). Tune the feel in the TUNABLES below.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local WindController = {}

-- ===== TUNABLES =====
local COUNT       = 16                              -- how many streaks exist at once (subtle = few)
local WIND_DIR    = Vector3.new(1, -0.05, 0.35)     -- direction the wind blows (auto-normalized)
local SPEED       = 34                               -- studs/sec the streaks drift
local SPEED_VAR   = 0.4                              -- ± fraction of SPEED, randomized per streak
local RADIUS      = 42                               -- horizontal radius of the band kept around the player
local HEIGHT_MIN  = -6                               -- lowest streak height relative to the player
local HEIGHT_MAX  = 26                               -- highest streak height relative to the player
local LENGTH_MIN  = 5                                -- shortest streak (studs)
local LENGTH_MAX  = 11                               -- longest streak
local THICK       = 0.06                             -- streak thickness (studs) — keep tiny
local TRANSP_MIN  = 0.82                             -- most visible a streak gets (higher = fainter)
local TRANSP_MAX  = 0.92                             -- faintest
local COLOR       = Color3.fromRGB(232, 240, 255)    -- cool, near-white

local localPlayer = Players.LocalPlayer
local folder
local streaks = {} -- { part, pos (Vector3), speed, length }

-- Wind axes (constant): the horizontal flow direction + a horizontal perpendicular for spreading streaks.
local WDIR = WIND_DIR.Magnitude > 0 and WIND_DIR.Unit or Vector3.new(1, 0, 0)
local WHORIZ = Vector3.new(WDIR.X, 0, WDIR.Z)
WHORIZ = WHORIZ.Magnitude > 0 and WHORIZ.Unit or Vector3.new(1, 0, 0)
local WPERP = Vector3.new(-WHORIZ.Z, 0, WHORIZ.X) -- 90° in the XZ plane

local function randRange(a: number, b: number): number
	return a + math.random() * (b - a)
end

-- A position somewhere across the whole band (used to seed streaks so it's populated instantly).
local function spreadPos(center: Vector3): Vector3
	return center
		+ WHORIZ * randRange(-RADIUS, RADIUS)
		+ WPERP * randRange(-RADIUS, RADIUS)
		+ Vector3.new(0, randRange(HEIGHT_MIN, HEIGHT_MAX), 0)
end

-- A position on the UPWIND edge (used when recycling, so the streak drifts across the band toward you).
local function upwindPos(center: Vector3): Vector3
	return center
		- WHORIZ * RADIUS
		+ WPERP * randRange(-RADIUS, RADIUS)
		+ Vector3.new(0, randRange(HEIGHT_MIN, HEIGHT_MAX), 0)
end

local function place(streak, pos: Vector3)
	streak.pos = pos
	streak.speed = SPEED * randRange(1 - SPEED_VAR, 1 + SPEED_VAR)
	streak.length = randRange(LENGTH_MIN, LENGTH_MAX)
	streak.part.Size = Vector3.new(THICK, THICK, streak.length)
	streak.part.Transparency = randRange(TRANSP_MIN, TRANSP_MAX)
	streak.part.CFrame = CFrame.lookAt(pos, pos + WDIR)
end

local function build()
	folder = Instance.new("Folder")
	folder.Name = "WindFX"
	folder.Parent = Workspace.CurrentCamera -- client-only, never replicated

	for _ = 1, COUNT do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = COLOR
		part.Parent = folder
		local streak = { part = part }
		table.insert(streaks, streak)
	end
end

local function rootOf()
	local char = localPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local seeded = false
local function onRender(dt: number)
	local root = rootOf()
	if not root then
		if seeded and folder then
			folder.Parent = nil -- no character (lobby / between runs): hide the streaks entirely
			seeded = false
		end
		return
	end
	if not seeded then
		folder.Parent = Workspace.CurrentCamera
		for _, s in streaks do
			place(s, spreadPos(root.Position))
		end
		seeded = true
	end

	local center = root.Position
	for _, s in streaks do
		s.pos += WDIR * (s.speed * dt)
		-- Recycle once it has drifted out of the band around the (possibly moving) player.
		local flat = Vector3.new(s.pos.X - center.X, 0, s.pos.Z - center.Z)
		if flat.Magnitude > RADIUS * 1.2 or math.abs(s.pos.Y - center.Y) > (HEIGHT_MAX - HEIGHT_MIN) + 12 then
			place(s, upwindPos(center))
		else
			s.part.CFrame = CFrame.lookAt(s.pos, s.pos + WDIR)
		end
	end
end

function WindController.Start()
	build()
	RunService.RenderStepped:Connect(onRender)
	print("[WindController] started")
end

return WindController
