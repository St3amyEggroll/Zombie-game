--!nonstrict
-- EventWheelController.lua — THE VISIBLE EVENT WHEEL. Every wave break the server rolls next wave's
-- modifier and broadcasts EventSpin {wave, outcome, seconds}; we run a slot-machine reel top-center:
-- icons whip past a window, decelerate, and LAND on the outcome — then the name card flashes and the
-- banner tucks away before the wave starts. Pure theater: the server already decided the outcome.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)
local LobbyLook = require(Shared.Modules.LobbyLook)

local EventWheelController = {}

-- ===== TUNABLES =====
local CELL = 64            -- icon cell size (px)
local GAP = 8              -- gap between cells
local WINDOW_W = 232       -- the visible reel window (shows ~3 cells; the CENTER one wins)
local REEL_CELLS = 16      -- how many cells the reel scrolls past before landing
local HOLD_SECONDS = 2.2   -- how long the landed result stays up
local LINGER_NAME = 1.6    -- the outcome name card's flash time

-- What each wheel outcome looks like on the reel (server sends only the id).
local LOOK = {
	calm      = { icon = "☀️", name = "CALM WAVE",     color = Color3.fromRGB(124, 219, 35) },
	bloodmoon = { icon = "🌕", name = "BLOOD MOON",    color = Color3.fromRGB(255, 70, 50) },
	fog       = { icon = "🌫️", name = "FOG",           color = Color3.fromRGB(180, 186, 168) },
	meteors   = { icon = "☄️", name = "METEOR SHOWER", color = Color3.fromRGB(255, 140, 40) },
}
local IDS = { "calm", "bloodmoon", "fog", "meteors" }

local localPlayer = Players.LocalPlayer

