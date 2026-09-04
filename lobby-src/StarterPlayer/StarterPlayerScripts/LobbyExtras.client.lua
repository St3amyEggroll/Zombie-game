--!nonstrict
-- LobbyExtras.client.lua — launch-pass lobby additions kept OUT of LobbyClient.client.lua (that file
-- sits at Luau's 200-local ceiling). It never reaches into LobbyClient's internals; it only reads the
-- LobbyRemotes folder + PlayerGui. Three things:
--   1) INVITE circle — under the QUESTS circle on the left edge. Roblox's own invite prompt; the
--      sticker advertises the friend bonus (+25% Coins with a friend in the server — the game
--      place's GameConfig.FriendCoinMult; FRIEND_BONUS_PCT below is the label only).
--   2) RUN RECAP card — the run you just finished (wave / kills / coins). On a NEW PERSONAL BEST it
--      adds a soft "enjoying it? a thumbs-up helps" nudge (Roblox has no like-prompt API — this is
--      words only). Fed by the server's RunRecap remote; asks for it once the UI is up.
--   3) WHAT'S NEW board — every BasePart tagged "UpdateBoard" gets a SurfaceGui listing UPDATES.
--      OWNER: edit UPDATES on each release; tag a flat sign part (~12x7 studs) in the lobby map.
--      Optional attribute `Face` = "Front" | "Back" | "Left" | "Right" | "Top" | "Bottom" (default Front).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("LobbyRemotes")
local RunRecap = remotes:WaitForChild("RunRecap")

-- ===== TUNABLES =====
local FRIEND_BONUS_PCT = 25     -- label only (the real number is GameConfig.FriendCoinMult in the game place)
local INVITE_SIZE = 64          -- same circle as the QUESTS launcher
local INVITE_BELOW_QUESTS = 96  -- px below the QUESTS circle's centre (its label sits ~+50)
local RECAP_SECONDS = 14        -- the recap card auto-hides after this
local RECAP_TOP = 150           -- px from the top of the screen (under the squad strip)
local BOARD_PX_PER_STUD = 60    -- SurfaceGui resolution for the WHAT'S NEW sign

-- ===== WHAT'S NEW (owner-edited; newest first) =====
local UPDATES = {
	{ date = "SEP 2026", title = "LAUNCH PASS", lines = {
		"FRIEND BONUS: +25% Coins with a friend in your server",
		"Badges, touch controls, and this run recap",
		"Blizzard, rain and lightning storms renovated",
	} },
	{ date = "AUG 2026", title = "THE EVENT REEL", lines = {
		"The wave roller is a vertical reel with live odds",
		"Titles tab, crate popups, daily wheel redone",
	} },
}

-- ===== THEME (mirrors LobbyClient's palette) =====
local PANEL = Color3.fromRGB(21, 24, 17)
local CARD = Color3.fromRGB(29, 33, 23)
local TBLACK = Color3.fromRGB(6, 7, 5)
local ACCENT = Color3.fromRGB(124, 219, 35)
local ORANGE = Color3.fromRGB(255, 96, 34)
local GOLD = Color3.fromRGB(255, 196, 40)
local TEXTCOL = Color3.fromRGB(222, 227, 209)
local DIMTEXT = Color3.fromRGB(134, 142, 116)
local TITLE_FACE = Font.new(Font.fromEnum(Enum.Font.FredokaOne).Family, Enum.FontWeight.Regular)
local BODY_FACE = Font.new(Font.fromEnum(Enum.Font.GothamMedium).Family, Enum.FontWeight.Medium)

local function corner(o: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
	return c
end

local function ledge(o: Instance, color: Color3?, thickness: number?, transparency: number?)
	local st = Instance.new("UIStroke")
	st.Color = color or TBLACK
	st.Thickness = thickness or 2
	st.Transparency = transparency or 0
	st.Parent = o
	return st
end

local function sticker(parent: Instance, str: string, size: number, colr: Color3?, face: Font?)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = face or TITLE_FACE
	l.TextSize = size
	l.TextColor3 = colr or TEXTCOL
	l.Text = str
	l.ZIndex = 5
	local st = Instance.new("UIStroke")
	st.Color = TBLACK
	st.Thickness = math.clamp(size / 8, 1.5, 3)
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	st.Parent = l
	l.Parent = parent
	return l
end

local function fmt(n: number): string
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Responsive scale: MIRROR the quest launcher's UIScale so the two circles always match (LobbyClient's
-- lattach "hud" mode); fall back to the same formula if that gui never shows up.
local function mirrorScale(gui: ScreenGui)
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Parent = gui
	task.spawn(function()
		local quests = playerGui:WaitForChild("LobbyQuests", 10)
		local src = quests and quests:WaitForChild("ResponsiveScale", 5)
		if src and src:IsA("UIScale") then
			scale.Scale = src.Scale
			src:GetPropertyChangedSignal("Scale"):Connect(function()
				scale.Scale = src.Scale
			end)
			return
		end
		local function compute(): number
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
			local mobile = UserInputService.TouchEnabled and (not UserInputService.MouseEnabled or vp.Y < 600)
			if mobile then
				return math.clamp(vp.Y / 780, 0.5, 2.2)
			end
			return math.clamp(math.min(vp.X / 1920, vp.Y / 1080), 0.7, 1.3)
		end
		scale.Scale = compute()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				scale.Scale = compute()
			end)
		end
	end)
	return scale
