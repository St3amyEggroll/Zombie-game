--!nonstrict
-- CameraController.lua — first-person + third-person toggle, and the authoritative aim solution.
-- GetAim() returns (origin, direction): origin is a point ON the player (so the server's origin-sanity
-- check passes), direction points exactly where the crosshair is aimed (camera ray → world target).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local CameraController = {}

-- ===== TUNABLES =====
local DEFAULT_MODE     = "first"   -- "first" | "third"
local TP_MIN_ZOOM      = 8         -- third-person zoom distance bounds
local TP_MAX_ZOOM      = 14
local TP_SHOULDER      = Vector3.new(1.75, 0.5, 0)  -- over-the-shoulder offset in third person
local MAX_AIM_DIST     = 1000      -- how far the aim ray reaches to find a target point

local localPlayer = Players.LocalPlayer
local mode: string = DEFAULT_MODE

-- ===== MODE =====
local function applyMode()
	if mode == "first" then
		localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
		localPlayer.CameraMinZoomDistance = 0.5
		localPlayer.CameraMaxZoomDistance = 0.5
	else
		localPlayer.CameraMode = Enum.CameraMode.Classic
		localPlayer.CameraMinZoomDistance = TP_MIN_ZOOM
		localPlayer.CameraMaxZoomDistance = TP_MAX_ZOOM
	end
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.CameraOffset = (mode == "third") and TP_SHOULDER or Vector3.zero
	end
end

function CameraController.SetMode(newMode: string)
	mode = (newMode == "third") and "third" or "first"
	applyMode()
end

function CameraController.Toggle()
	CameraController.SetMode(mode == "first" and "third" or "first")
end

function CameraController.GetMode(): string
	return mode
end

-- ===== AIM =====
-- Returns (origin: Vector3, direction: Vector3) or nil if the character isn't ready.
function CameraController.GetAim(): (Vector3?, Vector3?)
	local camera = Workspace.CurrentCamera
	local character = localPlayer.Character
	if not camera or not character then
		return nil, nil
	end
	local originPart = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not originPart then
		return nil, nil
	end

	-- Ray from the screen center → find the world point the crosshair is over.
	local vp = camera.ViewportSize
	local screenRay = camera:ViewportPointToRay(vp.X * 0.5, vp.Y * 0.5)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local hit = Workspace:Raycast(screenRay.Origin, screenRay.Direction * MAX_AIM_DIST, params)
	local aimPoint = hit and hit.Position or (screenRay.Origin + screenRay.Direction * MAX_AIM_DIST)

	local origin = originPart.Position
	local direction = aimPoint - origin
	if direction.Magnitude < 0.001 then
		direction = screenRay.Direction
	end
	return origin, direction.Unit
end

-- ===== LIFECYCLE =====
function CameraController.Start()
	applyMode()
	localPlayer.CharacterAdded:Connect(function()
		-- Re-apply on respawn (CameraOffset lives on the new humanoid).
		task.defer(applyMode)
	end)
	print("[CameraController] started (" .. mode .. " person)")
end

return CameraController
