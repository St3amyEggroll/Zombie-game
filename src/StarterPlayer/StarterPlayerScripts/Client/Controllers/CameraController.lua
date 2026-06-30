--!nonstrict
-- CameraController.lua — third-person camera + the authoritative aim solution for shooting.
-- (First person was removed.) GetAim() returns (origin, direction): origin is a point ON the player (so
-- the server's origin-sanity check passes), direction points exactly where the crosshair is aimed.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local CameraController = {}

-- ===== TUNABLES =====
local MAX_AIM_DIST = 1000 -- how far the aim ray reaches to find a target point

local localPlayer = Players.LocalPlayer
local mouse = localPlayer:GetMouse()

-- Third-person camera. Min-zoom is kept back so you can't scroll into first person.
local function applyThirdPerson()
	localPlayer.CameraMode = Enum.CameraMode.Classic
	localPlayer.CameraMinZoomDistance = 7   -- > ~1 so the camera never enters first person
	localPlayer.CameraMaxZoomDistance = 128
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.CameraOffset = Vector3.zero
	end
end

-- Returns (origin: Vector3, direction: Vector3) or nil if the character isn't ready.
-- Aims THROUGH THE MOUSE CURSOR (so it works in third person, where the mouse is free) rather than the
-- screen center. origin is on the player (passes the server's origin check); direction points at the cursor.
function CameraController.GetAim(): (Vector3?, Vector3?)
	local character = localPlayer.Character
	if not character then
		return nil, nil
	end
	local originPart = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not originPart then
		return nil, nil
	end

	local unitRay = mouse.UnitRay -- ray from the camera through the cursor (handles the GUI inset)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local hit = Workspace:Raycast(unitRay.Origin, unitRay.Direction * MAX_AIM_DIST, params)
	local aimPoint = hit and hit.Position or (unitRay.Origin + unitRay.Direction * MAX_AIM_DIST)

	local origin = originPart.Position
	local direction = aimPoint - origin
	if direction.Magnitude < 0.001 then
		direction = unitRay.Direction
	end
	return origin, direction.Unit
end

function CameraController.Start()
	applyThirdPerson()
	localPlayer.CharacterAdded:Connect(function()
		task.defer(applyThirdPerson)
	end)
	print("[CameraController] started (third-person)")
end

return CameraController
