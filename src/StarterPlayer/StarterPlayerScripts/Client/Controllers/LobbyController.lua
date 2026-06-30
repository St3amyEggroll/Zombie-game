--!nonstrict
-- LobbyController.lua — the MENU LOBBY. **You style the UI; this code drives it.**
--
-- The flow (server-driven): on join the server fires EnterLobby(nil) → this shows the lobby menu (you have
-- no character yet). Press PLAY → we fire RequestPlay → the server spawns you into the arena and we hide the
-- menu (on CharacterAdded). When you DIE, the server banks your run and fires EnterLobby(summary) → we show
-- the menu again with the run's results. Press PLAY for a fresh run.
--
-- NAMED-INSTANCE CONTRACT: build a ScreenGui named "LobbyGui" anywhere under StarterGui/PlayerGui and name
-- the pieces — this code finds them and drives them, skipping any that are missing:
--   PlayButton  (TextButton)  — pressing it starts a run
--   LevelLabel  (TextLabel)   — "Level 7"
--   MoneyLabel  (TextLabel)   — lobby money "$1,250"
--   BestWaveLabel (TextLabel) — "Best: Wave 23"
--   SummaryLabel (TextLabel)  — last run's results (hidden until you finish a run)
-- If no "LobbyGui" exists, a plain functional fallback menu is built so the lobby is playable immediately.
-- Restyle freely: build your own LobbyGui and this fallback steps aside.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Config = Shared:WaitForChild("Config")

local Util = require(Modules.Util)
local Remotes = require(Modules.Remotes)
local Places = require(Config.Places)

local LobbyController = {}

-- ===== TUNABLES =====
local DISPLAY_ORDER = 50                      -- above the HUD/crosshair so the menu always covers them
local BG_COLOR      = Color3.fromRGB(12, 10, 16)
local BG_TRANSP     = 0.15                     -- how see-through the backdrop is (0 = opaque)
local ACCENT        = Color3.fromRGB(120, 220, 120)
local TITLE_TEXT    = "ZOMBIE LOBBY"

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Latest known meta (seeded from GetData, kept live by DataReady + ProgressChanged).
local meta = { level = 1, xp = 0, lobbyMoney = 0, bestWave = 0 }

local gui          -- the lobby ScreenGui (owner's "LobbyGui" or our fallback)
local ownerStyled  -- true if we're driving an owner-built LobbyGui (don't restyle it)
local refs = {}    -- cached named elements: PlayButton, LevelLabel, MoneyLabel, BestWaveLabel, SummaryLabel
local waiting = false -- PLAY pressed, waiting to spawn (debounce)

-- ===== ELEMENT LOOKUP =====
local function findIn(root: Instance, name: string)
	for _, d in root:GetDescendants() do
		if d.Name == name and (d:IsA("GuiObject")) then
			return d
		end
	end
	return nil
end

-- ===== FALLBACK MENU (built only if no owner "LobbyGui") =====
local function buildFallback()
	local g = Instance.new("ScreenGui")
	g.Name = "LobbyMenu"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = DISPLAY_ORDER
	g.Enabled = false
	g.Parent = playerGui

	local bg = Instance.new("Frame")
	bg.Name = "Backdrop"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = BG_COLOR
	bg.BackgroundTransparency = BG_TRANSP
	bg.BorderSizePixel = 0
	bg.Parent = g

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 460)
	panel.BackgroundColor3 = Color3.fromRGB(22, 20, 28)
	panel.BackgroundTransparency = 0.05
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
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.Padding = UDim.new(0, 12)
	list.Parent = panel

	local function label(name: string, text: string, size: number, color: Color3, order: number)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.Size = UDim2.new(1, 0, 0, size + 8)
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBold
		l.Text = text
		l.TextScaled = false
		l.TextSize = size
		l.TextColor3 = color
		l.LayoutOrder = order
		l.Parent = panel
		return l
	end

	label("Title", TITLE_TEXT, 30, Color3.fromRGB(235, 235, 245), 1)
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
	play.AutoButtonColor = true
	play.LayoutOrder = 10
	play.Parent = panel
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 10)
	bc.Parent = play

	return g
end

-- ===== RESOLVE (prefer an owner-built "LobbyGui") =====
local function resolve()
	if gui and gui.Parent then
		return
	end
	local owner = playerGui:FindFirstChild("LobbyGui", true)
	if owner and owner:IsA("ScreenGui") then
		gui = owner
		ownerStyled = true
		gui.ResetOnSpawn = false
	else
		gui = buildFallback()
		ownerStyled = false
	end
	refs.PlayButton = findIn(gui, "PlayButton")
	refs.LevelLabel = findIn(gui, "LevelLabel")
	refs.MoneyLabel = findIn(gui, "MoneyLabel")
	refs.BestWaveLabel = findIn(gui, "BestWaveLabel")
	refs.SummaryLabel = findIn(gui, "SummaryLabel")

	if refs.PlayButton and refs.PlayButton:IsA("GuiButton") then
		refs.PlayButton.Activated:Connect(function()
			LobbyController.RequestPlay()
		end)
	end