local gui, banner, window, reel, nameCard, nameLabel, titleLabel
local spinToken = 0

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "EventWheel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = (UITheme.Layer and UITheme.Layer.HUD or 4) + 1
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui, nil, nil, "hud")

	banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	-- Below the wave strip; on touch the whole top lane sits lower (see HUDController's lane note).
	banner.Position = UDim2.new(0.5, 0, 0, UserInputService.TouchEnabled and 168 or 64)
	banner.Size = UDim2.fromOffset(WINDOW_W + 24, 108)
	banner.BackgroundTransparency = 1
	banner.Parent = gui

	titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.fromOffset(0, 0)
	titleLabel.Size = UDim2.new(1, 0, 0, 18)
	titleLabel.FontFace = LobbyLook.BODYB_FACE
	titleLabel.TextSize = 13
	titleLabel.TextColor3 = LobbyLook.DIMTEXT
	titleLabel.Text = "NEXT WAVE"
	titleLabel.Parent = banner
	local tStroke = Instance.new("UIStroke")
	tStroke.Color = Color3.fromRGB(0, 0, 0)
	tStroke.Transparency = 0.4
	tStroke.Thickness = 1.2
	tStroke.Parent = titleLabel

	window = Instance.new("Frame") -- the reel window (clips the scrolling icons)
	window.Name = "Window"
	window.AnchorPoint = Vector2.new(0.5, 0)
	window.Position = UDim2.new(0.5, 0, 0, 22)
	window.Size = UDim2.fromOffset(WINDOW_W, CELL + 12)
	window.BackgroundColor3 = LobbyLook.PANEL
	window.BackgroundTransparency = 0.08
	window.BorderSizePixel = 0
	window.ClipsDescendants = true
	window.Parent = banner
	LobbyLook.corner(window, 14)
	LobbyLook.ledge(window, LobbyLook.TBLACK, 3)
	LobbyLook.lstuds(window, 46, 0.94)

	-- Center marker: the win slot (two little notches above/below the middle).
	for _, side in { 0, 1 } do
		local notch = Instance.new("Frame")
		notch.AnchorPoint = Vector2.new(0.5, side)
		notch.Position = UDim2.new(0.5, 0, side, 0)
		notch.Size = UDim2.fromOffset(3, 8)
		notch.BackgroundColor3 = LobbyLook.GOLD
		notch.BorderSizePixel = 0
		notch.ZIndex = 5
		notch.Parent = window
	end

	reel = Instance.new("Frame") -- the scrolling strip of icon cells
	reel.Name = "Reel"
	reel.BackgroundTransparency = 1
	reel.Size = UDim2.fromOffset(10, CELL)
	reel.Position = UDim2.fromOffset(0, 6)
	reel.Parent = window

	nameCard = Instance.new("Frame") -- the landed outcome's name flash under the window
	nameCard.Name = "NameCard"
	nameCard.AnchorPoint = Vector2.new(0.5, 0)
	nameCard.Position = UDim2.new(0.5, 0, 0, CELL + 40)
	nameCard.Size = UDim2.fromOffset(WINDOW_W, 26)
	nameCard.BackgroundTransparency = 1
	nameCard.Parent = banner

	nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.FontFace = LobbyLook.TITLE_FACE
	nameLabel.TextSize = 22
	nameLabel.TextColor3 = LobbyLook.TEXTCOL
	nameLabel.Text = ""
	nameLabel.Parent = nameCard
	local nStroke = Instance.new("UIStroke")
	nStroke.Color = Color3.fromRGB(0, 0, 0)
	nStroke.Transparency = 0.25
	nStroke.Thickness = 2
	nStroke.Parent = nameLabel
end

local function makeCell(id: string, index: number): Frame
	local look = LOOK[id] or LOOK.calm
	local cell = Instance.new("Frame")
	cell.Name = "Cell" .. index
	cell.Position = UDim2.fromOffset((index - 1) * (CELL + GAP), 0)
	cell.Size = UDim2.fromOffset(CELL, CELL)
	cell.BackgroundColor3 = LobbyLook.PANEL2
	cell.BorderSizePixel = 0
	cell.Parent = reel
	LobbyLook.corner(cell, 12)
	LobbyLook.ledge(cell, look.color, 2, 0.35)
	local icon = Instance.new("TextLabel")
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(1, 1)
	icon.Text = look.icon
	icon.TextSize = 34
	icon.Font = Enum.Font.SourceSansBold
	icon.Parent = cell
	return cell
end

local function runSpin(info)
	local outcome = typeof(info) == "table" and tostring(info.outcome) or "calm"
	if not LOOK[outcome] then
		outcome = "calm"
	end
	local secs = math.max(1, tonumber(info.seconds) or 3)

	spinToken += 1
	local myTok = spinToken
	reel:ClearAllChildren()
	nameLabel.Text = ""
	nameLabel.TextTransparency = 0

	-- Build the reel: random filler cells, with the OUTCOME as the final (landing) cell.
	local order = {}
	for i = 1, REEL_CELLS - 1 do
		order[i] = IDS[math.random(1, #IDS)]
	end
	order[REEL_CELLS] = outcome
	local landed = {}
	for i, id in order do
		landed[i] = makeCell(id, i)
	end

	-- Land the final cell dead-center: reel x so cell N's center sits at WINDOW_W/2.
	local pitch = CELL + GAP
	local finalX = WINDOW_W / 2 - ((REEL_CELLS - 1) * pitch + CELL / 2)
	reel.Position = UDim2.fromOffset(0, 6)
	gui.Enabled = true

	-- The spin: fast, then a long Quint decel onto the target — reads exactly like a slot reel.
	local spin = TweenService:Create(reel, TweenInfo.new(secs, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(finalX, 6),
	})
	spin:Play()
	spin.Completed:Once(function()
		if myTok ~= spinToken then
			return
		end
		-- The reveal: pulse the winning cell + flash the name in the outcome's color.
		local look = LOOK[outcome]
		local winCell = landed[REEL_CELLS]
		if winCell then
			local pop = Instance.new("UIScale")
			pop.Scale = 1
			pop.Parent = winCell
			TweenService:Create(pop, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1.18 }):Play()
		end
		nameLabel.Text = look.name
		nameLabel.TextColor3 = look.color
		task.delay(LINGER_NAME, function()
			if myTok == spinToken then
				TweenService:Create(nameLabel, TweenInfo.new(0.4), { TextTransparency = 0.25 }):Play()
			end
		end)
		task.delay(HOLD_SECONDS, function()
			if myTok == spinToken then
				gui.Enabled = false
			end
		end)
	end)
end

function EventWheelController.Start()
	build()
	Remotes.Get("EventSpin").OnClientEvent:Connect(runSpin)
	print("[EventWheelController] started (the wheel is watching)")
end

return EventWheelController
