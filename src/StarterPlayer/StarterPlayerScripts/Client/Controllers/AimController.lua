--!nonstrict
-- AimController.lua — auto-aim. Your character automatically turns to face the CLOSEST zombie within the
-- forward arc (relative to where your mouse points), so shooting locks onto it. If no zombie is in front,
-- the character just faces the mouse direction.
--
-- THE LOCK RULE MIRRORS THE SERVER'S HIT RULE EXACTLY (CombatService.onFire): flat arc angle, reach
-- clamped to min(ArcRange, weapon.range) × range buff, and a line-of-sight ray that ignores zombies and
-- player bodies. If it locks here, the server can hit it — no locking onto zombies behind walls or past
-- the equipped weapon's range.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local GameConfig = require(SharedConfig:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedConfig:WaitForChild("WeaponConfig"))
local CameraController = require(script.Parent.CameraController)
-- (Buff draft removed — no client-side range buff anymore.)
local BuffController = { GetStat = function() return 0 end }

local AimController = {}

-- ===== TUNABLES =====
local TURN_SPEED = 16   -- higher = snappier lock-on
local STICKY     = 0.35 -- seconds to keep "having a target" after it leaves the cone (steadies the fire rate)

local localPlayer = Players.LocalPlayer
local currentTarget: BasePart? = nil -- the zombie we're locked onto this frame (nil = none); read by auto-shoot
local lastTarget: BasePart? = nil    -- most recent target, for the stickiness grace
local lastTargetTime = 0
local equippedWeapon = "pistol"      -- kept in sync by InputController (avoids a circular require)

function AimController.SetWeapon(weaponId: string)
	if WeaponConfig[weaponId] then
		equippedWeapon = weaponId
	end
end

-- The zombie root the auto-aim is currently locked onto, or nil. Used by auto-shoot to decide when to fire.
function AimController.GetTarget(): BasePart?
	if currentTarget and currentTarget.Parent then
		return currentTarget
	end
	-- Stickiness: a zombie briefly leaving the tight cone shouldn't stutter the fire rate — keep firing at
	-- the last target for a short grace while it's still alive.
	-- CHANGED: zombies are custom rigs with NO Humanoid — aliveness is the server-set ZDead attribute.
	if lastTarget and lastTarget.Parent and (os.clock() - lastTargetTime) < STICKY then
		if lastTarget.Parent:GetAttribute("ZDead") ~= true then
			return lastTarget
		end
	end
	return nil
end

-- Line-of-sight filter mirroring the server's: ignore zombies and EVERY player's character (bodies are
-- not cover — there's no friendly fire). Rebuilt per query because characters respawn.
local function losParamsNow(zombieFolder: Instance): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local exclude = { zombieFolder }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(exclude, pl.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	return params
end

-- Closest VISIBLE zombie within the equipped weapon's reach whose flat direction is within the arc of
-- `dir` (a flat unit vector). Same candidate rule as the server, then LOS-checked nearest-first.
local function findTargetRoot(fromPos: Vector3, dir: Vector3): BasePart?
	local folder = Workspace:FindFirstChild("Zombies")
	if not folder then
		return nil
	end
	local weapon = WeaponConfig[equippedWeapon]
	local dotThreshold = math.cos(math.rad(GameConfig.ArcDegrees * 0.5))
	local reach = math.min(GameConfig.ArcRange, (weapon and weapon.range) or GameConfig.ArcRange)
		* (1 + BuffController.GetStat("range")) -- Attack Range buff

	local cands = {}
	for _, model in folder:GetChildren() do
		-- CHANGED: custom zombies have no Humanoid — alive = ZDead attribute not set true by the server.
		local root = model:FindFirstChild("HumanoidRootPart") or (model:IsA("Model") and model.PrimaryPart)
		if root and model:GetAttribute("ZDead") ~= true then
			local to = root.Position - fromPos
			local dist = to.Magnitude
			if dist > 0.01 and dist <= reach then
				local flatTo = Vector3.new(to.X, 0, to.Z)
				if flatTo.Magnitude > 0.01 and flatTo.Unit:Dot(dir) >= dotThreshold then
					table.insert(cands, { root = root, dist = dist })
				end
			end
		end
	end
	table.sort(cands, function(a, b)
		return a.dist < b.dist
	end)

	-- Nearest-first, take the first with clear line of sight (usually one ray).
	local params = losParamsNow(folder)
	for _, c in cands do
		if not Workspace:Raycast(fromPos, c.root.Position - fromPos, params) then
			return c.root
		end
	end
	return nil
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

	-- Auto-aim: face the closest hittable zombie in the front arc; otherwise face the mouse direction.
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
	print("[AimController] started (auto-aim mirrors the server hit rule)")
end

return AimController
