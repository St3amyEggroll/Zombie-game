--!nonstrict
-- PowerDraftController.lua — the pick-1-of-3 POWER cards (the choice that replaced extraction).
-- Server (PowerDraftService) sends DraftOffer = { powers = {{id,name,desc,icon,stacks},...}, seconds };
-- we show three lobby-styled cards LOW-CENTER (above the hotbar, NON-blocking — the horde keeps coming
-- and dodging while you pick is the drama), a draining pick-timer bar, and send DraftPick(id) on tap.
-- No pick before the timer runs out = the server auto-picks the first card; we just hide.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)
local LobbyLook = require(Shared.Modules.LobbyLook)

local PowerDraftController = {}

-- ===== TUNABLES =====
local CARD_W, CARD_H = 172, 196
local CARD_GAP = 14
local LIFT_Y = -258          -- card row's offset above the screen bottom (clears hotbar + dock)
local TIMER_H = 8

local localPlayer = Players.LocalPlayer

local gui, row, timerTrack, timerFill
local windowToken = 0 -- invalidates the old offer's timer/buttons when a new one lands

local function buildRoot()
	gui = Instance.new("ScreenGui")
	gui.Name = "PowerDraft"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = (UITheme.Layer and UITheme.Layer.Hotbar or 6) + 1 -- above the hotbar, under modals
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui, nil, nil, "hud") -- HUD-scaled: it lives with the hotbar, not like a popup

	row = Instance.new("Frame")
	row.Name = "CardRow"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, LIFT_Y)
	row.Size = UDim2.fromOffset(CARD_W * 3 + CARD_GAP * 2, CARD_H + 34)
	row.BackgroundTransparency = 1
	row.Parent = gui

	-- The pick timer under the cards: full → empty over the window; the server auto-picks at zero.
	timerTrack = Instance.new("Frame")
	timerTrack.Name = "TimerTrack"
	timerTrack.AnchorPoint = Vector2.new(0.5, 1)
	timerTrack.Position = UDim2.new(0.5, 0, 1, 0)
	timerTrack.Size = UDim2.fromOffset(CARD_W * 3 + CARD_GAP * 2 - 40, TIMER_H)
	timerTrack.BackgroundColor3 = LobbyLook.TRACK
	timerTrack.BorderSizePixel = 0
	timerTrack.Parent = row
	LobbyLook.corner(timerTrack, 4)
	LobbyLook.ledge(timerTrack, LobbyLook.TBLACK, 2)

	timerFill = Instance.new("Frame")
	timerFill.Name = "Fill"
	timerFill.Size = UDim2.fromScale(1, 1)
	timerFill.BackgroundColor3 = Color3.fromRGB(170, 90, 255) -- POWER purple (matches the HUD clock bar)
	timerFill.BorderSizePixel = 0
	timerFill.Parent = timerTrack
	LobbyLook.corner(timerFill, 4)
end

-- Roman-ish stack tag ("II", "III", ... falls back to xN deep) so a re-offer reads as an upgrade.
local ROMAN = { "", "II", "III", "IV", "V", "VI", "VII", "VIII" }
local function stackTag(stacks: number): string
	local nextStack = stacks + 1
	if nextStack <= 1 then
		return "NEW"
	end
	return ROMAN[nextStack] or ("x" .. nextStack)
end

