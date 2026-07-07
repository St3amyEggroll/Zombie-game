--!nonstrict
-- UIFocus.lua — a subtle "lean back" when a UI panel opens: eases the camera FOV out a few degrees while
-- any panel is open, eases it back when the last one closes. Refcounted, so overlapping panels are fine.
-- Call UIFocus.Open() when a panel shows and UIFocus.Close() when it hides (always pair them).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UIFocus = {}

-- ===== TUNABLES =====
local FOV_PUSH = 6      -- degrees the FOV eases OUT while a panel is open
local EASE = 6          -- higher = snappier easing

local openCount = 0
local baseFov = nil     -- captured the first time a panel opens (respects whatever the camera runs at)
local looping = false

local function ensureLoop()
	if looping then
		return
	end
	looping = true
	RunService.RenderStepped:Connect(function(dt)
		local cam = Workspace.CurrentCamera
		if not cam or baseFov == nil then
			return
		end
		local target = (openCount > 0) and (baseFov + FOV_PUSH) or baseFov
		local a = math.clamp(dt * EASE, 0, 1)
		local cur = cam.FieldOfView
		if math.abs(cur - target) > 0.05 then
			cam.FieldOfView = cur + (target - cur) * a
		elseif openCount == 0 then
			cam.FieldOfView = baseFov -- settle exactly, then idle
		end
	end)
end

function UIFocus.Open()
	local cam = Workspace.CurrentCamera
	if baseFov == nil and cam then
		baseFov = cam.FieldOfView
	end
	openCount += 1
	ensureLoop()
end

function UIFocus.Close()
	openCount = math.max(0, openCount - 1)
end

return UIFocus
