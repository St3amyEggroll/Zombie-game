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
local TweenService = game:GetService("TweenService")

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(SharedFolder.Modules.Remotes)
local UITheme = require(SharedFolder.Modules.UITheme)
local GameConfig = require(SharedFolder.Config.GameConfig)

local SpectateController = {}

local localPlayer = Players.LocalPlayer

local downedSet = {}       -- [userId] = true — server-broadcast down state (so we skip downed teammates)
local spectating = false
local targetPlayer = nil
local panel, nameLabel
local vignette, diedLabel, diedSub, deathToken = nil, nil, nil, 0
local wipeLabel, wipeTick = nil, 0 -- the "RUN ENDS IN Ns" line + its countdown token
local reviveBtn, wipeLeaveBtn -- the wipe pair: green REVIVE + red LEAVE (visible only during the grace)
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
			nameLabel.Text = "WATCHING: " .. pl.DisplayName:upper()
		end
	end
end

-- Move to another live teammate. dir = -1 / +1 to step, 0 to (re)pick the current-or-first valid target.
local function cycle(dir: number)
	local list = liveTargets()
	if #list == 0 then
		if nameLabel and nameLabel.Text ~= "NO TEAMMATES LEFT" then
			nameLabel.Text = "NO TEAMMATES LEFT"
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
local KEEP = { GunShop = true, Settings = true, SettingsModal = true, Spectate = true, HotbarHUD = true,
	PartyHUD = true } -- teammate health rings STAY visible — "last one down ends the run" needs them most here
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

local enterDeathFx -- assigned in Start() once build() has made the vignette

local function enter()
	if spectating then
		return
	end
	spectating = true
	hideHud() -- leave only the settings/showcase layers (+ this overlay)
	if panel then
		panel.Visible = true
	end
	if enterDeathFx then
		enterDeathFx()
	end
	cycle(0)
end

