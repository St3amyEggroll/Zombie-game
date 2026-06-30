--!nonstrict
-- CrosshairController.lua — a dynamic crosshair that sits at your cursor and breathes with your accuracy:
-- it widens when you MOVE or FIRE and tightens back when you stand still, so your spread reads at a glance.
-- All client-side. Four lines + an optional center dot; restyle the numbers in the TUNABLES below.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local InputController = require(script.Parent.InputController)

local CrosshairController = {}

-- ===== TUNABLES =====
local COLOR       = Color3.fromRGB(255, 255, 255)
local THICKNESS   = 2     -- line thickness (px)
local LENGTH      = 8     -- length of each line (px)
local BASE_GAP    = 4     -- gap from center when perfectly still (px)
local MAX_GAP     = 26    -- hard cap on the gap (px)
local MOVE_SPREAD = 12    -- extra gap at full move speed
local FIRE_KICK   = 7     -- extra gap added per shot
local FIRE_DECAY  = 26    -- how fast the fire spread settles back (px/sec)
local SMOOTH      = 18    -- how snappy the gap eases toward its target (higher = snappier)
local REF_SPEED   = 16    -- move speed treated as "full spread" (base walk speed)
local SHOW_DOT    = true  -- draw a small center dot

local localPlayer = Players.LocalPlayer
local holder
local lines = {}
local fireSpread = 0
local gap = BASE_GAP

local function newLine(name: string, w: number, h: number)
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = COLOR
	f.Size = UDim2.fromOffset(w, h)
	f.Parent = holder
	return f
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Crosshair"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(0, 0) -- a zero-size anchor at the cursor; lines position relative to it
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	lines.top = newLine("Top", THICKNESS, LENGTH)
	lines.bottom = newLine("Bottom", THICKNESS, LENGTH)
	lines.left = newLine("Left", LENGTH, THICKNESS)
	lines.right = newLine("Right", LENGTH, THICKNESS)

	if SHOW_DOT then
		local dot = newLine("Dot", THICKNESS, THICKNESS)
		dot.Position = UDim2.fromOffset(0, 0)
	end
end

local function update(dt: number)
	if not holder then
		return
	end
	-- Sit at the cursor (aim is cursor-based in this game).
	local m = UserInputService:GetMouseLocation()
	holder.Position = UDim2.fromOffset(m.X, m.Y)

	-- Spread = base + movement + recent fire (decaying).
	fireSpread = math.max(0, fireSpread - FIRE_DECAY * dt)
	local moveGap = 0
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		local v = hrp.AssemblyLinearVelocity
		local speed = Vector3.new(v.X, 0, v.Z).Magnitude
		moveGap = math.clamp(speed / REF_SPEED, 0, 1.5) * MOVE_SPREAD
	end
	local target = math.min(MAX_GAP, BASE_GAP + moveGap + fireSpread)
	gap = gap + (target - gap) * math.clamp(SMOOTH * dt, 0, 1)

	local off = gap + LENGTH * 0.5
	lines.top.Position = UDim2.fromOffset(0, -off)
	lines.bottom.Position = UDim2.fromOffset(0, off)
	lines.left.Position = UDim2.fromOffset(-off, 0)
	lines.right.Position = UDim2.fromOffset(off, 0)
end

function CrosshairController.Start()
	build()
	InputController.Fired:Connect(function()
		fireSpread = math.min(MAX_GAP, fireSpread + FIRE_KICK)
	end)
	RunService.RenderStepped:Connect(update)
	print("[CrosshairController] started")
end

return CrosshairController
