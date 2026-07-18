--!nonstrict
-- LobbyLook.lua — the LOBBY's exact visual builders, extracted so the GAME place renders the SAME
-- buttons and panels (owner: "all the buttons in the game should just be copied. same with the ui
-- that the buttons open"). Everything here is a VERBATIM port from lobby-src/.../LobbyClient.client.lua
-- (fonts, palette, corner/ledge/ldepth/lstuds, redX, chromePanel, dockBtn) — change there, mirror here.

local TweenService = game:GetService("TweenService")

local LobbyLook = {}

-- ===== FONTS ===== (same Creator Store ids as the lobby's FONT_IDS; blank = the same fallbacks)
local FONT_IDS = { Title = "", Body = "" }
local function makeFace(id, weight, fallbackEnum)
	if id and id ~= "" then
		local ok, face = pcall(function()
			return Font.new("rbxassetid://" .. id, weight)
		end)
		if ok and face then
			return face
		end
	end
	return Font.new(Font.fromEnum(fallbackEnum).Family, weight)
end
LobbyLook.TITLE_FACE = makeFace(FONT_IDS.Title, Enum.FontWeight.Regular, Enum.Font.FredokaOne)
LobbyLook.BODY_FACE = makeFace(FONT_IDS.Body, Enum.FontWeight.Medium, Enum.Font.FredokaOne)
LobbyLook.BODYB_FACE = makeFace(FONT_IDS.Body, Enum.FontWeight.Bold, Enum.Font.FredokaOne)

-- ===== PALETTE =====
LobbyLook.PANEL = Color3.fromRGB(21, 24, 17)
LobbyLook.PANEL2 = Color3.fromRGB(29, 33, 23)
LobbyLook.TRACK = Color3.fromRGB(36, 41, 28)
LobbyLook.TBLACK = Color3.fromRGB(6, 7, 5)
LobbyLook.ACCENT = Color3.fromRGB(124, 219, 35)
LobbyLook.ORANGE = Color3.fromRGB(255, 96, 34)
LobbyLook.TEXTCOL = Color3.fromRGB(222, 227, 209)
LobbyLook.DIMTEXT = Color3.fromRGB(134, 142, 116)
LobbyLook.GOLD = Color3.fromRGB(230, 180, 76)
LobbyLook.NAVY = Color3.fromRGB(21, 36, 58)
LobbyLook.STUDS_TEXTURE = "rbxassetid://6965996718"
LobbyLook.HeaderColors = {
	guns = Color3.fromRGB(168, 32, 32),
	cases = Color3.fromRGB(150, 66, 16),
	shop = Color3.fromRGB(140, 100, 22),
	settings = Color3.fromRGB(36, 66, 104),
	play = Color3.fromRGB(42, 82, 20),
	summary = Color3.fromRGB(120, 30, 22),
}

-- ===== PRIMITIVES =====
function LobbyLook.darker(c, f)
	return Color3.new(c.R * (1 - f), c.G * (1 - f), c.B * (1 - f))
end
local darker = LobbyLook.darker

function LobbyLook.corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, math.floor((r or 6) * 1.8 + 2))
	c.Parent = o
end
local corner = LobbyLook.corner

function LobbyLook.ledge(o, color, thickness, transparency)
	local st = Instance.new("UIStroke")
	st.Color = color or LobbyLook.TBLACK
	st.Thickness = thickness or 2
	st.Transparency = transparency or 0
	st.Parent = o
	return st
end
local ledge = LobbyLook.ledge

function LobbyLook.ldepth(o, k)
	local g = Instance.new("UIGradient")
	k = k or 0.22
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1 - k, 1 - k, 1 - k))
	g.Rotation = 90
	g.Parent = o
	return g
end
local ldepth = LobbyLook.ldepth

function LobbyLook.lstuds(frame, tile, transparency)
	frame.ClipsDescendants = true
	local img = Instance.new("ImageLabel")
	img.Name = "Studs"
	img.BackgroundTransparency = 1
	img.Image = LobbyLook.STUDS_TEXTURE
	img.ScaleType = Enum.ScaleType.Tile
	img.TileSize = UDim2.fromOffset(tile or 42, tile or 42)
	img.ImageColor3 = darker(frame.BackgroundColor3, 0.45)
	img.ImageTransparency = transparency or 0.62
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = frame.ZIndex
	img.Parent = frame
	return img
end
local lstuds = LobbyLook.lstuds

