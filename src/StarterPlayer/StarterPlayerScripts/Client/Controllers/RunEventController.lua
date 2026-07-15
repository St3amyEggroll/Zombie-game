--!nonstrict
-- RunEventController.lua — client side of the run's SURPRISES:
--   • RunEvent "announce" → the HUD announcement lane (event names ride the same queue as boss banners).
--   • RunEvent "fog"      → thick Lighting fog rolls in for a while, then burns back off (local FX only).
--   • ExtractWindow       → THE choice: a centered CASH OUT (bank pot × multiplier, leave) vs DOUBLE DOWN
--                           (dismiss; the multiplier climbs) card with a live countdown.
--   • ExtractMult         → "DOUBLED DOWN" confirmation once the window closes for the stayers.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)

local HUDController = require(script.Parent.HUDController)

local RunEventController = {}

-- ===== TUNABLES =====
local FOG_END = 90            -- how close the fog closes in (studs)
local FOG_TWEEN = 3           -- seconds to roll in / burn off
local ANNOUNCE_SECONDS = 4

local COLORS = {
	gold = Color3.fromRGB(240, 196, 82),
	green = Color3.fromRGB(124, 219, 35),
	red = Color3.fromRGB(255, 96, 34),
	grey = Color3.fromRGB(180, 186, 168),
}

local localPlayer = Players.LocalPlayer

-- ===== FOG =====
local fogToken = 0
local function rollFog(seconds: number)
	fogToken += 1
	local myTok = fogToken
	local oldEnd, oldStart = Lighting.FogEnd, Lighting.FogStart
	local oldColor = Lighting.FogColor
	Lighting.FogColor = Color3.fromRGB(120, 128, 112)
	TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = FOG_END, FogStart = 12 }):Play()
	task.delay(math.max(1, seconds), function()
		if myTok ~= fogToken then
			return -- a newer fog event owns the Lighting now
		end
		local out = TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = oldEnd, FogStart = oldStart })
		out.Completed:Once(function()
			if myTok == fogToken then
				Lighting.FogColor = oldColor
			end
		end)
		out:Play()
	end)
end

-- ===== EXTRACTION CARD =====
local gui, panel, potLabel, timeLabel, stayNote
local countdownToken = 0

local function fmt(n: number): string
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function buildUI()
	gui = Instance.new("ScreenGui")
	gui.Name = "ExtractPrompt"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer and UITheme.Layer.Modal or 30
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui)

	panel = UITheme.Panel(gui, "ExtractPanel")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.42)
	panel.Size = UDim2.fromOffset(420, 240)
	UITheme.Header(panel, "EXTRACTION", nil, UITheme.GOLD)

	potLabel = UITheme.Title(panel, "Pot", 24)
	potLabel.Position = UDim2.fromOffset(0, 62)
	potLabel.Size = UDim2.new(1, 0, 0, 30)
	potLabel.TextXAlignment = Enum.TextXAlignment.Center

	timeLabel = UITheme.Label(panel, "Clock", 16, nil, true)
	timeLabel.Position = UDim2.fromOffset(0, 94)
	timeLabel.Size = UDim2.new(1, 0, 0, 20)
	timeLabel.TextXAlignment = Enum.TextXAlignment.Center

	local cash = UITheme.Button(panel, "CASH OUT", "primary")
	cash.AnchorPoint = Vector2.new(0.5, 1)
	cash.Position = UDim2.new(0.5, 0, 1, -66)
	cash.Size = UDim2.new(1, -32, 0, 52)
	cash.Activated:Connect(function()
		Remotes.Get("ExtractChoice"):FireServer()
		gui.Enabled = false -- the server banks + teleports; hide immediately so it can't double-fire
	end)

	local stay = UITheme.Button(panel, "DOUBLE DOWN", "danger")
	stay.AnchorPoint = Vector2.new(0.5, 1)
	stay.Position = UDim2.new(0.5, 0, 1, -12)
	stay.Size = UDim2.new(1, -32, 0, 46)
	stay.Activated:Connect(function()
		gui.Enabled = false -- staying is the default: just dismiss (the window closing doubles you down)
	end)

	stayNote = UITheme.Label(panel, "StayNote", 13)
	stayNote.Position = UDim2.fromOffset(0, 116)
	stayNote.Size = UDim2.new(1, 0, 0, 18)
	stayNote.TextXAlignment = Enum.TextXAlignment.Center
end

local function showWindow(info)
	local secs = tonumber(info.seconds) or 0
	if secs <= 0 then
		gui.Enabled = false
		return
	end
	local pot = tonumber(info.pot) or 0
	local mult = tonumber(info.mult) or 1
	local nextMult = tonumber(info.nextMult) or (mult + 0.5)
	potLabel.Text = ("CASH OUT: %s COINS  (x%.1f)"):format(fmt(math.floor(pot * mult)), mult)
	stayNote.Text = ("or DOUBLE DOWN — payout climbs to x%.1f"):format(nextMult)
	gui.Enabled = true
	countdownToken += 1
	local myTok = countdownToken
	task.spawn(function()
		local deadline = os.clock() + secs
		while gui.Enabled and myTok == countdownToken do
			local left = deadline - os.clock()
			if left <= 0 then
				break
			end
			timeLabel.Text = ("horde returns in %ds"):format(math.ceil(left))
			task.wait(0.2)
		end
		if myTok == countdownToken then
			gui.Enabled = false
		end
	end)
end

function RunEventController.Start()
	buildUI()

	Remotes.Get("RunEvent").OnClientEvent:Connect(function(kind, payload)
		payload = typeof(payload) == "table" and payload or {}
		if kind == "announce" and typeof(payload.text) == "string" then
			HUDController.Announce(payload.text, COLORS[payload.color] or COLORS.gold, ANNOUNCE_SECONDS)
		elseif kind == "fog" then
			rollFog(tonumber(payload.seconds) or 25)
		end
	end)

	Remotes.Get("ExtractWindow").OnClientEvent:Connect(function(info)
		if typeof(info) == "table" then
			showWindow(info)
		end
	end)

	Remotes.Get("ExtractMult").OnClientEvent:Connect(function(mult)
		HUDController.Announce(("DOUBLED DOWN — PAYOUT NOW x%.1f"):format(tonumber(mult) or 1), COLORS.gold, 4)
	end)

	print("[RunEventController] started")
end

return RunEventController
