--!nonstrict
-- AimController.lua — turns your character to face wherever the mouse points (twin-stick style), so the
-- character always points the way you aim. The server uses the same aim direction for the arc hit, so
-- "face the mouse" and "shoot the mouse direction" stay in sync.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CameraController = require(script.Parent.CameraController)

local AimController = {}

-- ===== TUNABLES =====
local TURN_SPEED = 14 -- higher = snappier turn toward the cursor

local localPlayer = Players.LocalPlayer

local function onRender(dt: number)
	local character = localPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp or humanoid.Health <= 0 or humanoid.Sit then
		return
	end

	local _, dir = CameraController.GetAim()
	if not dir then
		return
	end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.01 then
		return
	end

	-- We drive facing ourselves, so turn off the Humanoid's own move-direction rotation (lets you strafe).
	humanoid.AutoRotate = false
	local goal = CFrame.lookAt(hrp.Position, hrp.Position + flat)
	hrp.CFrame = hrp.CFrame:Lerp(goal, math.clamp(dt * TURN_SPEED, 0, 1))
end

function AimController.Start()
	RunService.RenderStepped:Connect(onRender)
	print("[AimController] started (character faces the cursor)")
end

return AimController