-- ===== redX ===== the lobby's juiced close button (drawn cross, hover grow, press squish).
function LobbyLook.redX(parentGui, size, tsize)
	local x = Instance.new("TextButton")
	x.AnchorPoint = Vector2.new(1, 0)
	x.Size = UDim2.fromOffset(size, size)
	x.BackgroundColor3 = Color3.fromRGB(224, 34, 34)
	x.BorderSizePixel = 0
	x.FontFace = LobbyLook.TITLE_FACE
	x.TextSize = tsize
	x.TextColor3 = Color3.fromRGB(255, 255, 255)
	x.Text = "✕"
	x.Parent = parentGui
	corner(x, 6)
	ledge(x, LobbyLook.TBLACK, 2.5)
	x.BackgroundColor3 = Color3.new(1, 1, 1)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(224, 34, 34):Lerp(Color3.new(1, 1, 1), 0.42)),
		ColorSequenceKeypoint.new(0.07, Color3.fromRGB(224, 34, 34):Lerp(Color3.new(1, 1, 1), 0.18)),
		ColorSequenceKeypoint.new(1, darker(Color3.fromRGB(224, 34, 34), 0.28)),
	})
	g.Rotation = 90
	g.Parent = x
	x.Text = ""
	for _, rot in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.new(0.55, 0, 0, math.max(4, math.floor(size / 8)))
		bar.Rotation = rot
		bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		bar.BorderSizePixel = 0
		bar.ZIndex = 20
		bar.Parent = x
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = bar
	end
	do
		local sc = Instance.new("UIScale")
		sc.Parent = x
		local function to(v, t, style)
			TweenService:Create(sc, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = v }):Play()
		end
		x.MouseEnter:Connect(function() to(1.1, 0.09) end)
		x.MouseLeave:Connect(function() to(1, 0.09) end)
		x.MouseButton1Down:Connect(function() to(0.88, 0.05) end)
		x.MouseButton1Up:Connect(function() to(1.1, 0.14, Enum.EasingStyle.Back) end)
	end
	return x
end

-- ===== chromePanel ===== the lobby's panel chrome: fat colored HEADER BAR overhanging the dark body,
-- big white title with the navy outline, the red X inside the bar, pop-open on show.
-- Returns root, body, title, closeX, recolor(c). Callers toggle root.Visible.
function LobbyLook.ChromePanel(parentGui, bodyW, bodyH, colr, titleText)
	local OVER, HDR_H, TUCK = 22, 64, 14
	local root = Instance.new("Frame")
	root.Name = "Chrome" .. titleText:gsub("%s", "")
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(bodyW + OVER * 2, HDR_H - TUCK + bodyH)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = parentGui
	local pop = Instance.new("UIScale")
	pop.Parent = root
	root:GetPropertyChangedSignal("Visible"):Connect(function()
		if root.Visible then
			pop.Scale = 0.92
			TweenService:Create(pop,
				TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(OVER, HDR_H - TUCK)
	body.Size = UDim2.fromOffset(bodyW, bodyH)
	body.BackgroundColor3 = Color3.fromRGB(19, 21, 15)
	body.BackgroundTransparency = 0.08
	body.BorderSizePixel = 0
	body.ZIndex = 1
	body.Parent = root
	corner(body, 8)
	lstuds(body)
	ldepth(body)
	ledge(body, LobbyLook.TBLACK, 3.5)

	local bar = Instance.new("Frame")
	bar.Name = "HeaderBar"
	bar.Size = UDim2.new(1, 0, 0, HDR_H)
	bar.BorderSizePixel = 0
	bar.ClipsDescendants = true
	bar.ZIndex = 3
	bar.Parent = root
	corner(bar, 7)
	ledge(bar, LobbyLook.TBLACK, 3.5)
	bar.BackgroundColor3 = Color3.new(1, 1, 1)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Parent = bar
	local sheen = Instance.new("Frame")
	sheen.Size = UDim2.fromScale(1, 1)
	sheen.BackgroundColor3 = Color3.new(1, 1, 1)
	sheen.BorderSizePixel = 0
	sheen.ZIndex = 3
	sheen.Parent = bar
	local sg = Instance.new("UIGradient")
	sg.Rotation = 20
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(0.55, 0.8),
		NumberSequenceKeypoint.new(0.62, 0.86),
		NumberSequenceKeypoint.new(0.68, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	sg.Parent = sheen
	local function recolor(c)
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, c:Lerp(Color3.new(1, 1, 1), 0.5)),
			ColorSequenceKeypoint.new(0.45, c),
			ColorSequenceKeypoint.new(1, darker(c, 0.3)),
		})
	end
	recolor(colr)

	local title = Instance.new("TextLabel")
	title.Position = UDim2.new(0, 24, 0, 0)
	title.Size = UDim2.new(1, -100, 1, 0)
	title.BackgroundTransparency = 1
	title.FontFace = LobbyLook.TITLE_FACE
	title.TextSize = 40
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.new(1, 1, 1)
	title.ZIndex = 4
	title.Text = titleText
	title.Parent = bar
	local ts = Instance.new("UIStroke")
	ts.Color = LobbyLook.NAVY
	ts.Thickness = 3.5
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = title

	local x = LobbyLook.redX(bar, 46, 24)
	x.AnchorPoint = Vector2.new(1, 0.5)
	x.Position = UDim2.new(1, -9, 0.5, 0)
	x.ZIndex = 4
	return root, body, title, x, recolor
