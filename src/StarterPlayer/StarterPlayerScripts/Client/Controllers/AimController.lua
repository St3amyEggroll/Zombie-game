--!nonstrict
-- AimController.lua — auto-aim. Your character automatically turns to face the CLOSEST zombie within the
-- forward arc (relative to where your mouse points), so shooting locks onto it. If no zombie is in front,
-- the character just faces the mouse direction. The server uses the same closest-in-arc rule for the hit.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local CameraController = require(script.Parent.CameraController)
-- Buff stats (auto-aim reach). GUARDED: a missing/broken BuffController must never brick auto-aim.
local okBuff, BuffController = pcall(require, script.Parent.BuffController)
if not okBuff or type(BuffController) ~= "table" then
	BuffController = { GetStat = function() return 0 end }
end

local AimController = {}

-- ===== TUNABLES =====
local TURN_SPEED = 16   -- higher = snappier lock-on
local STICKY     = 0.35 -- seconds to keep "having a target" after it leaves the cone (steadies the fire rate)

local localPlayer = Players.LocalPlayer
local currentTarget: BasePart? = nil -- the zombie we're locked onto this frame (nil = none); read by auto-shoot
local lastTarget: BasePart? = nil    -- most recent target, for the stickiness grace
local lastTargetTime = 0

-- The zombie root the auto-aim is currently locked onto, or nil. Used by auto-shoot to decide when to fire.
function AimController.GetTarget(): BasePart?
	if currentTarget and currentTarget.Parent then
		return currentTarget
	end
	-- Stickiness: a zombie briefly leaving the tight cone shouldn't stutter the fire rate — keep firing at
	-- the last target for a short grace while it's still alive.
	if lastTarget and lastTarget.Parent and (os.clock() - lastTargetTime) < STICKY then
		local hum = lastTarget.Parent:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			return lastTarget
		end
	end
	return nil
end

-- Closest zombie within ArcRange whose direction is within the arc of `dir` (a flat unit vector).
local function findTargetRoot(fromPos: Vector3, dir: Vector3): BasePart?
	local folder = Workspace:FindFirstChild("Zombies")
	if not folder then
		return nil
	end
	local dotThreshold = math.cos(math.rad(GameConfig.ArcDegrees * 0.5))
	local reach = GameConfig.ArcRange * (1 + BuffController.GetStat("range")) -- Attack Range buff
	local best, bestDist = nil, math.huge
	for _, model in folder:GetChildren() do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			local to = root.Position - fromPos
			local dist = to.Magnitude
			if dist > 0.01 and dist <= reach and dist < bestDist then
				local flatTo = Vector3.new(to.X, 0, to.Z)
				if flatTo.Magnitude > 0.01 and flatTo.Unit:Dot(dir) >= dotThreshold then
					best, bestDist = root, dist
				end
			end
		end
	end
	return best
end

local function onRender(dt: number)
	currentTarget = nil -- cleared each frame; set below only when we actually have a live target
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
	flat = flat.Unit

	-- Auto-aim: face the closest zombie in the front arc; otherwise face the mouse direction.
	local faceDir = flat
	local targetRoot = findTargetRoot(hrp.Position, flat)
	currentTarget = targetRoot
	if targetRoot then
		lastTarget = targetRoot
		lastTargetTime = os.clock()
		local td = targetRoot.Position - hrp.Position
		td = Vector3.new(td.X, 0, td.Z)
		if td.Magnitude > 0.01 then
			faceDir = td.Unit
		end
	end

	humanoid.AutoRotate = false
	local goal = CFrame.lookAt(hrp.Position, hrp.Position + faceDir)
	hrp.CFrame = hrp.CFrame:Lerp(goal, math.clamp(dt * TURN_SPEED, 0, 1))
end

function AimController.Start()
	RunService.RenderStepped:Connect(onRender)
	print("[AimController] started (auto-aim to closest zombie)")
end

return AimController
