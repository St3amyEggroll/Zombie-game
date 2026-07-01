-- LobbyClient (LOBBY PLACE ONLY) — HUD for the walkable hub: your Coins / Level / Best Wave, and a
-- countdown panel that appears while you stand in a loading zone (difficulty, party size, seconds to launch).
-- Self-contained; none of the game's controllers run here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("LobbyRemotes")
local StatsRemote = remotes:WaitForChild("Stats")
local ZoneRemote = remotes:WaitForChild("ZoneStatus")

local ACCENT = Color3.fromRGB(120, 220, 120)

local function formatNumber(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "LobbyHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.Parent = playerGui

-- Stats card (top-left)
local stats = Instance.new("Frame")
stats.Position = UDim2.fromOffset(16, 16)
stats.Size = UDim2.fromOffset(220, 96)
stats.BackgroundColor3 = Color3.fromRGB(22, 20, 28)
stats.BackgroundTransparency = 0.1
stats.BorderSizePixel = 0
stats.Parent = gui
corner(stats, 12)
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 12)
pad.PaddingTop = UDim.new(0, 8)
pad.Parent = stats
local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 4)
list.Parent = stats

local function statLabel(name, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Size = UDim2.new(1, -12, 0, 26)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextSize = 18
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = color
	l.Text = ""
	l.Parent = stats
	return l
end
local moneyLabel = statLabel("Money", Color3.fromRGB(255, 220, 120))
local levelLabel = statLabel("Level", Color3.fromRGB(200, 220, 255))
local bestLabel = statLabel("Best", Color3.fromRGB(210, 210, 220))

-- Countdown panel (bottom-center; hidden until you're in a zone)
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -40)
panel.Size = UDim2.fromOffset(360, 96)
panel.BackgroundColor3 = Color3.fromRGB(18, 22, 34)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
corner(panel, 14)
local ps = Instance.new("UIStroke")
ps.Color = ACCENT
ps.Thickness = 2
ps.Transparency = 0.4
ps.Parent = panel

local diffLabel = Instance.new("TextLabel")
diffLabel.AnchorPoint = Vector2.new(0.5, 0)
diffLabel.Position = UDim2.new(0.5, 0, 0, 8)
diffLabel.Size = UDim2.new(1, 0, 0, 26)
diffLabel.BackgroundTransparency = 1
diffLabel.Font = Enum.Font.GothamBlack
diffLabel.TextSize = 20
diffLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
diffLabel.Text = ""
diffLabel.Parent = panel

local countText = Instance.new("TextLabel")
countText.AnchorPoint = Vector2.new(0.5, 0)
countText.Position = UDim2.new(0.5, 0, 0, 36)
countText.Size = UDim2.new(1, 0, 0, 22)
countText.BackgroundTransparency = 1
countText.Font = Enum.Font.GothamBold
countText.TextSize = 16
countText.TextColor3 = Color3.fromRGB(190, 200, 215)
countText.Text = ""
countText.Parent = panel

local secsText = Instance.new("TextLabel")
secsText.AnchorPoint = Vector2.new(0.5, 1)
secsText.Position = UDim2.new(0.5, 0, 1, -8)
secsText.Size = UDim2.new(1, 0, 0, 26)
secsText.BackgroundTransparency = 1
secsText.Font = Enum.Font.GothamBlack
secsText.TextSize = 22
secsText.TextColor3 = ACCENT
secsText.Text = ""
secsText.Parent = panel

-- ===== EVENTS =====
StatsRemote.OnClientEvent:Connect(function(s)
	if typeof(s) ~= "table" then
		return
	end
	moneyLabel.Text = "🪙 " .. formatNumber(s.lobbyMoney or 0)
	levelLabel.Text = "Level " .. tostring(s.level or 1)
	bestLabel.Text = "Best: Wave " .. tostring(s.bestWave or 0)
end)

ZoneRemote.OnClientEvent:Connect(function(info)
	if typeof(info) ~= "table" then
		panel.Visible = false
		return
	end
	local diff = tostring(info.difficulty or "medium")
	diffLabel.Text = diff:sub(1, 1):upper() .. diff:sub(2)
	countText.Text = ("Party  %d / %d"):format(info.count or 1, info.maxParty or 4)
	secsText.Text = ("Starting in %d..."):format(info.seconds or 0)
	panel.Visible = true
end)

print("[LobbyClient] started")
