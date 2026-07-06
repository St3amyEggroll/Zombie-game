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
				e.model:PivotTo(e.base * CFrame.Angles(0, e.ang, 0))
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

	if spin ~= false then
		table.insert(spinning, { vp = vp, model = model, base = cf, ang = math.random() * math.pi * 2 })
		startLoop()
	end
	return vp
end

return GunViewport