end

-- ===== dockBtn ===== the lobby's dock button, verbatim: 66x84 holder, 64px dark-glass circle with a
-- white rim, the photo round-cropped inside (emoji pops above when there's no photo), Title-case label
-- ON the lower rim, and the hidden red badge. Caller positions the holder (lobby spacing = 83px).
-- Returns holder, circle(ImageButton), badge.
function LobbyLook.DockButton(parent, label, iconId, emoji)
	local holder = Instance.new("Frame")
	holder.Name = "Dock_" .. label
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.Size = UDim2.fromOffset(66, 84)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 2
	holder.Parent = parent
	local circ = Instance.new("ImageButton")
	circ.Name = "Circle"
	circ.AnchorPoint = Vector2.new(0.5, 1)
	circ.Position = UDim2.new(0.5, 0, 1, -14)
	circ.Size = UDim2.fromOffset(64, 64)
	circ.BackgroundColor3 = Color3.new(1, 1, 1)
	circ.BorderSizePixel = 0
	circ.ZIndex = 2
	circ.Parent = holder
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(1, 0)
	cc.Parent = circ
	local cg = Instance.new("UIGradient")
	cg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(52, 55, 64)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(26, 27, 33)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 14, 18)),
	})
	cg.Rotation = 90
	cg.Parent = circ
	local rim = Instance.new("UIStroke")
	rim.Color = Color3.new(1, 1, 1)
	rim.Transparency = 0.9
	rim.Thickness = 1.5
	rim.Parent = circ
	if iconId and iconId ~= "" then
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Crop
		img.Image = iconId:match("^%d+$") and ("rbxassetid://" .. iconId) or iconId
		img.ZIndex = 3
		img.Parent = circ
		local ic = Instance.new("UICorner")
		ic.CornerRadius = UDim.new(1, 0)
		ic.Parent = img
	elseif emoji and emoji ~= "" then
		local e = Instance.new("TextLabel")
		e.AnchorPoint = Vector2.new(0.5, 0)
		e.Position = UDim2.new(0.5, 0, 0, -6)
		e.Size = UDim2.fromOffset(58, 56)
		e.BackgroundTransparency = 1
		e.FontFace = LobbyLook.TITLE_FACE
		e.TextSize = 44
		e.Text = emoji
		e.ZIndex = 3
		e.Parent = holder
	end
	local lbl = Instance.new("TextLabel")
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.new(0.5, 0, 1, 0)
	lbl.Size = UDim2.fromOffset(84, 16)
	lbl.BackgroundTransparency = 1
	lbl.FontFace = LobbyLook.BODYB_FACE
	lbl.TextSize = 13
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.ZIndex = 4
	lbl.Text = label
	lbl.Parent = holder
	local ls = Instance.new("UIStroke")
	ls.Color = Color3.new(0, 0, 0)
	ls.Transparency = 0.25
	ls.Thickness = 1.6
	ls.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ls.Parent = lbl
	local badge = Instance.new("Frame")
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, 2, 0, 2)
	badge.Size = UDim2.fromOffset(22, 22)
	badge.BackgroundColor3 = Color3.fromRGB(224, 28, 14)
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 5
	badge.Parent = holder
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(1, 0)
	bc.Parent = badge
	ledge(badge, Color3.new(1, 1, 1), 2, 0.25)
	return holder, circ, badge
end

return LobbyLook
