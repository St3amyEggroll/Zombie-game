--!nonstrict
-- KillStreakController.lua — on-screen flair for chain kills. The server tracks the streak (kills WITHOUT
-- taking damage) and the cash multiplier and sends KillStreak(streak, multiplier). This shows an escalating
-- banner (STREAK -> ON FIRE -> RAMPAGE -> UNSTOPPABLE) and the current cash bonus.
--
-- NAMED-INSTANCE CONTRACT (optional): build a TextLabel named "KillStreakLabel" anywhere under PlayerGui
-- and this drives its .Text/.TextColor3. If you don't, a default centered banner is created so it's visible.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("UITheme"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")
local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local KillStreakController = {}

-- ===== TUNABLES ===== escalating tiers, highest threshold first.
local TIERS = {
	{ at = 15, color = Color3.fromRGB(255, 70, 70),  word = "UNSTOPPABLE" },
	{ at = 10, color = Color3.fromRGB(255, 140, 40), word = "RAMPAGE" },
	{ at = 6,  color = Color3.fromRGB(255, 210, 60), word = "ON FIRE" },
	{ at = 3,  color = Color3.fromRGB(120, 220, 255), word = "STREAK" },
}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local labelCache, builtLabel

local function findLabel()
	if labelCache and labelCache.Parent then
		return labelCache
	end
	for _, d in playerGui:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Name == "KillStreakLabel" then
			labelCache = d
			return d
		end
	end
	labelCache = nil
	return nil
end

-- The owner's KillStreakLabel if they styled one; otherwise a default centered banner.
local function ensureLabel()
	local found = findLabel()
	if found then
		return found
	end
	if builtLabel and builtLabel.Parent then
		return builtLabel
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "KillStreakHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local l = Instance.new("TextLabel")
	l.Name = "KillStreakLabel"
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.fromScale(0.5, 0.12)
	l.Size = UDim2.fromOffset(440, 56)
	l.BackgroundTransparency = 1
	l.FontFace = UITheme.TitleFace
	l.TextScaled = true
	l.TextStrokeTransparency = 0.4
	l.TextTransparency = 1
	l.Text = ""
	l.Parent = gui
	builtLabel = l
	return l
end

-- A UIScale child gives us a non-destructive "pop" that doesn't fight the owner's sizing.
local function getScale(label): UIScale
	local s = label:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = label
	end
	return s
end

local function tierFor(streak: number)
	for _, t in TIERS do
		if streak >= t.at then
			return t
		end
	end
	return nil
end

local function onKillStreak(streak: number, multiplier: number)
	local label = ensureLabel()
	if not label then
		return
	end
	if streak < GameConfig.KillStreakShowAt then
		label.TextTransparency = 1
		return
	end
	local tier = tierFor(streak) or TIERS[#TIERS]
	label.TextColor3 = tier.color
	label.Text = string.format("%s  x%d   (+%d%% cash)", tier.word, streak, math.floor((multiplier - 1) * 100 + 0.5))
	label.TextTransparency = 0

	local scale = getScale(label)
	scale.Scale = 1.25
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

function KillStreakController.Start()
	Remotes.Get("KillStreak").OnClientEvent:Connect(onKillStreak)
	print("[KillStreakController] started")
end

return KillStreakController
