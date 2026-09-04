--!nonstrict
-- TouchControlsController.lua — on-screen buttons for phones/tablets (launch pass: the mobile pass).
-- Keyboard/mouse players never see this. It builds when the device is touch-first — UITheme's rule:
-- touch AND (no mouse OR a short viewport) — so Studio's phone emulator shows it too.
--
--   FIRE   (hold)   right side, above Roblox's jump button. Hold = autos fire; tap = one semi-auto shot.
--   SPRINT (toggle) left of FIRE. Toggles the server sprint flag (stamina still rules; off on respawn).
--   USE             small, above SPRINT: the E interact (traps).
--
-- Autofire defaults ON on touch (AutoShootController), so FIRE is for players who want the control;
-- raw screen touches no longer pull the trigger on these devices (InputController.TOUCH_FIRST).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Modules.UITheme)

local InputController = require(script.Parent.InputController)

local TouchControlsController = {}

-- ===== TUNABLES =====
local FIRE_SIZE   = 96   -- px (logical; the hud scale shrinks it on phones)
local SPRINT_SIZE = 66
local USE_SIZE    = 54
local RIGHT_PAD   = 22   -- px in from the right screen edge
local FIRE_BOTTOM = 150  -- px up from the bottom edge (clears the default jump button)
local GAP         = 14   -- px between buttons

local localPlayer = Players.LocalPlayer

local function isTouchFirst(): boolean
	local cam = Workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
	return UserInputService.TouchEnabled and (not UserInputService.MouseEnabled or vp.Y < 600)
end

-- A round, studded, edged button with a one-word label. Returns the button.
local function roundButton(parent: Instance, name: string, size: number, label: string, textSize: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Size = UDim2.fromOffset(size, size)
	btn.BackgroundColor3 = UITheme.PANEL
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.FontFace = UITheme.TitleFace
	btn.TextSize = textSize
	btn.TextColor3 = UITheme.TEXT
	btn.Text = label
	btn:SetAttribute("NoClickSound", true)
	btn.Parent = parent
	UITheme.Corner(btn, size / 2)
	UITheme.Edge(btn, UITheme.BLACK, 2.5)
	UITheme.Studs(btn)
	local stroke = Instance.new("UIStroke")
	stroke.Color = UITheme.BLACK
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = btn
	return btn
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

function TouchControlsController.Start()
	if not isTouchFirst() then
		print("[TouchControlsController] skipped (not a touch-first device)")
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "TouchControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.Chrome
	gui.Parent = playerGui
	UITheme.Attach(gui, nil, nil, "hud") -- same scale as the HUD on phones

	-- ----- FIRE (hold) -----
	local fire = roundButton(gui, "Fire", FIRE_SIZE, "FIRE", 24)
	fire.Position = UDim2.new(1, -RIGHT_PAD, 1, -FIRE_BOTTOM)
	fire.BackgroundColor3 = Color3.fromRGB(150, 32, 24)
	local held: InputObject? = nil
	local function release()
		if held then
			held = nil
			fire.BackgroundColor3 = Color3.fromRGB(150, 32, 24)
			InputController.SetManualFire(false)
		end
	end
	fire.InputBegan:Connect(function(input)
		if isPress(input) and not held then
			held = input
			fire.BackgroundColor3 = Color3.fromRGB(224, 60, 40)
			InputController.SetManualFire(true)
		end
	end)
	-- Release on the SAME input object ending anywhere (a finger that slides off the button still lifts).
	UserInputService.InputEnded:Connect(function(input)
		if held and input == held then
			release()
		end
	end)
	UserInputService.WindowFocusReleased:Connect(release)

	-- ----- SPRINT (toggle) -----
	local sprint = roundButton(gui, "Sprint", SPRINT_SIZE, "RUN", 18)
	sprint.Position = UDim2.new(1, -RIGHT_PAD - FIRE_SIZE - GAP, 1, -FIRE_BOTTOM)
	local sprinting = false
	local function paintSprint()
		sprint.BackgroundColor3 = sprinting and UITheme.TOXIC or UITheme.PANEL
		sprint.TextColor3 = sprinting and UITheme.BLACK or UITheme.TEXT
	end
	sprint.Activated:Connect(function()
		sprinting = not sprinting
		paintSprint()
		InputController.SetSprint(sprinting)
	end)
	paintSprint()
	localPlayer.CharacterAdded:Connect(function()
		sprinting = false -- a fresh character starts walking (the server resets its flag too)
		paintSprint()
		release()
	end)

	-- ----- USE (E) -----
	local use = roundButton(gui, "Use", USE_SIZE, "USE", 15)
	use.Position = UDim2.new(1, -RIGHT_PAD - FIRE_SIZE - GAP - (SPRINT_SIZE - USE_SIZE) / 2, 1, -FIRE_BOTTOM - SPRINT_SIZE - GAP)
	use.Activated:Connect(function()
		InputController.Interact()
	end)

	print("[TouchControlsController] started (FIRE / RUN / USE)")
end

return TouchControlsController
