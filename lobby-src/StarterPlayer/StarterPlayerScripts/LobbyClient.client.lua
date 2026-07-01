-- LobbyClient (LOBBY PLACE ONLY) — the hub HUD + the run SELECTION menu (Map → Difficulty → Party Size).
-- The menu opens while you stand in a loading zone; locked difficulties show 🔒. PLAY queues you; the panel
-- then shows the party count + countdown. Self-contained (no game controllers run here).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("LobbyRemotes")
local StatsRemote = remotes:WaitForChild("Stats")
local ZoneEnter = remotes:WaitForChild("ZoneEnter")
local ZoneLeave = remotes:WaitForChild("ZoneLeave")
local RequestQueue = remotes:WaitForChild("RequestQueue")
local LeaveQueue = remotes:WaitForChild("LeaveQueue")
local QueueStatus = remotes:WaitForChild("QueueStatus")

local ACCENT = Color3.fromRGB(120, 220, 120)
local DIM = Color3.fromRGB(70, 70, 82)
local CARD = Color3.fromRGB(24, 24, 32)

local sel = { map = "forest", difficulty = "easy", size = 1 }
local payload = nil
local queued = false

local function fmt(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
local function cap(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end
local function corner(o, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = o
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "LobbyHUD"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 10
gui.Parent = playerGui

-- stats card
local stats = Instance.new("Frame")
stats.Position = UDim2.fromOffset(16, 16); stats.Size = UDim2.fromOffset(220, 96)
stats.BackgroundColor3 = Color3.fromRGB(22, 20, 28); stats.BackgroundTransparency = 0.1; stats.BorderSizePixel = 0
stats.Parent = gui; corner(stats, 12)
local sp = Instance.new("UIPadding"); sp.PaddingLeft = UDim.new(0, 12); sp.PaddingTop = UDim.new(0, 8); sp.Parent = stats
local sl = Instance.new("UIListLayout"); sl.Padding = UDim.new(0, 4); sl.Parent = stats
local function statLabel(color)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -12, 0, 26); l.BackgroundTransparency = 1; l.Font = Enum.Font.GothamBold
	l.TextSize = 18; l.TextXAlignment = Enum.TextXAlignment.Left; l.TextColor3 = color; l.Text = ""; l.Parent = stats
	return l
end
local moneyLabel = statLabel(Color3.fromRGB(255, 220, 120))
local bestLabel = statLabel(Color3.fromRGB(210, 210, 220))

-- selection panel
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5); panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(560, 380); panel.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
panel.BackgroundTransparency = 0.05; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 16)
local pstroke = Instance.new("UIStroke"); pstroke.Color = ACCENT; pstroke.Thickness = 2; pstroke.Transparency = 0.5; pstroke.Parent = panel

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 14); title.Size = UDim2.new(1, 0, 0, 34); title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack; title.TextSize = 26; title.TextColor3 = Color3.fromRGB(240, 240, 245)
title.Text = "SELECT YOUR RUN"; title.Parent = panel

local function sectionLabel(text, y)
	local l = Instance.new("TextLabel")
	l.Position = UDim2.new(0, 24, 0, y); l.Size = UDim2.new(1, -48, 0, 20); l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold; l.TextSize = 15; l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Color3.fromRGB(170, 180, 195); l.Text = text; l.Parent = panel
	return l
end
local function row(y, h)
	local f = Instance.new("Frame")
	f.Position = UDim2.new(0, 24, 0, y); f.Size = UDim2.new(1, -48, 0, h); f.BackgroundTransparency = 1; f.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal; list.Padding = UDim.new(0, 10); list.Parent = f
	return f
end
local function button(parent, w, h, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, h); b.BackgroundColor3 = CARD; b.AutoButtonColor = true; b.Text = text
	b.Font = Enum.Font.GothamBold; b.TextSize = 16; b.TextColor3 = Color3.fromRGB(235, 235, 245); b.Parent = parent
	corner(b, 8)
	return b
end

sectionLabel("MAP", 56)
local mapRow = row(78, 40)
sectionLabel("DIFFICULTY", 130)
local diffRow = row(152, 44)
sectionLabel("PARTY SIZE", 208)
local sizeRow = row(230, 40)

local mapBtns, diffBtns, sizeBtns = {}, {}, {}

