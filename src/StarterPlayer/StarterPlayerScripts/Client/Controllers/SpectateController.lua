--!nonstrict
-- SpectateController.lua — while you're DOWNED (bleeding out, waiting for a teammate to revive you), let the
-- camera follow a living teammate instead of your own crawling body. ◄ / ► (or the arrow keys) cycle targets.
-- Auto-exits the instant you're revived. Pure client camera work: Roblox's Classic camera follows
-- Camera.CameraSubject, so spectating is just swapping that subject — no scriptable-camera fight, no server call.
--
-- Drives off DownedChanged (server broadcast: userId, isDowned, bleedEnds). We also track OTHER players' down
-- state from the same broadcast so we only ever point the camera at a teammate who is actually up and fighting.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(SharedFolder.Modules.Remotes)
local UITheme = require(SharedFolder.Modules.UITheme)

local SpectateController = {}

local localPlayer = Players.LocalPlayer

local downedSet = {}       -- [userId] = true — server-broadcast down state (so we skip downed teammates)
local spectating = false
local targetPlayer = nil
local panel, nameLabel
local playerGuiRef = nil

-- A player is a valid spectate target if it isn't me, isn't downed, and has a living character.
local function isLive(pl): boolean
	if pl == nil or pl == localPlayer then
		return false
	end
	if downedSet[pl.UserId] then
		return false
	end
	local char = pl.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return hum ~= nil and root ~= nil and hum.Health > 0
end

local function liveTargets()
	local list = {}
	for _, pl in Players:GetPlayers() do
		if isLive(pl) then
			table.insert(list, pl)
		end
	end
	table.sort(list, function(a, b)
		return a.UserId < b.UserId
	end)
	return list
end

local function restoreSubject()
	local cam = Workspace.CurrentCamera
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if cam and hum then
		cam.CameraSubject = hum
	end
	targetPlayer = nil
end

local function setSubject(pl)
	local cam = Workspace.CurrentCamera
	local char = pl and pl.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if cam and hum then
		cam.CameraSubject = hum
		targetPlayer = pl
		if nameLabel then
			nameLabel.Text = "SPECTATING  " .. pl.DisplayName
		end
	end
end

-- Move to another live teammate. dir = -1 / +1 to step, 0 to (re)pick the current-or-first valid target.
local function cycle(dir: number)
	local list = liveTargets()
	if #list == 0 then
		if nameLabel and nameLabel.Text ~= "NO TEAMMATES TO SPECTATE" then
			nameLabel.Text = "NO TEAMMATES TO SPECTATE"
		end
		restoreSubject()
		return
	end
	local idx = 1
	for i, pl in list do
		if pl == targetPlayer then
			idx = i
			break
		end
	end
	idx = ((idx - 1 + dir) % #list) + 1
	setSubject(list[idx])
end

-- While spectating we strip the HUD down to just the menu buttons. Keep = ScreenGuis that stay on.
local KEEP = { GunShop = true, Settings = true, Spectate = true, HotbarHUD = true }
local hiddenGuis = {}   -- gui -> its prior .Enabled
local hiddenSlots = nil -- the hotbar's gun-slot row (hidden, but the CASES button beside it stays)

local function hideHud()
	if not playerGuiRef then
		return
	end
	for _, g in playerGuiRef:GetChildren() do
		if g:IsA("ScreenGui") and not KEEP[g.Name] and hiddenGuis[g] == nil then
			hiddenGuis[g] = g.Enabled
			g.Enabled = false
		end
	end
	-- Hotbar stays enabled for its CASES button; hide only the two gun slots.
	local hb = playerGuiRef:FindFirstChild("HotbarHUD")
	local slots = hb and hb:FindFirstChild("Slots")
	if slots then
		hiddenSlots = slots
		slots.Visible = false
	end
end

local function restoreHud()
	for g, enabled in hiddenGuis do
		if g and g.Parent then
			g.Enabled = enabled
		end
	end
	hiddenGuis = {}
	if hiddenSlots and hiddenSlots.Parent then
		hiddenSlots.Visible = true
	end
	hiddenSlots = nil
end

local function enter()
	if spectating then
		return
	end
	spectating = true
	hideHud() -- leave only GUNS / CASES / Settings (+ this overlay)
	if panel then
		panel.Visible = true
	end
	cycle(0)
end

local function exit()
	if not spectating then
		return
	end
	spectating = false
	if panel then
		panel.Visible = false
	end
	restoreHud()
	restoreSubject()
end

local function build(playerGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "Spectate"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 11
	gui.Parent = playerGui
	UITheme.Attach(gui)

	panel = UITheme.Panel(gui, "SpectatePanel", { alpha = 0.1 })
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -24)
	panel.Size = UDim2.fromOffset(360, 58)
	panel.Visible = false

	local function arrow(txt, ax, pos)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(ax, 0.5)
		b.Position = pos
		b.Size = UDim2.fromOffset(44, 40)
		b.BackgroundColor3 = UITheme.PANEL2
		b.BorderSizePixel = 0
		b.FontFace = UITheme.TitleFace
		b.TextSize = 22
		b.TextColor3 = UITheme.TOXIC
		b.Text = txt
		b.Parent = panel
		UITheme.Corner(b, 8)
		UITheme.Edge(b, UITheme.BLACK, 2)
		return b
	end
	local prevBtn = arrow("◄", 0, UDim2.new(0, 8, 0.5, 0))
	local nextBtn = arrow("►", 1, UDim2.new(1, -8, 0.5, 0))

	nameLabel = UITheme.Label(panel, "Name", 15, UITheme.TEXT, true)
	nameLabel.AnchorPoint = Vector2.new(0.5, 0)
	nameLabel.Position = UDim2.new(0.5, 0, 0, 9)
	nameLabel.Size = UDim2.new(1, -110, 0, 22)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.Text = "SPECTATING"

	local hint = UITheme.Label(panel, "Hint", 11, UITheme.DIM, true)
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -7)
	hint.Size = UDim2.new(1, -110, 0, 14)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.Text = "◄ ►  /  arrow keys"

	prevBtn.Activated:Connect(function()
		cycle(-1)
	end)
	nextBtn.Activated:Connect(function()
		cycle(1)
	end)
end

function SpectateController.Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	playerGuiRef = playerGui
	build(playerGui)

	Remotes.Get("DownedChanged").OnClientEvent:Connect(function(userId, isDowned)
		downedSet[userId] = isDowned and true or nil
		if userId == localPlayer.UserId then
			if isDowned then
				enter()
			else
				exit()
			end
		elseif spectating and targetPlayer and targetPlayer.UserId == userId and isDowned then
			cycle(1) -- the teammate we were watching just went down — move to someone still up
		end
	end)

	-- Any time I get a fresh character (respawn / revive land), make sure the camera is mine again.
	localPlayer.CharacterAdded:Connect(function()
		exit()
	end)

	-- Keep the view on a valid target: if the one we're watching dies or leaves, re-pick (cheap — only
	-- runs while spectating and only when the current target has gone invalid).
	RunService.Heartbeat:Connect(function()
		if not spectating then
			return
		end
		if targetPlayer ~= nil and isLive(targetPlayer) then
			return
		end
		cycle(0)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not spectating or gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Left then
			cycle(-1)
		elseif input.KeyCode == Enum.KeyCode.Right then
			cycle(1)
		end
	end)

	print("[SpectateController] started")
end

return SpectateController
