--!nonstrict
-- GunViewport.lua — spinning 3D gun displays for the UI. The server publishes sanitized clones of every
-- weapon model into ReplicatedStorage > GunDisplay (WeaponModelService does this at boot); this module
-- builds a ViewportFrame around one and slowly spins it. One shared RenderStepped drives every live
-- viewport; entries clean themselves up when their frame is destroyed (grids re-render by clearing
-- children, so no manual disposal needed).
--
--   local vp = GunViewport.Create(weaponId, spin)  -- returns a ViewportFrame, or nil if no model exists
--   vp.Size / Position / AnchorPoint are the caller's to set; background is transparent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GunViewport = {}

-- ===== TUNABLES =====
local SPIN_SPEED = math.rad(45)  -- degrees/sec the gun turns
local CAM_FOV    = 30            -- narrow FOV = less fisheye on long guns
local CAM_PITCH  = 0.22          -- how far above the gun the camera sits (fraction of distance)
local FIT_SLACK  = 1.12          -- zoom-out margin around the bounding box

-- DISPLAY ORIENTATION: how the gun is posed in the card/hotbar.
--   TILT     = a global upward tilt (degrees) so every gun sits at a cool angle instead of dead-flat.
--   BASE_YAW = a global spin-to-side (degrees) — the game place publishes its gun models pointing at the
--              camera, so this turns ALL of them side-on. (The lobby publishes them differently; it has its
--              own copy of these numbers.)
--   DISP_YAW = per-gun EXTRA yaw for any single gun still facing wrong after BASE_YAW. Empty until needed.
local TILT     = 45
local BASE_YAW = 90
local DISP_YAW = {}

-- Build the display rotation for one gun: reorient it side-on, then tilt it up.
local function displayRot(weaponId: string, builtRot: CFrame): CFrame
	return CFrame.Angles(0, 0, math.rad(TILT))
		* CFrame.Angles(0, math.rad(BASE_YAW + (DISP_YAW[weaponId] or 0)), 0)
		* builtRot
end

local spinning = {} -- { {vp, model, base, ang} }
local loopStarted = false

local function startLoop()
	if loopStarted then
		return
	end
	loopStarted = true
	RunService.RenderStepped:Connect(function(dt)
		for i = #spinning, 1, -1 do
			local e = spinning[i]
			if not e.vp.Parent then
				table.remove(spinning, i)
			elseif e.vp.Visible then
				e.ang += dt * SPIN_SPEED
				-- Yaw around WORLD up at the pivot point (base * Angles spun around the MODEL's local Y,
				-- which flipped guns built lying flat).
				e.model:PivotTo(CFrame.new(e.pos) * CFrame.Angles(0, e.ang, 0) * e.rot)
			end
		end
	end)
end

function GunViewport.Create(weaponId: string, spin: boolean?, folderName: string?)
	local folder = ReplicatedStorage:FindFirstChild(folderName or "GunDisplay")
	local template = folder and folder:FindFirstChild(weaponId)
	if not template then
		return nil
	end

	local vp = Instance.new("ViewportFrame")
	vp.Name = "GunViewport"
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromRGB(160, 160, 160)
	vp.LightColor = Color3.fromRGB(235, 235, 220)
	vp.LightDirection = Vector3.new(-0.4, -1, -0.4)

	local model = template:Clone()
	model.Parent = vp

	local cam = Instance.new("Camera")
	cam.FieldOfView = CAM_FOV
	cam.Parent = vp
	vp.CurrentCamera = cam

	local cf, size = model:GetBoundingBox()
	model.WorldPivot = cf -- spin around the true center, not wherever the pivot happened to be
	local dist = (size.Magnitude / 2) / math.tan(math.rad(CAM_FOV / 2)) * FIT_SLACK + 0.1
	cam.CFrame = CFrame.new(cf.Position + Vector3.new(0, dist * CAM_PITCH, dist), cf.Position)

	-- GUNS get the side-on + tilt pose; CRATES (CrateDisplay) keep their built rotation — the gun yaw
	-- was turning crates sideways.
	local isGun = (folderName or "GunDisplay") == "GunDisplay"
	local dispRot = isGun and displayRot(weaponId, cf.Rotation) or cf.Rotation
	if spin ~= false then
		table.insert(spinning, { vp = vp, model = model, pos = cf.Position, rot = dispRot, ang = math.random() * math.pi * 2 })
		startLoop()
	else
		model:PivotTo(CFrame.new(cf.Position) * dispRot) -- static: pose it once
	end
	return vp
end

return GunViewport
