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

-- Plain stock third-person camera.
local function applyThirdPerson()
	localPlayer.CameraMode = Enum.CameraMode.Classic
	localPlayer.CameraMinZoomDistance = 0.5
	localPlayer.CameraMaxZoomDistance = 128
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.CameraOffset = Vector3.zero
	end
end

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

function CameraController.Start()
	applyThirdPerson()
	localPlayer.CharacterAdded:Connect(function()
		task.defer(applyThirdPerson)
	end)
	print("[CameraController] started (third-person)")
end

return CameraController
