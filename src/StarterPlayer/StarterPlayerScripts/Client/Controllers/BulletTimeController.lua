--!nonstrict
-- BulletTimeController.lua — the final kill of a wave gets a brief cinematic: the camera pushes in on the
-- dying zombie, the FOV punches, and the screen desaturates for a "slow-mo" beat. All client-side and
-- self-restoring (the camera always hands control back even if something goes wrong).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local BulletTimeController = {}

-- ===== TUNABLES =====
local DURATION   = 0.75   -- seconds the slow-mo beat lasts
local PUNCH_FOV   = 48    -- field of view at the closest point (lower = more zoom)
local DESAT       = -0.7  -- saturation during the beat (-1 = grayscale)

local localPlayer = Players.LocalPlayer
local active = false
local pushTween

local function trigger(pos: Vector3)
	if active or typeof(pos) ~= "Vector3" then
		return
	end
	active = true
	local cam = Workspace.CurrentCamera

	-- Slow-mo colour grade.
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "BulletTimeCC"
	cc.Saturation = 0
	cc.Contrast = 0.1
	cc.Parent = Lighting
	TweenService:Create(cc, TweenInfo.new(0.12), { Saturation = DESAT }):Play()

	-- Camera push-in toward the kill (only if we have a body to anchor the framing on).
	local savedType = cam.CameraType
	local savedFOV = cam.FieldOfView
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		local eye = hrp.Position + Vector3.new(0, 2, 0)
		local flat = pos - eye
		flat = Vector3.new(flat.X, 0, flat.Z)
		local dir = flat.Magnitude > 0.1 and flat.Unit or cam.CFrame.LookVector
		local startPos = pos - dir * 18 + Vector3.new(0, 7, 0)
		local endPos = pos - dir * 9 + Vector3.new(0, 4, 0)
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(startPos, pos)
		pushTween = TweenService:Create(cam, TweenInfo.new(DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.lookAt(endPos, pos),
			FieldOfView = PUNCH_FOV,
		})
		pushTween:Play()
	end

	-- Restore everything after the beat.
	task.delay(DURATION, function()
		if pushTween then
			pushTween:Cancel()
			pushTween = nil
		end
		cam.CameraType = savedType -- hand the camera back to the player view
		TweenService:Create(cam, TweenInfo.new(0.2), { FieldOfView = savedFOV }):Play()
		local fade = TweenService:Create(cc, TweenInfo.new(0.25), { Saturation = 0 })
		fade:Play()
		fade.Completed:Connect(function()
			cc:Destroy()
		end)
		active = false
	end)
end

function BulletTimeController.Start()
	Remotes.Get("BulletTime").OnClientEvent:Connect(trigger)
	print("[BulletTimeController] started")
end

return BulletTimeController