local function exit()
	if not spectating then
		return
	end
	spectating = false
	deathToken += 1 -- cancel any pending fade
	if panel then
		panel.Visible = false
	end
	if vignette then
		vignette.Visible = false
	end
	-- Hand the crosshair back its cursor (see CrosshairController's NeedsCursor check).
	Players.LocalPlayer:SetAttribute("NeedsCursor", nil)
	restoreHud()
	restoreSubject()
end

local function build(playerGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "Spectate"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.Spectate
	gui.Parent = playerGui
	-- CHANGED: fit height 500 -> 390. On a landscape phone the modal-fit scale came out 0.56, which
	-- rendered the WATCHING pill and the REVIVE/LEAVE buttons ~26px tall — under the 36px touch
	-- floor at the exact moment a Robux revive is being sold. 390 keeps them finger-sized.
	UITheme.Attach(gui, 720, 390) -- mobile: death-screen buttons at finger size

	-- Bottom chrome (the approved plan): [ ◀  WATCHING: NAME  ▶ ] pill + red LEAVE RUN beside it.
	panel = Instance.new("Frame")
	panel.Name = "SpectatePanel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -24)
	panel.Size = UDim2.fromOffset(510, 46)
	panel.BackgroundTransparency = 1
	panel.Visible = false
	panel.Parent = gui

	local pill = UITheme.Button(panel, "WATCHING: —", "ghost")
	pill.Name = "WatchPill"
	pill.Position = UDim2.fromOffset(0, 0)
	pill.Size = UDim2.fromOffset(350, 46)
	pill.TextSize = 15
	pill.AutoButtonColor = false
	nameLabel = pill -- cycle() writes pill.Text (the face label mirrors it)

	local function arrow(txt, xPos, dir)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(0, 0.5)
		b.Position = UDim2.new(0, xPos, 0.5, -2)
		b.Size = UDim2.fromOffset(34, 32)
		b.BackgroundTransparency = 1
		b.FontFace = UITheme.TitleFace
		b.TextSize = 20
		b.TextColor3 = UITheme.TOXIC
		b.Text = txt
		b.ZIndex = 8 -- above the pill's face
		b.Parent = pill
		local st = Instance.new("UIStroke")
		st.Color = UITheme.BLACK
		st.Thickness = 2.5
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Parent = b
		b.Activated:Connect(function()
			cycle(dir)
		end)
		return b
	end
	arrow("◀", 8, -1)
	arrow("▶", 350 - 42, 1)

	local leaveBtn = UITheme.Button(panel, "LEAVE RUN", "danger")
	leaveBtn.Name = "SpectateLeave"
	leaveBtn.Position = UDim2.fromOffset(362, 0)
	leaveBtn.Size = UDim2.fromOffset(148, 46)
	leaveBtn.TextSize = 15
	leaveBtn.Activated:Connect(function()
		Remotes.Get("LeaveRun"):FireServer()
	end)

	-- DEATH SCREEN: red vignette creeping in from every edge + the "YOU DIED" sticker slam.
	vignette = Instance.new("Frame")
	vignette.Name = "DeathVignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundTransparency = 1
	vignette.Visible = false
	vignette.Parent = gui
	local RED = Color3.fromRGB(140, 16, 10)
	local function edge(edgeName, pos, size, rot)
		local f = Instance.new("Frame")
		f.Name = edgeName
		f.Position = pos
		f.Size = size
		f.BackgroundColor3 = RED
		f.BorderSizePixel = 0
		f.Parent = vignette
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({ -- solid at the screen edge, gone toward the middle
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Rotation = rot
		g.Parent = f
		return f
	end
	edge("Top", UDim2.new(), UDim2.new(1, 0, 0.22, 0), 90)
	edge("Bottom", UDim2.new(0, 0, 0.78, 0), UDim2.new(1, 0, 0.22, 0), -90)
	edge("Left", UDim2.new(), UDim2.new(0.14, 0, 1, 0), 0)
	edge("Right", UDim2.new(0.86, 0, 0, 0), UDim2.new(0.14, 0, 1, 0), 180)

	diedLabel = Instance.new("TextLabel")
	diedLabel.Name = "YouDied"
	diedLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	diedLabel.Position = UDim2.fromScale(0.5, 0.38)
	diedLabel.Size = UDim2.fromOffset(600, 64)
	diedLabel.BackgroundTransparency = 1
	diedLabel.FontFace = UITheme.TitleFace
	diedLabel.TextSize = 52
	diedLabel.TextColor3 = Color3.fromRGB(255, 96, 76)
	diedLabel.Text = "YOU DIED"
	diedLabel.Parent = vignette
	local ds = Instance.new("UIStroke")
	ds.Color = UITheme.BLACK
	ds.Thickness = 4
	ds.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ds.Parent = diedLabel
	Instance.new("UIScale").Parent = diedLabel

	diedSub = Instance.new("TextLabel")
	diedSub.Name = "YouDiedSub"
	diedSub.AnchorPoint = Vector2.new(0.5, 0)
	diedSub.Position = UDim2.fromScale(0.5, 0.46)
	diedSub.Size = UDim2.fromOffset(500, 22)
	diedSub.BackgroundTransparency = 1
	diedSub.FontFace = UITheme.BodyBoldFace
	diedSub.TextSize = 16
	diedSub.TextColor3 = UITheme.TEXT
	diedSub.Text = "SPECTATING YOUR TEAM — LAST ONE DOWN ENDS THE RUN"
	diedSub.Parent = vignette
	local ss = Instance.new("UIStroke")
	ss.Color = UITheme.BLACK
	ss.Thickness = 2.5
	ss.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ss.Parent = diedSub

	-- THE WIPE PAIR (owner call): during the full-wipe grace window a GREEN REVIVE and a RED LEAVE sit
	-- side by side under YOU DIED — always built (no product id needed to see them; without an id the
	-- revive warns in Output instead of prompting). Hidden outside the wipe window (spectate keeps its
	-- own smaller LEAVE RUN in the top strip).
	reviveBtn = UITheme.Button(vignette, "REVIVE", "primary") -- green
	reviveBtn.Name = "ReviveButton"
	reviveBtn.AnchorPoint = Vector2.new(1, 0)
	reviveBtn.Position = UDim2.new(0.5, -8, 0.55, 0)
	reviveBtn.Size = UDim2.fromOffset(210, 56)
	reviveBtn.TextSize = 20
	reviveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	reviveBtn.Visible = false
	reviveBtn.Activated:Connect(function()
		local id = tonumber(GameConfig.ReviveProductId) or 0
		if id > 0 then
			MarketplaceService:PromptProductPurchase(localPlayer, id)
		else
			warn("[Spectate] REVIVE: set GameConfig.ReviveProductId to your Developer Product id")
		end
	end)
	task.spawn(function() -- live Robux price on the button once the id is set
		local id = tonumber(GameConfig.ReviveProductId) or 0
		if id > 0 then
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
			end)
			if ok and info and tonumber(info.PriceInRobux) then
				reviveBtn.Text = ("REVIVE — R$%d"):format(info.PriceInRobux)
			end
		end
	end)

	wipeLeaveBtn = UITheme.Button(vignette, "LEAVE", "danger") -- red
	wipeLeaveBtn.Name = "WipeLeaveButton"
	wipeLeaveBtn.AnchorPoint = Vector2.new(0, 0)
	wipeLeaveBtn.Position = UDim2.new(0.5, 8, 0.55, 0)
	wipeLeaveBtn.Size = UDim2.fromOffset(210, 56)
	wipeLeaveBtn.TextSize = 20
	wipeLeaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	wipeLeaveBtn.Visible = false
	wipeLeaveBtn.Activated:Connect(function()
		Remotes.Get("LeaveRun"):FireServer()
	end)
	wipeLabel = Instance.new("TextLabel")
	wipeLabel.Name = "WipeCountdown"
	wipeLabel.AnchorPoint = Vector2.new(0.5, 0)
	wipeLabel.Position = UDim2.fromScale(0.5, 0.64)
	wipeLabel.Size = UDim2.fromOffset(400, 24)
	wipeLabel.BackgroundTransparency = 1
	wipeLabel.FontFace = UITheme.TitleFace
	wipeLabel.TextSize = 20
	wipeLabel.TextColor3 = Color3.fromRGB(255, 96, 76)
	wipeLabel.Text = ""
	wipeLabel.Visible = false
	wipeLabel.Parent = vignette
	local ws = Instance.new("UIStroke")
	ws.Color = UITheme.BLACK
	ws.Thickness = 2.5
	ws.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ws.Parent = wipeLabel
end

-- The death moment: slam the sticker in over the vignette, then fade the words out and leave a faint
-- red rim while spectating. Cancelled cleanly by exit() (respawn / run end).
local function showDeathScreen()
	if not vignette then
		return
	end
	deathToken += 1
	local my = deathToken
	vignette.Visible = true
	-- The death screen is a CLICKABLE screen (REVIVE / LEAVE): ask for the real cursor back, the
	-- crosshair gets out of the way. Without this the buttons sat under an invisible mouse.
	Players.LocalPlayer:SetAttribute("NeedsCursor", true)
	for _, f in vignette:GetChildren() do
		if f:IsA("Frame") then
			f.BackgroundTransparency = 0
		end
	end
	local st = diedLabel:FindFirstChildOfClass("UIStroke")
	local sst = diedSub:FindFirstChildOfClass("UIStroke")
	diedLabel.TextTransparency = 0
	diedSub.TextTransparency = 0
	if st then
		st.Transparency = 0
	end
	if sst then
		sst.Transparency = 0
	end
	local sc = diedLabel:FindFirstChildOfClass("UIScale")
	if sc then
		sc.Scale = 1.6
		TweenService:Create(sc, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	task.delay(2.4, function()
		if deathToken ~= my or not vignette.Visible then
			return
		end
		-- Words fade; the rim thins to a faint reminder while spectating.
		TweenService:Create(diedLabel, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		TweenService:Create(diedSub, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		if st then
			TweenService:Create(st, TweenInfo.new(0.5), { Transparency = 1 }):Play()
		end
		if sst then
			TweenService:Create(sst, TweenInfo.new(0.5), { Transparency = 1 }):Play()
		end
		for _, f in vignette:GetChildren() do
			if f:IsA("Frame") then
				TweenService:Create(f, TweenInfo.new(0.8), { BackgroundTransparency = 0.55 }):Play()
			end
		end
	end)
end

function SpectateController.Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	playerGuiRef = playerGui
	build(playerGui)
	enterDeathFx = showDeathScreen

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

	-- NEW: the server holds a full team wipe open for a few seconds so someone can buy the Robux
	-- revive — tick the "RUN ENDS IN Ns" line while it does (0 = a revive landed, hide it).
	Remotes.Get("WipeCountdown").OnClientEvent:Connect(function(secs)
		wipeTick += 1
		local my = wipeTick
		secs = math.floor(tonumber(secs) or 0)
		if not wipeLabel then
			return
		end
		if secs <= 0 then
			wipeLabel.Visible = false
			if reviveBtn then
				reviveBtn.Visible = false
				wipeLeaveBtn.Visible = false
			end
			return
		end
		wipeLabel.Visible = true
		if reviveBtn then -- the wipe pair appears for exactly the grace window
			reviveBtn.Visible = true
			wipeLeaveBtn.Visible = true
		end
		task.spawn(function()
			for left = secs, 1, -1 do
				if wipeTick ~= my then
					return
				end
				wipeLabel.Text = ("RUN ENDS IN %ds — REVIVE TO KEEP GOING"):format(left)
				task.wait(1)
			end
			if wipeTick == my then
				wipeLabel.Visible = false
			end
		end)
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
