-- LobbyClient (LOBBY PLACE ONLY) — builds the lobby menu and fires PLAY. Self-contained: none of the game's
-- controllers run here. Restyle freely, or build your own ScreenGui named "LobbyGui" with a TextButton named
-- "PlayButton" (+ optional LevelLabel/MoneyLabel/BestWaveLabel/SummaryLabel) and this fallback steps aside.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("LobbyRemotes")
local PlayRemote = remotes:WaitForChild("Play")
local MenuRemote = remotes:WaitForChild("ShowMenu")

-- ===== TUNABLES =====
local BG_COLOR = Color3.fromRGB(12, 10, 16)
local ACCENT   = Color3.fromRGB(120, 220, 120)
local TITLE    = "ZOMBIE LOBBY"

local waiting = false
local refs = {}

local function formatNumber(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- ===== BUILD (used unless you provide your own "LobbyGui") =====
local function findOwnerGui()
	local g = playerGui:FindFirstChild("LobbyGui")
	return (g and g:IsA("ScreenGui")) and g or nil
end

local function findIn(root: Instance, name: string)
	for _, d in root:GetDescendants() do
		if d.Name == name and d:IsA("GuiObject") then
			return d
		end
	end
	return nil
end

local function buildFallback(): ScreenGui
	local g = Instance.new("ScreenGui")
	g.Name = "LobbyMenu"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 50
	g.Parent = playerGui

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = BG_COLOR
	bg.BackgroundTransparency = 0.1
	bg.BorderSizePixel = 0
	bg.Parent = g

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 440)
	panel.BackgroundColor3 = Color3.fromRGB(22, 20, 28)
	panel.BorderSizePixel = 0
	panel.Parent = bg
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = panel
	local ps = Instance.new("UIStroke")
	ps.Color = ACCENT
	ps.Thickness = 2
	ps.Transparency = 0.5
	ps.Parent = panel
	local pad = Instance.new("UIPadding")
	for _, s in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		pad[s] = UDim.new(0, 24)
	end
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 12)
	list.Parent = panel

	local function label(name: string, text: string, size: number, color: Color3, order: number)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.Size = UDim2.new(1, 0, 0, size + 8)
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBold
		l.Text = text
		l.TextSize = size
		l.TextColor3 = color
		l.LayoutOrder = order
		l.Parent = panel
		return l
	end

	label("Title", TITLE, 30, Color3.fromRGB(235, 235, 245), 1)
	label("LevelLabel", "Level 1", 22, Color3.fromRGB(200, 220, 255), 2)
	label("MoneyLabel", "$0", 22, Color3.fromRGB(255, 220, 120), 3)
	label("BestWaveLabel", "Best: Wave 0", 20, Color3.fromRGB(210, 210, 220), 4)

	local summary = label("SummaryLabel", "", 18, Color3.fromRGB(180, 255, 180), 5)
	summary.Size = UDim2.new(1, 0, 0, 52)
	summary.TextWrapped = true
	summary.Visible = false

	local play = Instance.new("TextButton")
	play.Name = "PlayButton"
	play.Size = UDim2.new(1, 0, 0, 64)
	play.BackgroundColor3 = ACCENT
	play.Text = "PLAY"
	play.Font = Enum.Font.GothamBlack
	play.TextSize = 28
	play.TextColor3 = Color3.fromRGB(15, 25, 15)
	play.LayoutOrder = 10
	play.Parent = panel
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 10)
	bc.Parent = play

	return g
end

local function setText(name: string, text: string)
	local el = refs[name]
	if el and el:IsA("TextLabel") then
		el.Text = text
	end
end

local function onPlay()
	if waiting then
		return
	end
	waiting = true
	local btn = refs.PlayButton
	if btn then
		btn.AutoButtonColor = false
		if btn:IsA("TextButton") then
			btn.Text = "LOADING..."
		end
	end
	PlayRemote:FireServer()
end

-- ===== START =====
local gui = findOwnerGui() or buildFallback()
refs.PlayButton = findIn(gui, "PlayButton")
refs.LevelLabel = findIn(gui, "LevelLabel")
refs.MoneyLabel = findIn(gui, "MoneyLabel")
refs.BestWaveLabel = findIn(gui, "BestWaveLabel")
refs.SummaryLabel = findIn(gui, "SummaryLabel")

if refs.PlayButton and refs.PlayButton:IsA("GuiButton") then
	refs.PlayButton.Activated:Connect(onPlay)
end

MenuRemote.OnClientEvent:Connect(function(stats, summary)
	if typeof(stats) == "table" then
		setText("LevelLabel", ("Level %d"):format(stats.level or 1))
		setText("MoneyLabel", "$" .. formatNumber(stats.lobbyMoney or 0))
		setText("BestWaveLabel", ("Best: Wave %d"):format(stats.bestWave or 0))
	end
	if refs.SummaryLabel then
		if typeof(summary) == "table" then
			refs.SummaryLabel.Visible = true
			refs.SummaryLabel.Text = ("Last run: Wave %d  ·  %d kills  ·  +$%s")
				:format(summary.wave or 0, summary.kills or 0, formatNumber(summary.money or 0))
		else
			refs.SummaryLabel.Visible = false
		end
	end
	-- A fresh PLAY can be pressed again after returning to the menu.
	waiting = false
	if refs.PlayButton then
		refs.PlayButton.AutoButtonColor = true
		if refs.PlayButton:IsA("TextButton") then
			refs.PlayButton.Text = "PLAY"
		end
	end
end)

print("[LobbyClient] started")