end

-- =====================================================================================================
-- 1) INVITE circle
-- =====================================================================================================
do
	local gui = Instance.new("ScreenGui")
	gui.Name = "LobbyInvite"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 12 -- same layer as the QUESTS launcher
	gui.Enabled = false   -- shown once Roblox confirms invites can be sent from here
	gui.Parent = playerGui
	mirrorScale(gui)

	local btn = Instance.new("TextButton")
	btn.Name = "InviteRail"
	btn.AnchorPoint = Vector2.new(0, 0.5)
	btn.Position = UDim2.new(0, 14, 0.5, INVITE_BELOW_QUESTS)
	btn.Size = UDim2.fromOffset(INVITE_SIZE, INVITE_SIZE)
	btn.BackgroundColor3 = CARD
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.FontFace = TITLE_FACE
	btn.TextSize = 30
	btn.TextColor3 = ACCENT
	btn.Text = "+"
	btn.Parent = gui
	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0) -- full circle
		c.Parent = btn
	end
	ledge(btn, TBLACK, 2.5)
	local lbl = sticker(btn, "INVITE", 13, Color3.fromRGB(217, 247, 184))
	lbl.AnchorPoint = Vector2.new(0.5, 0)
	lbl.Position = UDim2.new(0.5, 0, 1, 2)
	lbl.Size = UDim2.fromOffset(80, 16)
	-- The pitch: a tiny gold tag on the shoulder.
	local tag = Instance.new("TextLabel")
	tag.AnchorPoint = Vector2.new(0, 0.5)
	tag.Position = UDim2.new(1, 6, 0.5, 0)
	tag.Size = UDim2.fromOffset(112, 22)
	tag.BackgroundColor3 = GOLD
	tag.BorderSizePixel = 0
	tag.FontFace = TITLE_FACE
	tag.TextSize = 12
	tag.TextColor3 = TBLACK
	tag.Text = ("+%d%% COINS W/ FRIEND"):format(FRIEND_BONUS_PCT)
	tag.ZIndex = 6
	tag.Parent = btn
	corner(tag, 6)
	ledge(tag, TBLACK, 1.5)

	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(localPlayer)
		end)
		gui.Enabled = ok and can == true
	end)
	btn.Activated:Connect(function()
		local ok, err = pcall(function()
			SocialService:PromptGameInvite(localPlayer)
		end)
		if not ok then
			warn("[LobbyExtras] invite prompt failed: " .. tostring(err))
		end
	end)
end