local function makeCard(def, index: number, myTok: number)
	local card = Instance.new("TextButton")
	card.Name = "Power_" .. tostring(def.id)
	card.AutoButtonColor = false
	card.Text = ""
	card.Position = UDim2.fromOffset((index - 1) * (CARD_W + CARD_GAP), 0)
	card.Size = UDim2.fromOffset(CARD_W, CARD_H)
	card.BackgroundColor3 = LobbyLook.PANEL2
	card.BorderSizePixel = 0
	card.Parent = row
	LobbyLook.corner(card, 14)
	LobbyLook.ledge(card, Color3.fromRGB(170, 90, 255), 3, 0.25)
	LobbyLook.ldepth(card, 0.45)
	LobbyLook.lstuds(card, 46, 0.94)

	local icon = Instance.new("TextLabel")
	icon.BackgroundTransparency = 1
	icon.Position = UDim2.fromOffset(0, 14)
	icon.Size = UDim2.new(1, 0, 0, 52)
	icon.Text = tostring(def.icon or "✦")
	icon.TextSize = 44
	icon.Font = Enum.Font.SourceSansBold
	icon.Parent = card

	local tag = Instance.new("TextLabel") -- stack tag: NEW on first pick, II/III... on repeats
	tag.BackgroundColor3 = LobbyLook.TBLACK
	tag.BackgroundTransparency = 0.25
	tag.AnchorPoint = Vector2.new(1, 0)
	tag.Position = UDim2.new(1, -8, 0, 8)
	tag.Size = UDim2.fromOffset(40, 20)
	tag.FontFace = LobbyLook.BODYB_FACE
	tag.TextSize = 12
	tag.TextColor3 = (tonumber(def.stacks) or 0) > 0 and LobbyLook.GOLD or LobbyLook.ACCENT
	tag.Text = stackTag(tonumber(def.stacks) or 0)
	tag.Parent = card
	LobbyLook.corner(tag, 8)

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(8, 72)
	name.Size = UDim2.new(1, -16, 0, 44)
	name.FontFace = LobbyLook.TITLE_FACE
	name.TextSize = 17
	name.TextColor3 = LobbyLook.TEXTCOL
	name.TextWrapped = true
	name.Text = tostring(def.name or def.id)
	name.Parent = card

	local desc = Instance.new("TextLabel")
	desc.BackgroundTransparency = 1
	desc.Position = UDim2.fromOffset(10, 120)
	desc.Size = UDim2.new(1, -20, 0, 62)
	desc.FontFace = LobbyLook.BODY_FACE
	desc.TextSize = 14
	desc.TextColor3 = LobbyLook.DIMTEXT
	desc.TextWrapped = true
	desc.Text = tostring(def.desc or "")
	desc.Parent = card

	card.MouseEnter:Connect(function()
		card.BackgroundColor3 = LobbyLook.darker(LobbyLook.PANEL2, -0.15)
	end)
	card.MouseLeave:Connect(function()
		card.BackgroundColor3 = LobbyLook.PANEL2
	end)
	card.Activated:Connect(function()
		if myTok ~= windowToken then
			return -- a newer offer owns the row
		end
		Remotes.Get("DraftPick"):FireServer(def.id)
		PowerDraftController.Hide()
	end)
end

function PowerDraftController.Hide()
	windowToken += 1
	gui.Enabled = false
end

local function showOffer(info)
	local powers = typeof(info) == "table" and typeof(info.powers) == "table" and info.powers or nil
	if not powers or #powers == 0 then
		return
	end
	windowToken += 1
	local myTok = windowToken

	for _, child in row:GetChildren() do -- clear the last offer's cards
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local n = math.min(#powers, 3)
	row.Size = UDim2.fromOffset(CARD_W * n + CARD_GAP * (n - 1), CARD_H + 34)
	for i = 1, n do
		makeCard(powers[i], i, myTok)
	end

	gui.Enabled = true
	-- Pick timer: drain the bar, then hide (the server auto-picks the first card for us at zero).
	local secs = math.max(1, tonumber(info.seconds) or 12)
	timerFill.Size = UDim2.fromScale(1, 1)
	TweenService:Create(timerFill, TweenInfo.new(secs, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) }):Play()
	task.delay(secs, function()
		if myTok == windowToken then
			gui.Enabled = false
		end
	end)
end

function PowerDraftController.Start()
	buildRoot()
	Remotes.Get("DraftOffer").OnClientEvent:Connect(showOffer)
	print("[PowerDraftController] started")
end

return PowerDraftController
