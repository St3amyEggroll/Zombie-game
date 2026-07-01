--!nonstrict
-- ReviveController.lua — the client side of down/revive:
--   * YOU are downed  -> full-width banner ("YOU'RE DOWN") with the bleedout countdown / revive progress.
--   * a TEAMMATE is downed nearby -> "Hold E — Revive <name>" prompt + progress bar while you hold E.
-- Server (PlayerStateService) owns all the rules; this only renders + sends the hold intent.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")
local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local ReviveController = {}

-- ===== STYLE (shared design system) =====
local COL_PANEL    = Color3.fromRGB(22, 24, 30)
local COL_TEXT     = Color3.fromRGB(238, 240, 245)
local COL_TEXT_DIM = Color3.fromRGB(150, 156, 168)
local COL_ACCENT   = Color3.fromRGB(87, 196, 116)
local COL_DANGER   = Color3.fromRGB(224, 82, 82)
local COL_TRACK    = Color3.fromRGB(40, 44, 54)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local downed: { [number]: boolean } = {} -- userId -> is downed
local selfDownedEndsAt = 0               -- os.clock() our own bleedout ends (client-side countdown)
local selfReviveFrac = 0                 -- someone reviving US: 0..1
local holdTarget: Player? = nil          -- the downed teammate our prompt points at
local holding = false                    -- E currently held on holdTarget
local holdFrac = 0                       -- our revive progress on holdTarget: 0..1

local selfBanner, selfTitle, selfSub, selfFill
local prompt, promptText, promptFill

local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ReviveHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9
	gui.Parent = playerGui

	-- "YOU'RE DOWN" banner (center, above the middle).
	selfBanner = Instance.new("Frame")
	selfBanner.AnchorPoint = Vector2.new(0.5, 0.5)
	selfBanner.Position = UDim2.new(0.5, 0, 0.32, 0)
	selfBanner.Size = UDim2.fromOffset(340, 86)
	selfBanner.BackgroundColor3 = COL_PANEL
	selfBanner.BackgroundTransparency = 0.08
	selfBanner.BorderSizePixel = 0
	selfBanner.Visible = false
	selfBanner.Parent = gui
	corner(selfBanner, 12)
	local bs = Instance.new("UIStroke")
	bs.Color = COL_DANGER
	bs.Transparency = 0.35
	bs.Thickness = 1.5
	bs.Parent = selfBanner

	selfTitle = Instance.new("TextLabel")
	selfTitle.Position = UDim2.fromOffset(0, 10)
	selfTitle.Size = UDim2.new(1, 0, 0, 24)
	selfTitle.BackgroundTransparency = 1
	selfTitle.Font = Enum.Font.GothamBlack
	selfTitle.TextSize = 20
	selfTitle.TextColor3 = COL_DANGER
	selfTitle.Text = "YOU'RE DOWN"
	selfTitle.Parent = selfBanner

	selfSub = Instance.new("TextLabel")
	selfSub.Position = UDim2.fromOffset(0, 36)
	selfSub.Size = UDim2.new(1, 0, 0, 18)
	selfSub.BackgroundTransparency = 1
	selfSub.Font = Enum.Font.GothamBold
	selfSub.TextSize = 13
	selfSub.TextColor3 = COL_TEXT_DIM
	selfSub.Text = ""
	selfSub.Parent = selfBanner

	local track = Instance.new("Frame")
	track.Position = UDim2.new(0, 20, 1, -22)
	track.Size = UDim2.new(1, -40, 0, 10)
	track.BackgroundColor3 = COL_TRACK
	track.BorderSizePixel = 0
	track.Parent = selfBanner
	corner(track, 5)
	selfFill = Instance.new("Frame")
	selfFill.Size = UDim2.fromScale(0, 1)
	selfFill.BackgroundColor3 = COL_ACCENT
	selfFill.BorderSizePixel = 0
	selfFill.Parent = track
	corner(selfFill, 5)

	-- Revive prompt (bottom-center, above the hotbar area).
	prompt = Instance.new("Frame")
	prompt.AnchorPoint = Vector2.new(0.5, 1)
	prompt.Position = UDim2.new(0.5, 0, 1, -90)
	prompt.Size = UDim2.fromOffset(280, 52)
	prompt.BackgroundColor3 = COL_PANEL
	prompt.BackgroundTransparency = 0.1
	prompt.BorderSizePixel = 0
	prompt.Visible = false
	prompt.Parent = gui
	corner(prompt, 10)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(255, 255, 255)
	pStroke.Transparency = 0.92
	pStroke.Parent = prompt

	promptText = Instance.new("TextLabel")
	promptText.Position = UDim2.fromOffset(0, 7)
	promptText.Size = UDim2.new(1, 0, 0, 18)
	promptText.BackgroundTransparency = 1
	promptText.Font = Enum.Font.GothamBold
	promptText.TextSize = 14
	promptText.TextColor3 = COL_TEXT
	promptText.Text = ""
	promptText.Parent = prompt

	local pTrack = Instance.new("Frame")
	pTrack.Position = UDim2.new(0, 16, 1, -18)
	pTrack.Size = UDim2.new(1, -32, 0, 8)
	pTrack.BackgroundColor3 = COL_TRACK
	pTrack.BorderSizePixel = 0
	pTrack.Parent = prompt
	corner(pTrack, 4)
	promptFill = Instance.new("Frame")
	promptFill.Size = UDim2.fromScale(0, 1)
	promptFill.BackgroundColor3 = COL_ACCENT
	promptFill.BorderSizePixel = 0
	promptFill.Parent = pTrack
	corner(promptFill, 4)
