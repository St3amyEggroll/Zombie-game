--!nonstrict
-- GunShopController.lua — ONLY the "NEW GUN UNLOCKED" showcase now: a top-center banner with the
-- spinning 3D gun (black-silhouette outline behind it) + name, on a plate that fades out at the sides.
-- CHANGED: the in-game GUNS panel + launcher are DELETED — weapons are equipped in the LOBBY, and the
-- hotbar (1 / 2) switches guns mid-run. This controller just celebrates fresh unlocks mid-run.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConfig = require(Shared.Config.WeaponConfig)
local UITheme = require(Shared.Modules.UITheme)
local Remotes = require(Shared.Modules.Remotes)

local SoundController = require(script.Parent.SoundController)

local GunShopController = {}

local localPlayer = Players.LocalPlayer

local owned = {} -- [weaponId] = true (tracked so a NEW id in LoadoutChanged = a fresh unlock)

function GunShopController.IsOpen(): boolean
	return false -- the panel is gone; kept so old callers never break
end

-- ===== NEW GUN UNLOCKED showcase ===== a top-center banner: spinning 3D gun (with a black outline
-- silhouette behind it) + name, on a soft plate that FADES OUT at the sides (no hard box).
local function showGunUnlock(id)
	local w = WeaponConfig[id]
	local template = ReplicatedStorage:FindFirstChild("GunDisplay")
	template = template and template:FindFirstChild(id)
	local host = localPlayer:WaitForChild("PlayerGui"):FindFirstChild("GunShop")
	if not host then
		return
	end

	local plate = Instance.new("Frame")
	plate.AnchorPoint = Vector2.new(0.5, 0)
	plate.Position = UDim2.new(0.5, 0, 0, 150)
	plate.Size = UDim2.fromOffset(520, 116)
	plate.BackgroundColor3 = UITheme.BLACK
	plate.BackgroundTransparency = 0.35
	plate.BorderSizePixel = 0
	plate.ZIndex = 5
	plate.Parent = host
	local fade = Instance.new("UIGradient") -- the plate dissolves at both sides instead of a hard outline
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.22, 0),
		NumberSequenceKeypoint.new(0.78, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = plate

	local cap = UITheme.Label(plate, nil, UITheme.Type.Caption, UITheme.GOLD, true)
	cap.AnchorPoint = Vector2.new(0.5, 0)
	cap.Position = UDim2.new(0.5, 60, 0, 22)
	cap.Size = UDim2.fromOffset(300, 16)
	cap.ZIndex = 6
	cap.Text = "NEW GUN UNLOCKED"

	local nm = UITheme.Title(plate, nil, UITheme.Type.Item, UITheme.TEXT)
	nm.AnchorPoint = Vector2.new(0.5, 0)
	nm.Position = UDim2.new(0.5, 60, 0, 44)
	nm.Size = UDim2.fromOffset(320, 30)
	nm.TextXAlignment = Enum.TextXAlignment.Center
	nm.ZIndex = 6
	nm.Text = string.upper((w and w.name) or id)

	-- Spinning 3D gun with an inflated black-silhouette clone behind it = the outline.
	local spinConn
	if template then
		local vp = Instance.new("ViewportFrame")
		vp.BackgroundTransparency = 1
		vp.AnchorPoint = Vector2.new(0.5, 0.5)
		vp.Position = UDim2.new(0.5, -170, 0.5, 0)
		vp.Size = UDim2.fromOffset(110, 110)
		vp.Ambient = Color3.fromRGB(170, 170, 170)
		vp.ZIndex = 6
		vp.Parent = plate
		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		cam.Parent = vp
		vp.CurrentCamera = cam

		local wrap = Instance.new("Model")
		local outline = template:Clone()
		for _, d in outline:GetDescendants() do
			if d:IsA("BasePart") then
				d.Size = d.Size * 1.1 -- inflated hull = the outline
				d.Color = Color3.new(0, 0, 0)
				d.Material = Enum.Material.SmoothPlastic
			elseif d:IsA("SpecialMesh") or d:IsA("Texture") or d:IsA("Decal") then
				d:Destroy()
			end
		end
		outline.Parent = wrap
		local body = template:Clone()
		body.Parent = wrap
		wrap.Parent = vp

		local cf, size = wrap:GetBoundingBox()
		wrap.WorldPivot = cf
		local dist = (size.Magnitude / 2) / math.tan(math.rad(15)) * 1.15 + 0.1
		cam.CFrame = CFrame.new(cf.Position + Vector3.new(0, dist * 0.18, dist), cf.Position)
		local ang = 0
		spinConn = game:GetService("RunService").RenderStepped:Connect(function(dt)
			ang += dt * math.rad(60)
			wrap:PivotTo(CFrame.new(cf.Position) * CFrame.Angles(0, ang, 0) * cf.Rotation)
		end)
	end

	SoundController.Play("GunEquip") -- (GunBought slot removed with the shop — unlocks ride the equip sound)
	task.delay(4.5, function()
		if spinConn then
			spinConn:Disconnect()
		end
		plate:Destroy()
	end)
end

function GunShopController.Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- The showcase's host layer (the gui keeps its old name — SpectateController's KEEP list knows it).
	local gui = Instance.new("ScreenGui")
	gui.Name = "GunShop"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.ShopModal
	gui.Parent = playerGui
	UITheme.Attach(gui, 560, 430) -- mobile: the unlock showcase fills the phone screen

	-- A gun that wasn't owned a moment ago = fresh unlock -> showcase it (skip the initial sync).
	Remotes.Get("LoadoutChanged").OnClientEvent:Connect(function(ownedList)
		if typeof(ownedList) ~= "table" then
			return
		end
		local before = owned
		owned = {}
		for _, id in ownedList do
			owned[id] = true
		end
		if next(before) ~= nil then
			for id in owned do
				if not before[id] then
					showGunUnlock(id)
					break
				end
			end
		end
	end)

	print("[GunShopController] started (unlock showcase only — the GUNS panel lives in the lobby)")
end

return GunShopController