end

-- ===== RENDER =====
local function render()
	if refs.LevelLabel then
		refs.LevelLabel.Text = ("Level %d"):format(meta.level or 1)
	end
	if refs.MoneyLabel then
		refs.MoneyLabel.Text = "$" .. Util.FormatNumber(meta.lobbyMoney or 0)
	end
	if refs.BestWaveLabel then
		refs.BestWaveLabel.Text = ("Best: Wave %d"):format(meta.bestWave or 0)
	end
end

local function setPlayEnabled(on: boolean)
	local btn = refs.PlayButton
	if btn and btn:IsA("GuiButton") then
		btn.Active = on
		btn.AutoButtonColor = on
		if not ownerStyled then
			btn.Text = on and "PLAY" or "LOADING..."
		end
	end
end

-- ===== SHOW / HIDE =====
local function showLobby(summary)
	resolve()
	waiting = false
	setPlayEnabled(true)
	render()
	if refs.SummaryLabel then
		if typeof(summary) == "table" then
			refs.SummaryLabel.Visible = true
			refs.SummaryLabel.Text = ("Last run: Wave %d  ·  %d kills  ·  +$%s")
				:format(summary.wave or 0, summary.kills or 0, Util.FormatNumber(summary.money or 0))
		else
			refs.SummaryLabel.Visible = false
		end
	end
	if gui then
		gui.Enabled = true
	end
end

local function hideLobby()
	if gui then
		gui.Enabled = false
	end
end

-- ===== PUBLIC =====
-- Fire the PLAY intent (also usable by an owner script wired to a custom button).
function LobbyController.RequestPlay()
	if waiting then
		return
	end
	waiting = true
	setPlayEnabled(false)
	Remotes.Get("RequestPlay"):FireServer()
end

function LobbyController.IsOpen(): boolean
	return gui ~= nil and gui.Enabled == true
end

-- ===== LIFECYCLE =====
function LobbyController.Start()
	-- Only active where a menu is shown: the lobby place, or Studio (in-place menu for testing). In the live
	-- game place the server teleports instead of showing a menu, so stay dormant (IsOpen() stays false).
	if not (Places.IsLobby or RunService:IsStudio()) then
		print("[LobbyController] dormant (live game place — server teleports to the lobby)")
		return
	end

	resolve()
	hideLobby()

	-- Seed meta now (in case DataReady already fired before this controller connected).
	task.spawn(function()
		local ok, data = pcall(function()
			return Remotes.Get("GetData"):InvokeServer()
		end)
		if ok and typeof(data) == "table" then
			meta.level = data.level or meta.level
			meta.xp = data.xp or meta.xp
			meta.lobbyMoney = data.lobbyMoney or meta.lobbyMoney
			meta.bestWave = data.bestWave or meta.bestWave
			render()
		end
	end)

	-- Full snapshot on load.
	Remotes.Get("DataReady").OnClientEvent:Connect(function(data)
		if typeof(data) == "table" then
			meta.level = data.level or meta.level
			meta.xp = data.xp or meta.xp
			meta.lobbyMoney = data.lobbyMoney or meta.lobbyMoney
			meta.bestWave = data.bestWave or meta.bestWave
			render()
		end
	end)

	-- Live progression updates (XP/level/lobby money).
	Remotes.Get("ProgressChanged").OnClientEvent:Connect(function(xp, level, lobbyMoney)
		if xp then meta.xp = xp end
		if level then meta.level = level end
		if lobbyMoney then meta.lobbyMoney = lobbyMoney end
		render()
	end)

	-- Server puts us in the lobby (on join + after every run/death).
	Remotes.Get("EnterLobby").OnClientEvent:Connect(function(summary)
		showLobby(summary)
	end)

	-- We spawned into the arena → leave the menu.
	localPlayer.CharacterAdded:Connect(function()
		hideLobby()
	end)
	-- Initial state: if we already have a character we're in a run (hide); otherwise we're in the lobby —
	-- show the menu now as a safety net in case the server's EnterLobby fired before we connected.
	if localPlayer.Character then
		hideLobby()
	else
		showLobby(nil)
	end

	print("[LobbyController] started" .. (ownerStyled and " (owner LobbyGui)" or " (fallback menu)"))
end

return LobbyController