end

local function stopHolding()
	if holding then
		holding = false
		holdFrac = 0
		Remotes.Get("Revive"):FireServer(holdTarget and holdTarget.UserId or 0, false)
	end
end

-- The nearest downed teammate within prompt range (slightly under the server's ReviveRange).
local function nearestDowned(): Player?
	local myRoot = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	if not myRoot then
		return nil
	end
	local best, bestDist = nil, GameConfig.ReviveRange
	for _, pl in Players:GetPlayers() do
		if pl ~= localPlayer and downed[pl.UserId] then
			local root = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
			if root then
				local d = (root.Position - myRoot.Position).Magnitude
				if d <= bestDist then
					best, bestDist = pl, d
				end
			end
		end
	end
	return best
end

local function onRender()
	-- Self-downed banner.
	if downed[localPlayer.UserId] then
		selfBanner.Visible = true
		if selfReviveFrac > 0 then
			selfSub.Text = "A teammate is reviving you..."
			selfFill.BackgroundColor3 = COL_ACCENT
			selfFill.Size = UDim2.fromScale(selfReviveFrac, 1)
		else
			local left = math.max(0, selfDownedEndsAt - os.clock())
			selfSub.Text = ("A teammate can revive you — %ds"):format(math.ceil(left))
			selfFill.BackgroundColor3 = COL_DANGER
			local total = math.max(1, GameConfig.BleedoutSeconds)
			selfFill.Size = UDim2.fromScale(math.clamp(left / total, 0, 1), 1)
		end
	else
		selfBanner.Visible = false
	end

	-- Teammate revive prompt.
	local target = (not downed[localPlayer.UserId]) and nearestDowned() or nil
	if target ~= holdTarget then
		stopHolding()
		holdTarget = target
	end
	if holdTarget then
		prompt.Visible = true
		promptText.Text = holding and ("Reviving %s..."):format(holdTarget.DisplayName)
			or ("Hold E  —  Revive %s"):format(holdTarget.DisplayName)
		promptFill.Size = UDim2.fromScale(holding and holdFrac or 0, 1)
	else
		prompt.Visible = false
	end
end

function ReviveController.Start()
	build()

	Remotes.Get("DownedChanged").OnClientEvent:Connect(function(userId, isDowned, bleedSecs)
		downed[userId] = isDowned or nil
		if userId == localPlayer.UserId then
			selfReviveFrac = 0
			selfDownedEndsAt = isDowned and (os.clock() + (tonumber(bleedSecs) or GameConfig.BleedoutSeconds)) or 0
		end
	end)

	Remotes.Get("ReviveProgress").OnClientEvent:Connect(function(targetUserId, frac)
		frac = tonumber(frac) or 0
		if targetUserId == localPlayer.UserId then
			selfReviveFrac = frac
		elseif holdTarget and targetUserId == holdTarget.UserId then
			holdFrac = frac
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.E and holdTarget and not holding then
			holding = true
			holdFrac = 0
			Remotes.Get("Revive"):FireServer(holdTarget.UserId, true)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.E then
			stopHolding()
		end
	end)

	Players.PlayerRemoving:Connect(function(pl)
		downed[pl.UserId] = nil
		if holdTarget == pl then
			stopHolding()
			holdTarget = nil
		end
	end)

	RunService.RenderStepped:Connect(onRender)
	print("[ReviveController] started")
end

return ReviveController
