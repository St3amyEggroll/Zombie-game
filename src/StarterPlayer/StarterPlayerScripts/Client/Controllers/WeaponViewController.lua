--!nonstrict
-- WeaponViewController.lua — the first-person viewmodel: gun on screen, recoil kick, muzzle flash.
-- Purely cosmetic/client-side; it never affects damage. Works with a placeholder block out of the
-- box, and upgrades automatically when you provide a real model.
--
-- MODEL CONTRACT (when you build guns): put a Model at
--   ReplicatedStorage > Assets > Viewmodels > <weaponId>
-- with a PrimaryPart set, and (optionally) an Attachment named "Muzzle" where the flash spawns.
-- No model? A grey placeholder block is used so the system still works.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InputController = require(script.Parent.InputController)

local WeaponViewController = {}

-- ===== TUNABLES =====
local VIEW_OFFSET    = CFrame.new(1.1, -1.2, -2.0)            -- gun position relative to the camera
local RECOIL_KICK    = CFrame.new(0, 0.04, 0.18) * CFrame.Angles(math.rad(-4), 0, 0) -- per shot
local RECOIL_RECOVER = 12                                      -- how fast recoil settles (higher = snappier)
local MUZZLE_FLASH_TIME = 0.045
local MAX_RECOIL_BACK = 0.9                                    -- clamp accumulated recoil push

local localPlayer = Players.LocalPlayer

-- ===== STATE =====
local CameraController
local currentWeaponId: string? = nil
local viewmodel: Model? = nil
local muzzleAttachment: Attachment? = nil
local flashLight: PointLight? = nil
local flashPart: BasePart? = nil
local recoilCF = CFrame.identity
local flashUntil = 0

-- ===== BUILD =====
local function destroyViewmodel()
	if viewmodel then
		viewmodel:Destroy()
		viewmodel = nil
	end
	muzzleAttachment = nil
	flashLight = nil
	flashPart = nil
end

local function findViewmodelAsset(weaponId: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild("Viewmodels")
	local model = folder and folder:FindFirstChild(weaponId)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function buildPlaceholder(): Model
	local model = Instance.new("Model")
	model.Name = "PlaceholderViewmodel"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(0.4, 0.5, 1.6)
	body.Color = Color3.fromRGB(60, 60, 65)
	body.Material = Enum.Material.Metal
	body.Parent = model

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -0.9)
	muzzle.Parent = body

	model.PrimaryPart = body
	return model
end

local function prepViewmodel(model: Model)
	-- Make every part render-only: no collision, invisible to raycasts, no physics drift.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Massless = true
		end
	end
	if not model.PrimaryPart then
		local first = model:FindFirstChildWhichIsA("BasePart")
		model.PrimaryPart = first
	end

	-- Muzzle attachment (or synthesize one at the front of the primary part).
	muzzleAttachment = model:FindFirstChild("Muzzle", true)
	if not (muzzleAttachment and muzzleAttachment:IsA("Attachment")) then
		local att = Instance.new("Attachment")
		att.Name = "Muzzle"
		att.Position = Vector3.new(0, 0, -(model.PrimaryPart and model.PrimaryPart.Size.Z * 0.5 or 1))
		att.Parent = model.PrimaryPart
		muzzleAttachment = att
	end

	-- Flash visuals parented at the muzzle.
	local light = Instance.new("PointLight")
	light.Name = "MuzzleFlash"
	light.Color = Color3.fromRGB(255, 220, 140)
	light.Range = 8
	light.Brightness = 0
	light.Enabled = false
	light.Parent = muzzleAttachment
	flashLight = light

	local fp = Instance.new("Part")
	fp.Name = "FlashPart"
	fp.Shape = Enum.PartType.Ball
	fp.Size = Vector3.new(0.35, 0.35, 0.35)
	fp.Color = Color3.fromRGB(255, 230, 160)
	fp.Material = Enum.Material.Neon
	fp.Anchored = true
	fp.CanCollide = false
	fp.CanQuery = false
	fp.CanTouch = false
	fp.CastShadow = false
	fp.Transparency = 1
	fp.Parent = model
	flashPart = fp
end

local function buildViewmodel(weaponId: string)
	destroyViewmodel()
	local asset = findViewmodelAsset(weaponId)
	local model = asset and asset:Clone() or buildPlaceholder()
	prepViewmodel(model)
	model.Parent = Workspace.CurrentCamera
	viewmodel = model
	currentWeaponId = weaponId
end

-- ===== EFFECTS =====
local function onFired(_weaponId: string)
	-- Recoil kick (accumulate, but stop pushing once we've reached the clamp).
	if recoilCF.Position.Z < MAX_RECOIL_BACK then
		recoilCF = recoilCF * RECOIL_KICK
	end
	-- Muzzle flash on.
	flashUntil = os.clock() + MUZZLE_FLASH_TIME
	if flashLight then
		flashLight.Enabled = true
		flashLight.Brightness = 5
	end
end

-- ===== PER-FRAME =====
local function onRenderStep(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	-- Rebuild if the equipped weapon changed (or the viewmodel was lost on respawn).
	local equipped = InputController.GetEquipped()
	if equipped ~= currentWeaponId or not (viewmodel and viewmodel.Parent) then
		buildViewmodel(equipped)
	end
	if not viewmodel or not viewmodel.PrimaryPart then
		return
	end

	-- Decay recoil toward rest.
	recoilCF = recoilCF:Lerp(CFrame.identity, math.clamp(dt * RECOIL_RECOVER, 0, 1))

	local targetCF = camera.CFrame * VIEW_OFFSET * recoilCF
	viewmodel:PivotTo(targetCF)

	-- Position flash at the muzzle.
	if flashPart and muzzleAttachment then
		flashPart.CFrame = muzzleAttachment.WorldCFrame
	end

	-- Flash timing.
	local flashing = os.clock() < flashUntil
	if flashLight then
		flashLight.Enabled = flashing
	end
	if flashPart then
		flashPart.Transparency = flashing and 0.2 or 1
	end

	-- Hide the whole viewmodel in third person.
	local visible = (not CameraController) or CameraController.GetMode() == "first"
	for _, d in viewmodel:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = visible and 0 or 1
		end
	end
end

-- ===== LIFECYCLE =====
function WeaponViewController.Start()
	CameraController = require(script.Parent.CameraController)
	InputController.Fired:Connect(onFired)

	-- Rebuild cleanly each spawn (CurrentCamera changes / character resets).
	localPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			currentWeaponId = nil
			destroyViewmodel()
		end)
	end)

	RunService.RenderStepped:Connect(onRenderStep)
	print("[WeaponViewController] started")
end

return WeaponViewController