local play = Instance.new("TextButton")
play.AnchorPoint = Vector2.new(0.5, 1); play.Position = UDim2.new(0.5, 0, 1, -46); play.Size = UDim2.fromOffset(240, 52)
play.BackgroundColor3 = ACCENT; play.Font = Enum.Font.GothamBlack; play.TextSize = 24
play.TextColor3 = Color3.fromRGB(15, 25, 15); play.Text = "PLAY"; play.Parent = panel
corner(play, 10)

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 1); status.Position = UDim2.new(0.5, 0, 1, -12); status.Size = UDim2.new(1, -40, 0, 24)
status.BackgroundTransparency = 1; status.Font = Enum.Font.GothamBold; status.TextSize = 15
status.TextColor3 = Color3.fromRGB(190, 220, 255); status.Text = ""; status.Parent = panel

-- ===== RENDER =====
local function refresh()
	if not payload then return end
	-- map buttons
	for _, b in mapBtns do b:Destroy() end
	mapBtns = {}
	for _, w in payload.worldOrder do
		local info = payload.worlds[w]
		local b = button(mapRow, 150, 40, cap(w))
		b.LayoutOrder = #mapBtns + 1
		if not info.unlocked then
			b.Text = cap(w) .. " 🔒"; b.AutoButtonColor = false; b.TextColor3 = Color3.fromRGB(150, 150, 160)
		end
		b.BackgroundColor3 = (sel.map == w) and ACCENT or CARD
		b.Activated:Connect(function()
			if info.unlocked and not queued then sel.map = w; refresh() end
		end)
		table.insert(mapBtns, b)
	end
	-- difficulty buttons
	for _, b in diffBtns do b:Destroy() end
	diffBtns = {}
	local worldInfo = payload.worlds[sel.map]
	for _, d in payload.order do
		local unlocked = worldInfo and worldInfo.diffs[d]
		local b = button(diffRow, 120, 44, unlocked and cap(d) or (cap(d) .. " 🔒"))
		b.LayoutOrder = #diffBtns + 1
		if not unlocked then
			b.AutoButtonColor = false; b.BackgroundColor3 = DIM; b.TextColor3 = Color3.fromRGB(150, 150, 160)
		else
			b.BackgroundColor3 = (sel.difficulty == d) and ACCENT or CARD
			b.TextColor3 = (sel.difficulty == d) and Color3.fromRGB(15, 25, 15) or Color3.fromRGB(235, 235, 245)
		end
		b.Activated:Connect(function()
			if unlocked and not queued then sel.difficulty = d; refresh() end
		end)
		table.insert(diffBtns, b)
	end
	-- size buttons
	for _, b in sizeBtns do b:Destroy() end
	sizeBtns = {}
	for n = 1, 4 do
		local b = button(sizeRow, 60, 40, tostring(n))
		b.LayoutOrder = n
		b.BackgroundColor3 = (sel.size == n) and ACCENT or CARD
		b.TextColor3 = (sel.size == n) and Color3.fromRGB(15, 25, 15) or Color3.fromRGB(235, 235, 245)
		b.Activated:Connect(function()
			if not queued then sel.size = n; refresh() end
		end)
		table.insert(sizeBtns, b)
	end
	play.Text = queued and "CANCEL" or "PLAY"
	play.BackgroundColor3 = queued and Color3.fromRGB(230, 90, 90) or ACCENT
end

-- default difficulty = first unlocked for the selected map
local function pickDefaultDifficulty()
	local info = payload and payload.worlds[sel.map]
	if info then
		for _, d in payload.order do
			if info.diffs[d] then sel.difficulty = d; return end
		end
	end
end

-- ===== EVENTS =====
StatsRemote.OnClientEvent:Connect(function(s)
	if typeof(s) ~= "table" then return end
	moneyLabel.Text = "🪙 " .. fmt(s.lobbyMoney or 0)
	bestLabel.Text = "Best: Wave " .. tostring(s.bestWave or 0)
end)

ZoneEnter.OnClientEvent:Connect(function(p)
	payload = p
	queued = false
	status.Text = ""
	if not (payload.worlds[sel.map]) then sel.map = payload.worldOrder[1] end
	pickDefaultDifficulty()
	sel.size = 1
	refresh()
	panel.Visible = true
end)

ZoneLeave.OnClientEvent:Connect(function()
	panel.Visible = false
	queued = false
end)

QueueStatus.OnClientEvent:Connect(function(info)
	if typeof(info) ~= "table" then
		queued = false
		status.Text = ""
		refresh()
		return
	end
	queued = true
	status.Text = ("%s · %s · Party %d/%d · Starting in %d...")
		:format(cap(info.map), cap(info.difficulty), info.count or 1, info.size or 1, info.seconds or 0)
	refresh()
end)

play.Activated:Connect(function()
	if queued then
		LeaveQueue:FireServer()
		queued = false
		status.Text = ""
		refresh()
	else
		RequestQueue:FireServer({ map = sel.map, difficulty = sel.difficulty, size = sel.size })
	end
end)

print("[LobbyClient] started")