-- =====================================================================================================
-- 2) RUN RECAP card
-- =====================================================================================================
do
	local gui = Instance.new("ScreenGui")
	gui.Name = "LobbyRunRecap"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 14
	gui.Parent = playerGui
	mirrorScale(gui)

	local W, H = 440, 132
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, RECAP_TOP)
	card.Size = UDim2.fromOffset(W, H)
	card.BackgroundColor3 = PANEL
	card.BorderSizePixel = 0
	card.Visible = false
	card.Parent = gui
	corner(card, 14)
	ledge(card, TBLACK, 3)
	local pop = Instance.new("UIScale")
	pop.Parent = card

	local kicker = sticker(card, "LAST RUN", 13, DIMTEXT)
	kicker.Position = UDim2.fromOffset(18, 10)
	kicker.Size = UDim2.fromOffset(200, 16)
	kicker.TextXAlignment = Enum.TextXAlignment.Left

	local wave = sticker(card, "WAVE 0", 36, ACCENT)
	wave.Position = UDim2.fromOffset(18, 26)
	wave.Size = UDim2.fromOffset(240, 40)
	wave.TextXAlignment = Enum.TextXAlignment.Left

	local sub = sticker(card, "", 15, TEXTCOL)
	sub.Position = UDim2.fromOffset(18, 68)
	sub.Size = UDim2.new(1, -36, 0, 18)
	sub.TextXAlignment = Enum.TextXAlignment.Left

	local best = sticker(card, "NEW PERSONAL BEST!", 15, GOLD)
	best.AnchorPoint = Vector2.new(1, 0)
	best.Position = UDim2.new(1, -18, 0, 30)
	best.Size = UDim2.fromOffset(190, 18)
	best.TextXAlignment = Enum.TextXAlignment.Right

	local nudge = sticker(card, "", 13, DIMTEXT, BODY_FACE)
	nudge.Position = UDim2.fromOffset(18, 92)
	nudge.Size = UDim2.new(1, -36, 0, 30)
	nudge.TextXAlignment = Enum.TextXAlignment.Left
	nudge.TextWrapped = true

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 8)
	closeBtn.Size = UDim2.fromOffset(24, 24)
	closeBtn.BackgroundColor3 = Color3.fromRGB(224, 28, 14)
	closeBtn.BorderSizePixel = 0
	closeBtn.FontFace = TITLE_FACE
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Text = "✕"
	closeBtn.ZIndex = 6
	closeBtn.Parent = card
	corner(closeBtn, 8)
	ledge(closeBtn, TBLACK, 1.5)

	local shownId = nil
	local hideToken = 0
	local function hide()
		hideToken += 1
		card.Visible = false
	end
	closeBtn.Activated:Connect(hide)

	local function show(r)
		if typeof(r) ~= "table" then
			return
		end
		local id = tostring(r.id or "")
		if id ~= "" and id == shownId then
			return -- the join-time push AND our re-request both landed: show it once
		end
		shownId = id
		local w = math.floor(tonumber(r.wave) or 0)
		if w <= 0 then
			return
		end
		wave.Text = ("WAVE %d"):format(w)
		sub.Text = ("%s KILLS   +%s COINS   ·   BEST: WAVE %d"):format(fmt(tonumber(r.kills) or 0), fmt(tonumber(r.money) or 0), math.floor(tonumber(r.best) or w))
		local isBest = r.newBest == true
		best.Visible = isBest
		if isBest then
			nudge.Text = "New record! Enjoying ZombieRot? A 👍 on the game page helps a ton — and a friend in your server pays +" .. FRIEND_BONUS_PCT .. "% Coins."
		else
			nudge.Text = "Beat it next run — a friend in your server pays +" .. FRIEND_BONUS_PCT .. "% Coins."
		end
		card.Visible = true
		pop.Scale = 0.85
		TweenService:Create(pop, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		hideToken += 1
		local myToken = hideToken
		task.delay(RECAP_SECONDS, function()
			if myToken == hideToken then
				card.Visible = false
			end
		end)
	end

	RunRecap.OnClientEvent:Connect(show)
	task.delay(2, function()
		RunRecap:FireServer() -- our handlers are live now: re-ask (the join-time push may have beaten us)
	end)
end

-- =====================================================================================================
-- 3) WHAT'S NEW board (tag: UpdateBoard)
-- =====================================================================================================
do
	local function faceOf(part: BasePart): Enum.NormalId
		local f = part:GetAttribute("Face")
		if typeof(f) == "string" then
			local ok, e = pcall(function()
				return Enum.NormalId[f]
			end)
			if ok and e then
				return e
			end
		end
		return Enum.NormalId.Front
	end

	local function build(part: Instance)
		if not part:IsA("BasePart") or part:FindFirstChild("UpdateBoardGui") then
			return
		end
		local sg = Instance.new("SurfaceGui")
		sg.Name = "UpdateBoardGui"
		sg.Face = faceOf(part)
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = BOARD_PX_PER_STUD
		sg.LightInfluence = 0
		sg.Brightness = 1.2
		sg.Parent = part

		local bg = Instance.new("Frame")
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = PANEL
		bg.BorderSizePixel = 0
		bg.Parent = sg
		local pad = Instance.new("UIPadding")
		pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 18), UDim.new(0, 18)
		pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 26), UDim.new(0, 26)
		pad.Parent = bg
		local list = Instance.new("UIListLayout")
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, 8)
		list.Parent = bg

		local head = sticker(bg, "WHAT'S NEW", 40, ACCENT)
		head.Size = UDim2.new(1, 0, 0, 44)
		head.TextXAlignment = Enum.TextXAlignment.Left
		head.LayoutOrder = 0

		local order = 1
		for _, u in UPDATES do
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 34 + 26 * #u.lines)
			row.LayoutOrder = order
			row.Parent = bg
			order += 1
			local t = sticker(row, u.title, 28, GOLD)
			t.Position = UDim2.fromOffset(0, 0)
			t.Size = UDim2.new(1, -140, 0, 30)
			t.TextXAlignment = Enum.TextXAlignment.Left
			local d = sticker(row, u.date, 18, DIMTEXT)
			d.AnchorPoint = Vector2.new(1, 0)
			d.Position = UDim2.new(1, 0, 0, 6)
			d.Size = UDim2.fromOffset(130, 20)
			d.TextXAlignment = Enum.TextXAlignment.Right
			for i, line in u.lines do
				local l = sticker(row, "• " .. line, 21, TEXTCOL, BODY_FACE)
				l.Position = UDim2.fromOffset(6, 32 + (i - 1) * 26)
				l.Size = UDim2.new(1, -6, 0, 24)
				l.TextXAlignment = Enum.TextXAlignment.Left
				l.TextTruncate = Enum.TextTruncate.AtEnd
			end
		end
	end

	for _, part in CollectionService:GetTagged("UpdateBoard") do
		build(part)
	end
	CollectionService:GetInstanceAddedSignal("UpdateBoard"):Connect(build)
end

print("[LobbyExtras] started (invite circle · run recap · what's-new board)")
