--!nonstrict
-- DamageNumberController.lua — floating damage numbers that pop off zombies when you hit them.
-- White on a normal hit, yellow + bigger on a headshot, red + biggest on a kill. The number is the exact
-- damage the SERVER dealt (it rides on HitConfirmed), so it also visualizes range falloff: the same gun
-- prints smaller numbers on far zombies than point-blank ones.

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("UITheme"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local DamageNumberController = {}

-- ===== TUNABLES =====
local RISE       = 4      -- studs the number floats upward over its life
local LIFE       = 0.7    -- seconds before it fades out
local MAX_TILT   = 35     -- degrees: each number pops out at a random tilt within +/- this
local HIT_COLOR  = Color3.fromRGB(255, 255, 255)
local HEAD_COLOR = Color3.fromRGB(255, 221, 90)
local KILL_COLOR = Color3.fromRGB(255, 70, 70)

local anchorFolder

local function spawnNumber(pos: Vector3, text: string, color: Color3, scale: number)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	-- jitter a little so stacked hits don't overlap into one blob
	part.CFrame = CFrame.new(pos + Vector3.new(math.random(-8, 8) / 10, 1.5, math.random(-8, 8) / 10))
	part.Parent = anchorFolder

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(80 * scale, 40 * scale)
	bb.AlwaysOnTop = true
	bb.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Rotation = math.random(-MAX_TILT, MAX_TILT) -- random tilt so each number pops out cocked
	label.FontFace = UITheme.TitleFace
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = bb

	TweenService:Create(part, TweenInfo.new(LIFE), { CFrame = part.CFrame + Vector3.new(0, RISE, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(LIFE), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(part, LIFE)
end

local CRIT_COLOR = Color3.fromRGB(255, 150, 40) -- critical hits pop ORANGE

local function onHitConfirmed(position: Vector3, isHeadshot: boolean, hitHumanoid: boolean, killed: boolean, damage: number?, isCrit: boolean?)
	if not hitHumanoid or not damage or damage <= 0 then
		return
	end
	local color, scale = HIT_COLOR, 1
	if killed then
		color, scale = KILL_COLOR, 1.4
	elseif isCrit then
		color, scale = CRIT_COLOR, 1.3
	elseif isHeadshot then
		color, scale = HEAD_COLOR, 1.25
	end
	spawnNumber(position, tostring(damage), color, scale)
end

function DamageNumberController.Start()
	anchorFolder = Instance.new("Folder")
	anchorFolder.Name = "DamageNumbers"
	anchorFolder.Parent = Workspace.CurrentCamera -- client-only, never replicated

	Remotes.Get("HitConfirmed").OnClientEvent:Connect(onHitConfirmed)
	print("[DamageNumberController] started")
end

return DamageNumberController
