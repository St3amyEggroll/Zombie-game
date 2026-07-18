-- LobbyClient (LOBBY PLACE ONLY) — the hub HUD + the PARTY PAD menu + the inventory.
-- Step on an empty pad -> you HOST it (Map / Difficulty / Party Size + PLAY). After PLAY the panel becomes
-- party info + a LEAVE button; others who step on join (if they've unlocked the settings) or see why not.
-- The party launches when full or when the countdown ends. Self-contained (no game controllers run here).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- LC: low-traffic constants folded into ONE table -- the main chunk hit Luau's 200-local-register
-- ceiling ("Out of local registers ... robuxGem"). New file-scope values go IN HERE (or on the
-- C/S/Q/T/G/RV tables), never as fresh top-level locals.
local LC = {}

local remotes = ReplicatedStorage:WaitForChild("LobbyRemotes")
local StatsRemote = remotes:WaitForChild("Stats")
local ZoneEnter = remotes:WaitForChild("ZoneEnter")
local ZoneLeave = remotes:WaitForChild("ZoneLeave")
local FinalizeParty = remotes:WaitForChild("FinalizeParty")
local LeaveParty = remotes:WaitForChild("LeaveParty")
local PartyStatus = remotes:WaitForChild("PartyStatus")
local SetSoundSettings = remotes:WaitForChild("SetSoundSettings")

-- ===== THEME (synced copy of the game's UITheme — gritty apocalypse; change there, mirror here) =====
-- FONTS: paste the same Creator Store family ids as src/.../UITheme.lua FONT_IDS. Blank = fallbacks.
local FONT_IDS = { Title = "", Body = "" } -- Black Ops One / Orbitron
local function makeFace(id, weight, fallbackEnum)
	if id and id ~= "" then
		local ok, face = pcall(function()
			return Font.new("rbxassetid://" .. id, weight)
		end)
		if ok and face then return face end
	end
	return Font.new(Font.fromEnum(fallbackEnum).Family, weight)
end
local TITLE_FACE = makeFace(FONT_IDS.Title, Enum.FontWeight.Regular, Enum.Font.FredokaOne) -- chunky cartoon face
LC.BODY_FACE  = makeFace(FONT_IDS.Body, Enum.FontWeight.Medium, Enum.Font.FredokaOne)
local BODYB_FACE = makeFace(FONT_IDS.Body, Enum.FontWeight.Bold, Enum.Font.FredokaOne)

local PANEL   = Color3.fromRGB(21, 24, 17)
local PANEL2  = Color3.fromRGB(29, 33, 23)
local TRACK   = Color3.fromRGB(36, 41, 28)
LC.LINE    = Color3.fromRGB(74, 82, 56)
local TBLACK  = Color3.fromRGB(6, 7, 5)
local ACCENT  = Color3.fromRGB(124, 219, 35)   -- toxic green
local ORANGE  = Color3.fromRGB(255, 96, 34)    -- blood orange
LC.ORANGE_DK = Color3.fromRGB(150, 44, 12)
local TEXTCOL = Color3.fromRGB(222, 227, 209)
local DIMTEXT = Color3.fromRGB(134, 142, 116)
local GOLD    = Color3.fromRGB(230, 180, 76)
LC.DIM = TRACK          -- (legacy name: disabled-button fill)
local CARD = PANEL2        -- (legacy name: card/button fill)
local SELBG = Color3.fromRGB(98, 182, 28) -- selected-button fill: BRIGHT toxic — the old dark shade rendered the same as unselected through the face gradient
LC.STUDS_TEXTURE = "rbxassetid://6965996718"

local function darker(c, f)
	return Color3.new(c.R * (1 - f), c.G * (1 - f), c.B * (1 - f))
end
local function ledge(o, color, thickness, transparency)
	local st = Instance.new("UIStroke")
	st.Color = color or TBLACK
	st.Thickness = thickness or 2
	st.Transparency = transparency or 0
	st.Parent = o
	return st
end
local function ldepth(o, k)
	local g = Instance.new("UIGradient")
	k = k or 0.22
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1 - k, 1 - k, 1 - k))
	g.Rotation = 90
	g.Parent = o
	return g
end
local function lstuds(frame, tile, transparency)
	frame.ClipsDescendants = true
	local img = Instance.new("ImageLabel")
	img.Name = "Studs"
	img.BackgroundTransparency = 1
	img.Image = LC.STUDS_TEXTURE
	img.ScaleType = Enum.ScaleType.Tile
	img.TileSize = UDim2.fromOffset(tile or 42, tile or 42)
	img.ImageColor3 = darker(frame.BackgroundColor3, 0.45)
	img.ImageTransparency = transparency or 0.62
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = frame.ZIndex
	img.Parent = frame
	return img
end
-- Responsive: one live UIScale per ScreenGui. The lobby is authored in a 1920x1080 design space.
-- CHANGED (mobile pass): the old formula (min(vp/1920,1080) clamped 0.55-1.3, then x1.3 touch x1.2) landed
-- WILDLY inconsistently on phones — a high-DPI phone (2532x1170) computed ~1.69 while a low-res one
-- (1280x720) computed ~1.04, so "the same phone" looked very different. Now MOBILE fits the largest modal
-- (the run-setup panel, ~600x490) into a fixed fraction of the SCREEN, so the UI is the SAME relative size
-- on every device (pixel density cancels out) with finger-sized touch targets; DESKTOP stays near 1:1.
local UserInputService = game:GetService("UserInputService")
LC.UI_SCALE_MULT = 1.2 -- desktop size dial (game place uses its own in UITheme)
LC.FIT_W, LC.FIT_H = 720, 500 -- largest modal footprint + margin — the mobile fit target
-- mode "hud": persistent-HUD scaling (dock/coins/LVL/quests). The modal-fit formula below sizes a
-- 720x500 panel to FILL the screen — correct for modals, way too big for the always-on HUD on a
-- short phone viewport (the dock/LVL-card pileup). HUD tracks viewport HEIGHT instead.
local function lattach(screenGui, mode)
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	local function compute()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		-- CHANGED: Studio's device emulator keeps MouseEnabled=true, so it always fell into the
		-- desktop branch — a short TOUCH viewport now also counts as mobile.
		local isMobile = (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)
			or (UserInputService.TouchEnabled and vp.Y < 600)
		if mode == "hud" then
			if isMobile then
				return math.clamp(vp.Y / 780, 0.5, 2.2) -- height-proportional, never modal-huge
			end
			return math.clamp(math.min(vp.X / 1920, vp.Y / 1080), 0.7, 1.3) * LC.UI_SCALE_MULT
		end
		if isMobile then
			-- MOBILE: fit LC.FIT_W x LC.FIT_H into ~84% width / ~86% height and take the tighter axis. Because
			-- this scales to the viewport's real pixels, the modal occupies the same fraction of the
			-- screen (~86% tall) on a high-DPI AND a low-res phone — consistent, and always on-screen. The
			-- 0.86 height factor also leaves the bottom HUD (dock + coins + XP) room on narrow 16:9 phones.
			local sc = math.min(vp.X * 0.84 / LC.FIT_W, vp.Y * 0.86 / LC.FIT_H)
			return math.clamp(sc, 0.6, 2.5) -- floor low enough that a tiny viewport can still fit the modal
		end
		-- DESKTOP / mouse: near 1:1 with a gentle clamp (unchanged feel).
		return math.clamp(math.min(vp.X / 1920, vp.Y / 1080), 0.7, 1.3) * LC.UI_SCALE_MULT
	end
	scale.Scale = compute()
	scale.Parent = screenGui
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			scale.Scale = compute()
		end)
	end
end

local sel = { map = "forest", size = 1 } -- ONE difficulty per world now — the run is endless + extraction
local unlocks = nil       -- unlock payload while configuring a pad
local zoneMode = nil      -- "config" | "party" | "blocked" (what the pad UI is showing)

local function fmt(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
local function cap(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end
-- CHANGED: chunky simulator-style roundness — every radius runs through this curve (6->13, 8->16...).
local function corner(o, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, math.floor((r or 6) * 1.8 + 2)); c.Parent = o
end

-- The classic cartoon bottom bevel: a hard-stop WHITE->dark gradient multiplies whatever the
-- background color is, so it works on recolored (selected) buttons too.
local function lbevel(o)
	-- FACE/SLAB button (layout-safe): the element ITSELF is the dark slab — a child "Face" carries the
	-- bright surface and the text. (The old sibling-lip version became an extra row item inside
	-- UIListLayouts: those empty ghost tiles in the run-setup panel.) Gradients only multiply, so the
	-- face is white and the gradient carries ABSOLUTE colors.
	local white = Color3.new(1, 1, 1)
	local label = nil -- hoisted: the ZIndex sync (below) needs it even for non-text buttons
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -5) -- the slab shows as a 5px lip below
	face.BackgroundColor3 = white
	face.BorderSizePixel = 0
	-- CRITICAL (the "black pill" bug): the lobby renders under ZIndexBehavior.Global (every content
	-- element in this file is hand-assigned an ascending ZIndex because of it). Under Global a child does
	-- NOT auto-draw above its parent — so on any button with a raised ZIndex (reel CONTINUE = 7, class
	-- SELECT = 3) this bright Face + its text label (default ZIndex 1) got BURIED under the button's own
	-- dark slab, rendering as a solid dark/black pill with no visible text. Force them above the slab.
	face.ZIndex = o.ZIndex + 1
	local hostCorner = o:FindFirstChildOfClass("UICorner")
	if o:IsA("GuiButton") then
		-- COPY the game button: raw 10px corners (the shared corner() curve makes ~13px bulbous pills —
		-- the game's read squarer), and a CHUNKY black ring scaled to these bigger lobby buttons.
		if not hostCorner then
			hostCorner = Instance.new("UICorner")
			hostCorner.Parent = o
		end
		hostCorner.CornerRadius = UDim.new(0, 10)
		local ring = nil
		for _, c in o:GetChildren() do
			if c:IsA("UIStroke") and c.Color == TBLACK then
				ring = c
				break
			end
		end
		if ring then
			ring.Thickness = math.max(ring.Thickness, 4)
		else
			ledge(o, TBLACK, 4)
		end
	end
	local fc = Instance.new("UICorner")
	fc.CornerRadius = hostCorner and hostCorner.CornerRadius or UDim.new(0, 10)
	fc.Parent = face
	ledge(face, TBLACK, o:IsA("GuiButton") and 3.5 or 2.5) -- the face needs its OWN black ring (it covers the slab's)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Parent = face
	face.Parent = o
	if o:IsA("TextButton") then
		-- the button's own text renders UNDER children — mirror it onto a label on the face
		label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.FontFace = o.FontFace
		label.TextSize = o.TextSize
		label.TextColor3 = o.TextColor3
		label.Text = o.Text
		label.ZIndex = o.ZIndex + 2 -- above the Face (o.ZIndex+1) under Global ZIndexBehavior
		label.Parent = face
		local ls = Instance.new("UIStroke")
		ls.Color = TBLACK
		-- CHANGED: 3px merged the letters of longer labels (CONTINUE / SELECT JUGGERNAUT) into a solid
		-- black blob. 1.5 keeps a crisp sticker outline without swallowing the fill.
		ls.Thickness = 1.5
		ls.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		ls.Parent = label
		o.TextTransparency = 1
		o:GetPropertyChangedSignal("Text"):Connect(function()
			label.Text = o.Text
		end)
		o:GetPropertyChangedSignal("TextSize"):Connect(function()
			label.TextSize = o.TextSize
		end)
		o:GetPropertyChangedSignal("TextColor3"):Connect(function()
			label.TextColor3 = o.TextColor3
		end)
	end
	o:GetPropertyChangedSignal("ZIndex"):Connect(function()
		face.ZIndex = o.ZIndex + 1 -- keep the face/text above the slab if the button is restacked later
		if label then label.ZIndex = o.ZIndex + 2 end
	end)
	-- Signals fire deferred, so a boolean re-entry flag can't stop us reacting to
	-- our own slab write (every recolor would re-darken and spiral toward black).
	-- Instead remember the exact color we wrote and skip the echo by value.
	local lastSlab = nil
	local function applyFill()
		local base = o.BackgroundColor3
		if lastSlab ~= nil and base == lastSlab then
			return -- echo of our own slab write, not a real recolor
		end
		g.Color = ColorSequence.new({ -- EXACT match for the game's UITheme.Button (LEAVE / SKIP WAVE look)
			ColorSequenceKeypoint.new(0, base:Lerp(white, 0.42)),
			ColorSequenceKeypoint.new(0.07, base:Lerp(white, 0.18)),
			ColorSequenceKeypoint.new(1, darker(base, 0.28)),
		})
		lastSlab = darker(base, 0.5) -- the slab shade
		o.BackgroundColor3 = lastSlab
	end
	applyFill()
	o:GetPropertyChangedSignal("BackgroundColor3"):Connect(applyFill) -- selection recolors re-derive
	if o:IsA("GuiButton") then
		-- NEW: juice — smooth hover grow + press squish (tweened UIScale) on top of the face slide.
		local ts = game:GetService("TweenService")
		local sc = Instance.new("UIScale")
		sc.Parent = o
		local function to(v, t, style)
			ts:Create(sc, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = v }):Play()
		end
		o.MouseEnter:Connect(function()
			to(1.04, 0.09)
		end)
		o.MouseButton1Down:Connect(function()
			face.Position = UDim2.fromOffset(0, 4) -- press = face slides down onto the slab
			to(0.95, 0.05)
		end)
		o.MouseButton1Up:Connect(function()
			face.Position = UDim2.new()
			to(1.04, 0.14, Enum.EasingStyle.Back) -- release = springs back with a soft overshoot
		end)
		o.MouseLeave:Connect(function()
			face.Position = UDim2.new()
			to(1, 0.09)
		end)
	end
	return g
end

-- Chunky red close button (the image's red X): red rounded square, white X, bevel bottom.
local function redX(parentGui, size, tsize)
	local x = Instance.new("TextButton")
	x.AnchorPoint = Vector2.new(1, 0); x.Size = UDim2.fromOffset(size, size)
	x.BackgroundColor3 = Color3.fromRGB(224, 34, 34); x.BorderSizePixel = 0
	x.FontFace = TITLE_FACE; x.TextSize = tsize
	x.TextColor3 = Color3.fromRGB(255, 255, 255); x.Text = "✕"; x.Parent = parentGui
	corner(x, 6); ledge(x, TBLACK, 2.5)
	x.BackgroundColor3 = Color3.new(1, 1, 1)
	local g = Instance.new("UIGradient") -- one-surface fill, matches the button family
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(224, 34, 34):Lerp(Color3.new(1, 1, 1), 0.42)),
		ColorSequenceKeypoint.new(0.07, Color3.fromRGB(224, 34, 34):Lerp(Color3.new(1, 1, 1), 0.18)),
		ColorSequenceKeypoint.new(1, darker(Color3.fromRGB(224, 34, 34), 0.28)),
	})
	g.Rotation = 90; g.Parent = x
	-- Drawn white X (robust vs fonts lacking the glyph).
	x.Text = ""
	for _, rot in { 45, -45 } do -- CHANGED: fatter cross (3px got lost on the big header button)
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5); bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.new(0.55, 0, 0, math.max(4, math.floor(size / 8))); bar.Rotation = rot
		-- ZIndex 20: above the button fill under BOTH Sibling and Global ZIndexBehavior (a caller that
		-- bumps x.ZIndex, e.g. the class panel's X, would otherwise bury the cross under Global behavior).
		bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255); bar.BorderSizePixel = 0; bar.ZIndex = 20; bar.Parent = x
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = bar
	end
	do -- NEW: juice — tweened hover grow + press squish
		local ts = game:GetService("TweenService")
		local sc = Instance.new("UIScale")
		sc.Parent = x
		local function to(v, t, style)
			ts:Create(sc, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = v }):Play()
		end
		x.MouseEnter:Connect(function() to(1.1, 0.09) end)
		x.MouseLeave:Connect(function() to(1, 0.09) end)
		x.MouseButton1Down:Connect(function() to(0.88, 0.05) end)
		x.MouseButton1Up:Connect(function() to(1.1, 0.14, Enum.EasingStyle.Back) end)
	end
	return x
end

-- Per-screen header COLORS (mirror the game's UITheme.HeaderColors).
LC.HEADER_COLORS = {
	guns     = Color3.fromRGB(168, 32, 32),   -- RED — matches the WEAPONS nav pill
	cases    = Color3.fromRGB(150, 66, 16),   -- dark orange
	shop     = Color3.fromRGB(140, 100, 22),  -- gold / amber
	settings = Color3.fromRGB(36, 66, 104),   -- steel blue
	play     = Color3.fromRGB(42, 82, 20),    -- toxic green (dark)
	summary  = Color3.fromRGB(120, 30, 22),   -- blood red
}

-- Solid colored TOP BAR across a panel (rounded top, squared bottom, dark seam). Returns the bar so a
-- caller can recolor it later (the GUNS/CASES panel is shared, so its bar switches color per screen).
local function headerBar(panel, h, barColor)
	local bar = Instance.new("Frame")
	bar.Name = "HeaderBar"; bar.Size = UDim2.new(1, 0, 0, h)
	bar.BackgroundColor3 = barColor; bar.BorderSizePixel = 0; bar.ZIndex = 1; bar.Parent = panel
	corner(bar, 6)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(0.82, 0.82, 0.82)),
	})
	grad.Rotation = 90; grad.Parent = bar
	local sq = Instance.new("Frame")
	sq.AnchorPoint = Vector2.new(0, 1); sq.Position = UDim2.new(0, 0, 1, 0); sq.Size = UDim2.new(1, 0, 0, math.floor(h / 2))
	sq.BackgroundColor3 = barColor; sq.BorderSizePixel = 0; sq.ZIndex = 1; sq.Parent = bar
	local seam = Instance.new("Frame")
	seam.AnchorPoint = Vector2.new(0, 1); seam.Position = UDim2.new(0, 0, 1, 0); seam.Size = UDim2.new(1, 0, 0, 2)
	seam.BackgroundColor3 = TBLACK; seam.BackgroundTransparency = 0.2; seam.BorderSizePixel = 0; seam.ZIndex = 2; seam.Parent = bar
	return bar, sq
end

-- Vertical shade for cards: multiplies the fill darker toward the BOTTOM (the 3D drop).
local function cardShade(frame, strength)
	local k = strength or 0.4
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(1 - k, 1 - k, 1 - k)),
	})
	g.Rotation = 90; g.Parent = frame
	return g
end

-- REDONE (matched to the reference image): the panel chrome as ONE root assembly — a fat colored
-- HEADER BAR wider than the body (big white title with a LC.NAVY outline on the left, the red X sitting
-- INSIDE the bar's right end) and the dark BODY panel tucked underneath it. Everything lives inside
-- the root, so the header can never hang off-screen. Toggle the BODY's Visible (callers own it) and
-- mirror it onto the root. Returns root, body, title, closeX, recolor(c).
LC.NAVY = Color3.fromRGB(21, 36, 58) -- the reference title outline is navy, not black
local function chromePanel(parentGui, bodyW, bodyH, colr, titleText)
	local OVER, HDR_H, TUCK = 22, 64, 14 -- header overhang per side · header height · body tuck-under
	local root = Instance.new("Frame")
	root.Name = "Chrome" .. titleText:gsub("%s", "")
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(bodyW + OVER * 2, HDR_H - TUCK + bodyH)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = parentGui
	-- NEW: pop-open — every chrome panel grows in with a soft overshoot when it appears.
	local pop = Instance.new("UIScale")
	pop.Parent = root
	root:GetPropertyChangedSignal("Visible"):Connect(function()
		if root.Visible then
			pop.Scale = 0.92
			game:GetService("TweenService"):Create(pop,
				TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(OVER, HDR_H - TUCK)
	body.Size = UDim2.fromOffset(bodyW, bodyH)
	body.BackgroundColor3 = Color3.fromRGB(19, 21, 15) -- near-black like the reference (map peeks through)
	body.BackgroundTransparency = 0.08
	body.BorderSizePixel = 0
	body.ZIndex = 1
	body.Parent = root
	corner(body, 8)
	lstuds(body)
	ldepth(body)
	ledge(body, TBLACK, 3.5)

	local bar = Instance.new("Frame")
	bar.Name = "HeaderBar"
	bar.Size = UDim2.new(1, 0, 0, HDR_H)
	bar.BorderSizePixel = 0
	bar.ClipsDescendants = true -- the shine sweep stays inside the bar
	bar.ZIndex = 3
	bar.Parent = root
	corner(bar, 7)
	ledge(bar, TBLACK, 3.5)
	bar.BackgroundColor3 = Color3.new(1, 1, 1) -- white base: the gradient carries the ABSOLUTE colors
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Parent = bar
	-- Diagonal light streak via a GRADIENT (a rotated frame would escape ClipsDescendants — rotated
	-- UI ignores clipping, so it floated outside the bar).
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
	local function recolor(c) -- bright flash up top, deep foot — the reference's gold falloff
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
	title.FontFace = TITLE_FACE
	title.TextSize = 40
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.new(1, 1, 1)
	title.ZIndex = 4
	title.Text = titleText
	title.Parent = bar
	local ts = Instance.new("UIStroke")
	ts.Color = LC.NAVY
	ts.Thickness = 3.5
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = title

	local x = redX(bar, 46, 24)
	x.AnchorPoint = Vector2.new(1, 0.5)
	x.Position = UDim2.new(1, -9, 0.5, 0)
	x.ZIndex = 4
	return root, body, title, x, recolor
end

-- Subtle FOV "lean back" while a panel is open (refcounted; eases in/out).
LC.UI_FOV_PUSH, LC.UI_FOV_EASE = 6, 6
local uiOpenCount, uiBaseFov = 0, nil
do
	RunService.RenderStepped:Connect(function(dt)
		local cam = workspace.CurrentCamera
		if not cam or uiBaseFov == nil then return end
		local target = (uiOpenCount > 0) and (uiBaseFov + LC.UI_FOV_PUSH) or uiBaseFov
		local a = math.clamp(dt * LC.UI_FOV_EASE, 0, 1)
		local cur = cam.FieldOfView
		if math.abs(cur - target) > 0.05 then
			cam.FieldOfView = cur + (target - cur) * a
		elseif uiOpenCount == 0 then
			cam.FieldOfView = uiBaseFov
		end
	end)
end
local function uiFocusOpen()
	local cam = workspace.CurrentCamera
	if uiBaseFov == nil and cam then uiBaseFov = cam.FieldOfView end
	uiOpenCount += 1
end
local function uiFocusClose()
	uiOpenCount = math.max(0, uiOpenCount - 1)
end

-- =====================================================================================================
-- ===== SOUND ===== paste asset ids below ("123" or "rbxassetid://123"). Blank = that slot is silent.
-- The game place has its own (bigger) list in ReplicatedStorage/Shared/Config/SoundConfig.lua.
-- =====================================================================================================
local SOUND_IDS = {
	Music         = "138934492920017", -- lobby background loop [chill dark ambient loop]
	Click         = "133915937837646", -- any button
	Open          = "8968249401", -- panel opens
	Close         = "74657965144290", -- panel closes
	Error         = "87519554692663", -- failed action
	Buy           = "136519378894463", -- shop/gun purchase
	Upgrade       = "", -- (retired with gun upgrading; slot kept)
	Equip         = "81102724493720", -- weapon/skin equipped
	LevelUp       = "341542294", -- account level up (the bottom-right bar fills over)
	ReelTick      = "", -- each case-reel tile passing [tick]
	RevealLow     = "", -- common/uncommon/rare pull [small reward sting]
	RevealHigh    = "", -- epic/legendary pull [big reward sting]
	RevealJackpot = "", -- mythic/divine or NEW GUN [jackpot fanfare]
	TeleportGo    = "", -- party countdown ends [teleport whoosh]
}
LC.SOUND_VOL = { -- base volume per slot (before the sliders)
	Music = 0.45, Click = 0.4, ReelTick = 0.35, RevealJackpot = 0.8, LevelUp = 0.7,
}

local volMaster, volMusic, volSfx = 1, 0.6, 1
LC.volTouched = false -- true once the player moves a slider (server echoes stop overriding)

local function soundAsset(raw)
	if raw == "" then return "" end
	if string.find(raw, "://") then return raw end
	return "rbxassetid://" .. raw
end

local function lplay(name, pitch)
	local id = SOUND_IDS[name]
	if not id or id == "" then return end
	local s = Instance.new("Sound")
	s.SoundId = soundAsset(id)
	s.Volume = (LC.SOUND_VOL[name] or 0.5) * volMaster * volSfx
	if pitch then s.PlaybackSpeed = pitch end
	s.Parent = SoundService
	s.Ended:Once(function() s:Destroy() end)
	task.delay(15, function() if s.Parent then s:Destroy() end end)
	s:Play()
end

local lobbyMusic = nil
local function applySoundVol()
	if lobbyMusic then
		lobbyMusic.Volume = (LC.SOUND_VOL.Music or 0.45) * volMaster * volMusic
	end
end
if SOUND_IDS.Music ~= "" then
	lobbyMusic = Instance.new("Sound")
	lobbyMusic.SoundId = soundAsset(SOUND_IDS.Music)
	lobbyMusic.Looped = true
	lobbyMusic.Parent = SoundService
	applySoundVol()
	lobbyMusic:Play()
end

-- Every button in every lobby gui clicks — no per-button wiring. Opt out: SetAttribute("NoClickSound", true).
playerGui.DescendantAdded:Connect(function(inst)
	if inst:IsA("GuiButton") and not inst:GetAttribute("NoClickSound") then
		inst.Activated:Connect(function() lplay("Click") end)
	end
end)

-- Debounced slider save -> shared profile (settings.vol), same field the game place reads.
LC.volSaveAt = 0
local function queueVolSave()
	LC.volSaveAt = os.clock() + 0.6
	task.delay(0.65, function()
		if os.clock() >= LC.volSaveAt then
			SetSoundSettings:FireServer({ master = volMaster, music = volMusic, sfx = volSfx })
		end
	end)
end

-- ===== 3D GUN PREVIEWS ===== spinning ViewportFrames fed by ReplicatedStorage > GunDisplay (the server
-- publishes sanitized clones of every carry model at boot). Returns nil when a gun has no model yet.
local gvSpinning = {} -- { {vp, model, base, ang} }
local gvLoop = false
local function makeGunViewport(weaponId, spin, folderName, tint)
	-- NEW: `tint` (Color3) recolors the clone — tinted SKINS render on the base gun model, no
	-- per-skin model needed.
	local folder = ReplicatedStorage:FindFirstChild(folderName or "GunDisplay")
	local template = folder and folder:FindFirstChild(weaponId)
	if not template then
		return nil
	end
	local vp = Instance.new("ViewportFrame")
	vp.Name = "GunViewport"
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromRGB(160, 160, 160)
	vp.LightColor = Color3.fromRGB(235, 235, 220)
	vp.LightDirection = Vector3.new(-0.4, -1, -0.4)
	local model = template:Clone()
	if tint then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Color = tint:Lerp(d.Color, 0.15) -- mostly flat skin color, a hint of the original shading
			end
		end
	end
	model.Parent = vp
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vp
	vp.CurrentCamera = cam
	local cf, size = model:GetBoundingBox()
	model.WorldPivot = cf
	local dist = (size.Magnitude / 2) / math.tan(math.rad(15)) * 1.12 + 0.1
	cam.CFrame = CFrame.new(cf.Position + Vector3.new(0, dist * 0.22, dist), cf.Position)
	-- (No outline here: Roblox Highlights don't render inside ViewportFrames, and the fake black-clone
	-- rim looked wrong — UI previews render the plain model.)
	-- Display orientation: GUNS get side-on + a cool upward tilt; CRATES keep their built rotation
	-- (the gun yaw was turning crates sideways).
	local TILT, DISP_YAW = 45, { tommygun = 90, raygun = 90, plasma = 90, freezeray = 90 }
	local dispRot
	if (folderName or "GunDisplay") == "GunDisplay" then
		dispRot = CFrame.Angles(0, 0, math.rad(TILT)) * CFrame.Angles(0, math.rad(DISP_YAW[weaponId] or 0), 0) * cf.Rotation
	else
		dispRot = cf.Rotation
	end
	if spin ~= false then
		table.insert(gvSpinning, { vp = vp, model = model, pos = cf.Position, rot = dispRot, ang = math.random() * math.pi * 2 })
		if not gvLoop then
			gvLoop = true
			RunService.RenderStepped:Connect(function(dt)
				for i = #gvSpinning, 1, -1 do
					local e = gvSpinning[i]
					if not e.vp.Parent then
						table.remove(gvSpinning, i)
					elseif e.vp.Visible then
						e.ang += dt * math.rad(45)
						-- Yaw around WORLD up (spinning the model's local Y flipped flat-built guns).
						e.model:PivotTo(CFrame.new(e.pos) * CFrame.Angles(0, e.ang, 0) * e.rot)
					end
				end
			end)
		end
	else
		model:PivotTo(CFrame.new(cf.Position) * dispRot) -- static: pose it once, side-on + tilted
	end
	return vp
end

-- ===== BUILD =====
local gui = Instance.new("ScreenGui")
gui.Name = "LobbyHUD"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 10
gui.Parent = playerGui
lattach(gui, "hud")

-- Coins: a dark rounded pill BOTTOM-LEFT, coin icon + gold number. Auto-sizes to the number.
-- CHANGED: lives in its OWN ScreenGui above every ambient layer — it kept getting washed out by
-- whatever translucent layer happened to draw after it. Nothing sits on the coins anymore, period.
local COIN_ICON_ID = "rbxassetid://84729396970772"
local coinsGui = Instance.new("ScreenGui")
coinsGui.Name = "LobbyCoins"; coinsGui.ResetOnSpawn = false; coinsGui.IgnoreGuiInset = true
coinsGui.DisplayOrder = 25 -- above HUD(10)/dock(11)/panels(12), below toasts(40)/warnings(90)
coinsGui.Parent = playerGui
lattach(coinsGui, "hud")
local coinsRow = Instance.new("Frame")
coinsRow.AnchorPoint = Vector2.new(0, 1); coinsRow.Position = UDim2.new(0, 16, 1, -12)
coinsRow.Size = UDim2.fromOffset(0, 54); coinsRow.AutomaticSize = Enum.AutomaticSize.X
coinsRow.BackgroundColor3 = Color3.fromRGB(19, 20, 15); coinsRow.BackgroundTransparency = 0.05
coinsRow.BorderSizePixel = 0; coinsRow.Parent = coinsGui
corner(coinsRow, 27); ledge(coinsRow, TBLACK, 3); ledge(coinsRow, Color3.new(1, 1, 1), 1.5, 0.75)
local coinPad = Instance.new("UIPadding")
coinPad.PaddingLeft = UDim.new(0, 6); coinPad.PaddingRight = UDim.new(0, 18)
coinPad.Parent = coinsRow
local coinIcon = Instance.new("ImageLabel")
coinIcon.AnchorPoint = Vector2.new(0, 0.5); coinIcon.Position = UDim2.new(0, 0, 0.5, 0)
coinIcon.Size = UDim2.fromOffset(42, 42); coinIcon.BackgroundTransparency = 1
coinIcon.ScaleType = Enum.ScaleType.Fit; coinIcon.Visible = false; coinIcon.Parent = coinsRow
if COIN_ICON_ID ~= "" then
	coinIcon.Image = COIN_ICON_ID
	coinIcon.Visible = true
end
local moneyLabel = Instance.new("TextLabel")
moneyLabel.Position = UDim2.fromOffset(COIN_ICON_ID ~= "" and 50 or 0, 0)
moneyLabel.Size = UDim2.new(0, 0, 1, 0); moneyLabel.AutomaticSize = Enum.AutomaticSize.X
moneyLabel.BackgroundTransparency = 1
moneyLabel.FontFace = TITLE_FACE; moneyLabel.TextSize = 34; moneyLabel.TextXAlignment = Enum.TextXAlignment.Left
moneyLabel.TextColor3 = GOLD; moneyLabel.Text = ""; moneyLabel.Parent = coinsRow
local moneyStroke = Instance.new("UIStroke")
moneyStroke.Color = TBLACK; moneyStroke.Thickness = 3; moneyStroke.Parent = moneyLabel
local bestLabel = Instance.new("TextLabel") -- best-wave text removed; kept as a hidden data hook
bestLabel.Size = UDim2.fromOffset(0, 0); bestLabel.BackgroundTransparency = 1
bestLabel.FontFace = BODYB_FACE; bestLabel.TextSize = 14
bestLabel.TextColor3 = DIMTEXT; bestLabel.Text = ""; bestLabel.Visible = false; bestLabel.Parent = coinsRow
local bestStroke = Instance.new("UIStroke")
bestStroke.Color = TBLACK; bestStroke.Thickness = 1.5; bestStroke.Parent = bestLabel

-- selection panel
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5); panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(600, 402); panel.BackgroundColor3 = PANEL -- square map photos + size row
panel.BackgroundTransparency = 0.12; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 8)
lstuds(panel); ldepth(panel); ledge(panel, TBLACK, 3); ledge(panel, LC.HEADER_COLORS.play, 2.5, 0.05)

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 0); title.Size = UDim2.new(1, 0, 0, 48); title.BackgroundTransparency = 1
title.FontFace = TITLE_FACE; title.TextSize = 28; title.TextColor3 = TEXTCOL
headerBar(panel, 48, LC.HEADER_COLORS.play)
title.Text = "CHOOSE YOUR RUN"; title.Parent = panel

local function sectionLabel(text, y)
	local l = Instance.new("TextLabel")
	l.Position = UDim2.new(0, 24, 0, y); l.Size = UDim2.new(1, -48, 0, 20); l.BackgroundTransparency = 1
	l.FontFace = BODYB_FACE; l.TextSize = 18; l.TextXAlignment = Enum.TextXAlignment.Center -- centered column
	l.TextColor3 = DIMTEXT; l.Text = text; l.Parent = panel
	return l
end
local function row(y, h)
	local f = Instance.new("Frame")
	f.Position = UDim2.new(0, 24, 0, y); f.Size = UDim2.new(1, -48, 0, h); f.BackgroundTransparency = 1; f.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal; list.Padding = UDim.new(0, 10)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center -- centered column (was hugging the left)
	list.Parent = f
	return f
end
local function button(parent, w, h, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, h); b.BackgroundColor3 = CARD; b.AutoButtonColor = true; b.Text = text
	b.FontFace = BODYB_FACE; b.TextSize = 20; b.TextColor3 = TEXTCOL; b.Parent = parent
	corner(b, 6); ledge(b, TBLACK, 2.5); lbevel(b)
	local ts = Instance.new("UIStroke")
	ts.Color = TBLACK; ts.Thickness = 1.3; ts.Transparency = 0.3
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; ts.Parent = b
	return b
end

local mapLbl = sectionLabel("MAP", 58)
local mapRow = row(82, 118) -- taller row for square photo buttons
local sizeLbl = sectionLabel("PARTY SIZE", 214)
local sizeRow = row(238, 48)


-- PARTY MODE has no panel at all: just one BIG red LEAVE button at the bottom of the screen with a
-- live status line above it (the billboard over the pad shows the rest).
local leaveBtn = Instance.new("TextButton")
-- Above the visual hotbar (which owns the bottom-center strip: 84px slots + margins up to y -98).
leaveBtn.AnchorPoint = Vector2.new(0.5, 1); leaveBtn.Position = UDim2.new(0.5, 0, 1, -116)
leaveBtn.Size = UDim2.fromOffset(240, 44); leaveBtn.BackgroundColor3 = ORANGE; leaveBtn.BorderSizePixel = 0
leaveBtn.FontFace = TITLE_FACE; leaveBtn.TextSize = 16; leaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
leaveBtn.Text = "LEAVE PARTY"; leaveBtn.Visible = false; leaveBtn.Parent = gui
corner(leaveBtn, 8); ldepth(leaveBtn); ledge(leaveBtn, TBLACK, 3); lbevel(leaveBtn)

local leaveStatus = Instance.new("TextLabel")
leaveStatus.AnchorPoint = Vector2.new(0.5, 1); leaveStatus.Position = UDim2.new(0.5, 0, 1, -174)
leaveStatus.Size = UDim2.fromOffset(520, 26); leaveStatus.BackgroundTransparency = 1
leaveStatus.FontFace = BODYB_FACE; leaveStatus.TextSize = 18; leaveStatus.TextColor3 = TEXTCOL
leaveStatus.Text = ""; leaveStatus.Visible = false; leaveStatus.Parent = gui

local blockedMsg = Instance.new("TextLabel")
blockedMsg.Position = UDim2.new(0, 24, 0, 110); blockedMsg.Size = UDim2.new(1, -48, 0, 80); blockedMsg.BackgroundTransparency = 1
blockedMsg.FontFace = BODYB_FACE; blockedMsg.TextSize = 17; blockedMsg.TextWrapped = true
blockedMsg.TextColor3 = TEXTCOL; blockedMsg.Text = ""; blockedMsg.Visible = false; blockedMsg.Parent = panel

local mapBtns, sizeBtns = {}, {}

local play = Instance.new("TextButton")
play.AnchorPoint = Vector2.new(0.5, 1); play.Position = UDim2.new(0.5, 0, 1, -40); play.Size = UDim2.fromOffset(320, 56)
play.BackgroundColor3 = ACCENT; play.FontFace = TITLE_FACE; play.TextSize = 18
play.TextColor3 = Color3.new(1, 1, 1); play.Text = "PLAY"; play.Parent = panel -- white + black outline, like the game's CTAs
corner(play, 6)
ldepth(play); ledge(play, TBLACK, 2.5); lbevel(play)

local status = Instance.new("TextLabel")
-- LIVE RUN SUMMARY — sits ABOVE the PLAY button (it used to hide underneath it), spelling out exactly
-- what you're launching: "FOREST · MEDIUM · PARTY OF 2". refresh() keeps it current.
status.AnchorPoint = Vector2.new(0.5, 1); status.Position = UDim2.new(0.5, 0, 1, -104); status.Size = UDim2.new(1, -40, 0, 22)
status.BackgroundTransparency = 1; status.FontFace = BODYB_FACE; status.TextSize = 16
status.TextColor3 = DIMTEXT; status.Text = ""; status.Parent = panel
ledge(status, TBLACK, 1.5) -- text outline (no named local: this file sits at Luau's 200-local ceiling)

-- ===== RENDER =====
local function refresh()
	if not unlocks then return end
	status.Text = ("%s  ·  PARTY OF %d"):format(cap(sel.map or "?"):upper(), tonumber(sel.size) or 1)
	-- map buttons — each is a SQUARE PHOTO of the map itself (owner-supplied; add a line per world)
	local MAP_IMAGES = { forest = "rbxassetid://85349059800026" }
	for _, b in mapBtns do b:Destroy() end
	mapBtns = {}
	for _, w in unlocks.worldOrder do
		local info = unlocks.worlds[w]
		local isSel = (sel.map == w)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(118, 118); b.BackgroundColor3 = isSel and SELBG or CARD; b.AutoButtonColor = info.unlocked
		b.Text = ""; b.LayoutOrder = #mapBtns + 1; b.Parent = mapRow
		corner(b, 6); lbevel(b)
		local img = MAP_IMAGES[w]
		if img then
			local pic = Instance.new("ImageLabel")
			pic.Size = UDim2.fromScale(1, 1); pic.BackgroundTransparency = 1; pic.Image = img
			pic.ScaleType = Enum.ScaleType.Crop
			-- Locked = greyed. Unlocked-but-not-selected = dimmed so the SELECTED map pops at full brightness.
			pic.ImageColor3 = (not info.unlocked and Color3.fromRGB(95, 95, 105))
				or (isSel and Color3.new(1, 1, 1) or Color3.fromRGB(130, 130, 135))
			pic.Parent = b; corner(pic, 6)
		end
		local nm = Instance.new("TextLabel")
		nm.AnchorPoint = Vector2.new(0.5, 1); nm.Position = UDim2.new(0.5, 0, 1, -4)
		nm.Size = UDim2.new(1, -6, 0, 20); nm.BackgroundTransparency = 1; nm.ZIndex = 3
		nm.FontFace = BODYB_FACE; nm.TextSize = 15; nm.TextColor3 = isSel and ACCENT or TEXTCOL
		nm.Text = info.unlocked and cap(w) or (cap(w) .. " 🔒"); nm.Parent = b
		local nmSt = Instance.new("UIStroke"); nmSt.Color = TBLACK; nmSt.Thickness = 2; nmSt.Parent = nm
		local edge = Instance.new("UIStroke") -- bright accent outline on the selected map, thin black otherwise
		edge.Color = isSel and ACCENT or TBLACK
		edge.Thickness = isSel and 4 or 2
		edge.Parent = b
		if isSel then
			-- A clear "SELECTED" badge across the top so there's no doubt which map is chosen.
			local badge = Instance.new("TextLabel")
			badge.AnchorPoint = Vector2.new(0.5, 0); badge.Position = UDim2.new(0.5, 0, 0, 5)
			badge.Size = UDim2.fromOffset(90, 20); badge.BackgroundColor3 = ACCENT; badge.ZIndex = 4
			badge.FontFace = BODYB_FACE; badge.TextSize = 12; badge.TextColor3 = Color3.fromRGB(14, 22, 6)
			badge.Text = "✓ SELECTED"; badge.Parent = b; corner(badge, 4)
		end
		b.Activated:Connect(function()
			if info.unlocked then sel.map = w; refresh() end
		end)
		table.insert(mapBtns, b)
	end
	-- size buttons
	for _, b in sizeBtns do b:Destroy() end
	sizeBtns = {}
	for n = 1, 4 do
		local b = button(sizeRow, 64, 48, tostring(n))
		b.LayoutOrder = n
		b.BackgroundColor3 = (sel.size == n) and SELBG or CARD
		b.TextColor3 = TEXTCOL -- selection shows in the fill, text stays normal
		b.Activated:Connect(function()
			sel.size = n; refresh()
		end)
		table.insert(sizeBtns, b)
	end
end

-- Show/hide the three pad-UI modes inside the one panel.
local function setPanelMode(mode)
	zoneMode = mode
	local config = (mode == "config")
	mapLbl.Visible = config; mapRow.Visible = config
	sizeLbl.Visible = config; sizeRow.Visible = config
	blockedMsg.Visible = (mode == "blocked")
	play.Visible = config
	-- PARTY mode: the modal disappears completely — just the big red LEAVE button + status line.
	panel.Visible = (mode ~= "party")
	leaveBtn.Visible = (mode == "party")
	leaveStatus.Visible = (mode == "party")
	if mode == "config" then
		title.Text = "SET UP YOUR RUN"
	else
		title.Text = "PARTY PAD"
	end
	-- The dock's Play sits where the party LEAVE button lives — the dock section (declared later,
	-- so it can't be referenced here) listens to this attribute and hides Play while a pad UI is up.
	gui:SetAttribute("PadMode", mode or "")
end

-- ===== EVENTS =====
local saveWarn = nil -- the profile-failed-to-load banner (built once, stays up all session)
StatsRemote.OnClientEvent:Connect(function(s)
	if typeof(s) ~= "table" then return end
	if not LC.volTouched and typeof(s.settings) == "table" and typeof(s.settings.vol) == "table" then
		volMaster = math.clamp(tonumber(s.settings.vol.master) or volMaster, 0, 1)
		volMusic = math.clamp(tonumber(s.settings.vol.music) or volMusic, 0, 1)
		volSfx = math.clamp(tonumber(s.settings.vol.sfx) or volSfx, 0, 1)
		applySoundVol()
	end
	-- Camera-shake preference (shared with the game place): mirror it onto a player attribute the settings
	-- toggle reads. Default ON; only OFF when the saved value is explicitly false.
	if typeof(s.settings) == "table" and s.settings.shake ~= nil then
		localPlayer:SetAttribute("ShakeOff", s.settings.shake ~= true)
	end
	-- Account XP drives the level bar; expose it as an attribute so the XP-bar block (below) can react
	-- without a new top-level local (this client sits at Luau's 200-local ceiling).
	localPlayer:SetAttribute("AccountXP", tonumber(s.xp) or 0)
	-- Expose the first-join tour flag as an attribute too (this handler is connected early, so it catches
	-- the join snapshot; the tour block below reads the attribute rather than racing the remote event).
	localPlayer:SetAttribute("TutDone", s.tutDone == true)
	localPlayer:SetAttribute("BestWave", tonumber(s.bestWave) or 0) -- the pad trail hides once you've run
	moneyLabel.Text = fmt(s.lobbyMoney or 0)
	bestLabel.Text = "BEST: WAVE " .. tostring(s.bestWave or 0)
	-- All profile-load retries failed: this session runs on a fallback that will NEVER be saved
	-- (opening cases / buying is blocked server-side). Tell the player instead of failing silently.
	if s.noPersist and not saveWarn then
		-- CRITICAL banner: its own ScreenGui above every panel (it used to live in the DisplayOrder-10
		-- HUD gui, so the inventory panel drew over it), positioned below the Roblox topbar band.
		local warnGui = Instance.new("ScreenGui")
		warnGui.Name = "LobbyWarning"; warnGui.ResetOnSpawn = false; warnGui.IgnoreGuiInset = true
		warnGui.DisplayOrder = 90; warnGui.Parent = playerGui
		lattach(warnGui)
		saveWarn = Instance.new("TextLabel")
		saveWarn.AnchorPoint = Vector2.new(0.5, 0)
		saveWarn.Position = UDim2.new(0.5, 0, 0, 60)
		saveWarn.Size = UDim2.fromOffset(620, 36)
		saveWarn.BackgroundColor3 = ORANGE
		saveWarn.BorderSizePixel = 0
		saveWarn.FontFace = BODYB_FACE
		saveWarn.TextSize = 15
		saveWarn.TextColor3 = Color3.fromRGB(255, 255, 255)
		saveWarn.Text = "⚠  Your save data couldn't load — progress will NOT save. Please rejoin."
		saveWarn.ZIndex = 50
		saveWarn.Parent = warnGui
		corner(saveWarn, 8)
	end
end)

ZoneEnter.OnClientEvent:Connect(function(p)
	if typeof(p) ~= "table" then return end
	status.Text = ""
	if p.mode == "config" then
		unlocks = p.unlocks
		if unlocks then
			if not unlocks.worlds[sel.map] then sel.map = unlocks.worldOrder[1] end
		end
		sel.size = 1
		setPanelMode("config")
		refresh()
	elseif p.mode == "party" then
		setPanelMode("party")
		leaveStatus.Text = ("%s  —  waiting for players..."):format(cap(p.map or "?"))
	else
		setPanelMode("blocked")
		blockedMsg.Text = p.reason or "You can't join this pad right now."
	end
end)

ZoneLeave.OnClientEvent:Connect(function()
	panel.Visible = false
	leaveBtn.Visible = false
	leaveStatus.Visible = false
	status.Text = ""
	zoneMode = nil
	-- CHANGED: clear the pad-UI flag — Play stayed hidden forever after stepping off a pad.
	gui:SetAttribute("PadMode", "")
end)

local lastPartySeconds = math.huge
PartyStatus.OnClientEvent:Connect(function(info)
	if typeof(info) ~= "table" then return end
	local secs = tonumber(info.seconds) or 0
	if secs <= 1 and lastPartySeconds > 1 then
		lplay("TeleportGo")
	end
	lastPartySeconds = secs
	if zoneMode == "party" then
		leaveStatus.Text = ("PARTY %d/%d  ·  STARTING IN %ds"):format(info.count or 1, info.size or 1, info.seconds or 0)
	end
end)

play.Activated:Connect(function()
	if zoneMode == "config" then
		FinalizeParty:FireServer({ map = sel.map, size = sel.size })
	end
end)

leaveBtn.Activated:Connect(function()
	LeaveParty:FireServer()
end)

-- =====================================================================================================
-- ===== INVENTORY (Weapons / Cases / Potions) =========================================================
-- =====================================================================================================
local TweenService = game:GetService("TweenService")
local InvRequest = remotes:WaitForChild("InvRequest")
local BuyGun     = remotes:WaitForChild("BuyGun")
local EquipSkin  = remotes:WaitForChild("EquipSkin")
local InvSync    = remotes:WaitForChild("InvSync")
local EquipSlot = remotes:WaitForChild("EquipSlot")
local OpenCase   = remotes:WaitForChild("OpenCase")
local CaseResult = remotes:WaitForChild("CaseResult")

local invData = nil          -- latest snapshot: { catalog, owned, selected, cases, potions, coins }
local activeTab = "weapons"
local rolling = false
local rollToken = 0          -- watchdog id: if the server never answers an open, unstick `rolling`
local armRollTimeout         -- assigned after the reel exists (needs its upvalues)

LC.BLACK = darker(PANEL, 0.5)

local function rarityColor(rarityId)
	local r = invData and invData.catalog.rarities[rarityId]
	if r then
		return Color3.fromRGB(r.color[1], r.color[2], r.color[3])
	end
	return Color3.fromRGB(160, 160, 170)
end
local function weaponInfo(id)
	return invData and invData.catalog.weapons[id]
end
local function skinInfo(id)
	return invData and invData.catalog.skins and invData.catalog.skins[id]
end
local function ownsGun(id)
	return invData and table.find(invData.owned, id) ~= nil
end
local function ownsSkin(fullId)
	return invData and invData.skins and invData.skins.owned and invData.skins.owned[fullId] == true
end

-- ===== LOBBY HOTBAR (VISUAL ONLY) ===== your loadout at the bottom-center, styled like the game's
-- hotbar. You can't hold guns in the lobby — this just shows what you're taking into the next run.
-- Self-contained: subscribes to InvSync itself (this file sits at Luau's 200-local ceiling, so no
-- new top-level locals).
do
	local SLOT, GAP2 = 84, 10
	local row = Instance.new("Frame")
	row.Name = "LobbyHotbar"
	row.AnchorPoint = Vector2.new(1, 0.5) -- CHANGED: vertical rack on the RIGHT EDGE, centered (V2-A)
	row.Position = UDim2.new(1, -14, 0.5, 0)
	row.Size = UDim2.fromOffset(SLOT, SLOT * 2 + GAP2)
	row.BackgroundTransparency = 1
	row.Parent = gui
	local slots = {}
	for i = 1, 2 do
		local f = Instance.new("Frame")
		f.Position = UDim2.fromOffset(0, (i - 1) * (SLOT + GAP2))
		f.Size = UDim2.fromOffset(SLOT, SLOT)
		f.BackgroundColor3 = PANEL
		f.BackgroundTransparency = 0.05
		f.BorderSizePixel = 0
		f.Visible = false
		f.Parent = row
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, 8) -- crisp rectangle slots, same as the game
		fc.Parent = f
		lstuds(f, 30); ldepth(f); ledge(f, TBLACK, 2.5)
		local key = Instance.new("TextLabel")
		key.Position = UDim2.fromOffset(7, 4); key.Size = UDim2.fromOffset(20, 16); key.ZIndex = 3
		key.BackgroundTransparency = 1; key.FontFace = TITLE_FACE; key.TextSize = 12
		key.TextXAlignment = Enum.TextXAlignment.Left; key.TextColor3 = DIMTEXT
		key.Text = tostring(i); key.Parent = f
		local nmp = Instance.new("TextLabel") -- gun name on a dark strip, same as the game's slots
		nmp.AnchorPoint = Vector2.new(0.5, 1); nmp.Position = UDim2.new(0.5, 0, 1, -4)
		nmp.Size = UDim2.new(1, -10, 0, 26); nmp.ZIndex = 3
		nmp.BackgroundColor3 = Color3.fromRGB(5, 10, 3); nmp.BackgroundTransparency = 0.45
		nmp.FontFace = BODYB_FACE; nmp.TextScaled = true; nmp.TextColor3 = TEXTCOL; nmp.Text = ""
		nmp.Parent = f
		local nmc = Instance.new("UICorner"); nmc.CornerRadius = UDim.new(0, 6); nmc.Parent = nmp
		local ncon = Instance.new("UITextSizeConstraint"); ncon.MaxTextSize = 14; ncon.Parent = nmp
		slots[i] = { frame = f, name = nmp, vp = nil, vpId = nil }
	end
	local lastSnap, retryArmed, vpRetries = nil, false, 0
	local function renderRow(snap)
		lastSnap = snap
		for i = 1, 2 do
			local sl = slots[i]
			local id = snap.loadout and snap.loadout[i]
			-- Read the catalog off THIS snapshot first (invData may not be assigned yet on the very
			-- first push — handler order), falling back to the shared lookup.
			local w = id and ((snap.catalog and snap.catalog.weapons and snap.catalog.weapons[id]) or weaponInfo(id))
			if w then
				sl.frame.Visible = true
				if sl.vpId ~= id then
					if sl.vp then
						sl.vp:Destroy()
						sl.vp = nil
					end
					local vp = makeGunViewport(id, false)
					if vp then
						vp.AnchorPoint = Vector2.new(0.5, 0); vp.Position = UDim2.new(0.5, 0, 0, 2)
						vp.Size = UDim2.new(1, -8, 1, -32); vp.ZIndex = 2; vp.Parent = sl.frame
						sl.vp = vp
						sl.vpId = id
					elseif vpRetries < 30 and not retryArmed then
						-- CHANGED: no model YET (GunDisplay replicates after the first join snapshot) —
						-- retry instead of stamping the slot done with an empty well.
						retryArmed = true
						vpRetries += 1
						task.delay(1, function()
							retryArmed = false
							if lastSnap then renderRow(lastSnap) end
						end)
					end
				end
				sl.name.Text = w.name
			else
				sl.frame.Visible = false
				if sl.vp then
					sl.vp:Destroy()
					sl.vp = nil
					sl.vpId = nil
				end
			end
		end
	end
	InvSync.OnClientEvent:Connect(function(snap)
		if typeof(snap) == "table" then
			renderRow(snap)
		end
	end)
end
local function ownsSet()
	local s = {}
	if invData then
		for _, id in invData.owned do s[id] = true end
	end
	return s
end

-- ===== INVENTORY GUI ===== top tab strip over a full-width grid; clicking a card slides in a DETAIL
-- pane on the right (equip / upgrade / open / info). Click the card again or the pane's X to close it.
local invGui = Instance.new("ScreenGui")
invGui.Name = "LobbyInventory"; invGui.ResetOnSpawn = false; invGui.IgnoreGuiInset = true; invGui.DisplayOrder = 11
invGui.Parent = playerGui
lattach(invGui)

local function hideTip() end -- (legacy no-op: hover tooltips were replaced by the detail pane)

-- =====================================================================================================
-- ===== THE DOCK (Rivals-style, the approved V-A mock) ===== a faded black bar across the bottom, a
-- row of seven dark-glass circle buttons with their icons popping over the top edge, Title-case labels
-- sitting ON the circles' lower rim, white-rimmed red badges, and the glossy borderless Play above.
-- Owner photos go in DOCK_ICONS (any square image); until then the existing photos + emoji stand in.
-- =====================================================================================================
LC.GUN_ICON = "rbxassetid://107465960874017"
LC.CASES_ICON = "rbxassetid://83465359983310"
local dockBtns = {} -- every dock button + badge, one table (200-local ceiling)
do
	local DOCK_ICONS = { -- paste your photo ids here ("rbxassetid://..." or the number). "" = emoji.
		inventory = "119161862051444",
		weapons = "102091580612843",
		daily = "85053185478907",
		shop = "71412141929869",
		classes = "97897139122117",
		settings = "94140673883223",
		codes = "106591567271932",
	}
	local DOCK_EMOJI = { inventory = "🎒", weapons = "🔫", daily = "🎡", shop = "🧺", classes = "🛡️", settings = "⚙️", codes = "🔑" }
	local ORDER = { "weapons", "daily", "shop", "classes", "settings", "codes" } -- inventory merged into LOCKER
	local LABELS = { weapons = "Locker", daily = "Daily", shop = "Shop", classes = "Classes", settings = "Settings", codes = "Codes" }

	-- The faded black bar behind everything (pure gradient, no border — melts into the floor).
	local fade = Instance.new("Frame")
	fade.Name = "DockFade"
	fade.AnchorPoint = Vector2.new(0, 1)
	fade.Position = UDim2.new(0, 0, 1, 0)
	fade.Size = UDim2.new(1, 0, 0, 170)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BorderSizePixel = 0
	-- CHANGED: the fade gets its OWN ScreenGui UNDER every HUD layer (DisplayOrder 9 < LobbyHUD's 10).
	-- Same-gui ZIndex juggling kept losing — the coins pill still rendered dim under it.
	local fadeGui = Instance.new("ScreenGui")
	fadeGui.Name = "LobbyDockFade"
	fadeGui.ResetOnSpawn = false
	fadeGui.IgnoreGuiInset = true
	fadeGui.DisplayOrder = 9
	fadeGui.Parent = playerGui
	lattach(fadeGui)
	fade.Parent = fadeGui
	fade.Size = UDim2.new(1, 0, 0, 148) -- CHANGED: shorter — 195 was dimming the coins/XP readouts
	local fg = Instance.new("UIGradient")
	fg.Rotation = 90
	fg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.45, 0.5),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	fg.Parent = fade

	local function dockBtn(i, key)
		local holder = Instance.new("Frame")
		holder.Name = "Dock_" .. key
		holder.AnchorPoint = Vector2.new(0, 1)
		-- Centered for ANY button count (the old -282 was hand-tuned for seven; removing Inventory
		-- left the six-button dock hanging off-center).
		holder.Position = UDim2.new(0.5, -math.floor(((#ORDER - 1) * 83 + 66) / 2) + (i - 1) * 83, 1, -6)
		holder.Size = UDim2.fromOffset(66, 84)
		holder.BackgroundTransparency = 1
		holder.ZIndex = 2
		holder.Parent = invGui
		local circ = Instance.new("ImageButton") -- the dark-glass circle IS the click target
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
		local cg = Instance.new("UIGradient") -- absolute colors: near-black glass with a top light-catch
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
		-- Photos get ROUND-CROPPED inside the circle (square art with solid backgrounds read as white
		-- boxes when popped over the rim — transparent PNG renders can pop later); emoji still pop.
		local iconId = DOCK_ICONS[key]
		if iconId ~= "" then
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
		else
			local e = Instance.new("TextLabel")
			e.AnchorPoint = Vector2.new(0.5, 0)
			e.Position = UDim2.new(0.5, 0, 0, -6)
			e.Size = UDim2.fromOffset(58, 56)
			e.BackgroundTransparency = 1
			e.FontFace = TITLE_FACE
			e.TextSize = 44
			e.Text = DOCK_EMOJI[key]
			e.ZIndex = 3
			e.Parent = holder
		end
		local lbl = Instance.new("TextLabel") -- Title case, ON the circle's lower rim (the Rivals detail)
		lbl.AnchorPoint = Vector2.new(0.5, 1)
		lbl.Position = UDim2.new(0.5, 0, 1, 0)
		lbl.Size = UDim2.fromOffset(84, 16)
		lbl.BackgroundTransparency = 1
		lbl.FontFace = BODYB_FACE
		lbl.TextSize = 13
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.ZIndex = 4
		lbl.Text = LABELS[key]
		lbl.Parent = holder
		local ls = Instance.new("UIStroke")
		ls.Color = Color3.new(0, 0, 0)
		ls.Transparency = 0.25
		ls.Thickness = 1.6
		ls.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		ls.Parent = lbl
		local badge = Instance.new("Frame") -- white-rimmed red badge, hidden until something's waiting
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
		local bs = Instance.new("UIStroke")
		bs.Color = Color3.new(1, 1, 1)
		bs.Transparency = 0.15
		bs.Thickness = 1.5
		bs.Parent = badge
		local bt = Instance.new("TextLabel")
		bt.Name = "N"
		bt.Size = UDim2.fromScale(1, 1)
		bt.BackgroundTransparency = 1
		bt.FontFace = BODYB_FACE
		bt.TextSize = 13
		bt.TextColor3 = Color3.new(1, 1, 1)
		bt.Text = "!"
		bt.ZIndex = 6
		bt.Parent = badge
		-- hover/press pop — CHANGED: tweened now (the instant snaps read as jitter, not juice)
		local ts = game:GetService("TweenService")
		local press = Instance.new("UIScale")
		press.Parent = holder
		local function to(v, t, style)
			ts:Create(press, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = v }):Play()
		end
		circ.MouseEnter:Connect(function() to(1.08, 0.09) end)
		circ.MouseLeave:Connect(function() to(1, 0.09) end)
		circ.MouseButton1Down:Connect(function() to(0.9, 0.05) end)
		circ.MouseButton1Up:Connect(function() to(1.08, 0.14, Enum.EasingStyle.Back) end)
		dockBtns[key] = circ
		dockBtns[key .. "Badge"] = badge
		return circ
	end
	for i, key in ORDER do
		dockBtn(i, key)
	end
end
local gunsBtn = dockBtns.weapons -- the LOCKER button (guns + crates live in one panel now)

-- PLAY — the game place's chunky slab-and-face button (UITheme.Button "primary"), synced by hand:
-- dark slab with a 5px lip, bright toxic-gradient face with its own black ring, white stencil text,
-- face slides DOWN onto the slab on press. Steps you onto the nearest free party pad.
local playBtn = Instance.new("TextButton")
playBtn.Name = "PlayButton"
playBtn.AnchorPoint = Vector2.new(0.5, 1)
playBtn.Position = UDim2.new(0.5, 0, 1, -102)
playBtn.Size = UDim2.fromOffset(206, 56)
playBtn.BorderSizePixel = 0
playBtn.AutoButtonColor = false
playBtn.Text = ""
playBtn.ZIndex = 2
playBtn.Parent = invGui
do
	local white = Color3.new(1, 1, 1)
	local base = ACCENT
	local baseDk = Color3.fromRGB(58, 116, 16) -- TOXIC_DK from the game theme
	playBtn.BackgroundColor3 = darker(baseDk, 0.35) -- the slab
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 10)
	pc.Parent = playBtn
	ledge(playBtn, TBLACK, 3)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -5) -- the slab shows as a 5px lip below
	face.BackgroundColor3 = white
	face.BorderSizePixel = 0
	face.ZIndex = 3
	face.Parent = playBtn
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 10)
	fc.Parent = face
	ledge(face, TBLACK, 2.5) -- the face needs its OWN black ring (it covers the slab's)
	local pg = Instance.new("UIGradient") -- absolute colors: bright top flash baked in
	pg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, base:Lerp(white, 0.42)),
		ColorSequenceKeypoint.new(0.07, base:Lerp(white, 0.18)),
		ColorSequenceKeypoint.new(1, darker(base, 0.28)),
	})
	pg.Rotation = 90
	pg.Parent = face

	local pt = Instance.new("TextLabel")
	pt.Size = UDim2.fromScale(1, 1)
	pt.BackgroundTransparency = 1
	pt.FontFace = TITLE_FACE
	pt.TextSize = 26
	pt.TextColor3 = white
	pt.Text = "PLAY"
	pt.ZIndex = 4
	pt.Parent = face
	local pts = Instance.new("UIStroke")
	pts.Color = TBLACK
	pts.Thickness = 2.5
	pts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	pts.Parent = pt

	-- Press = the face slides down onto the slab (same feel as every in-game button),
	-- plus the tweened hover grow / press squish the rest of the buttons get.
	local ts = game:GetService("TweenService")
	local sc = Instance.new("UIScale")
	sc.Parent = playBtn
	local function to(v, t, style)
		ts:Create(sc, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = v }):Play()
	end
	playBtn.MouseEnter:Connect(function()
		to(1.05, 0.09)
	end)
	playBtn.MouseButton1Down:Connect(function()
		face.Position = UDim2.fromOffset(0, 4)
		to(0.95, 0.05)
	end)
	playBtn.MouseButton1Up:Connect(function()
		face.Position = UDim2.new()
		to(1.05, 0.14, Enum.EasingStyle.Back)
	end)
	playBtn.MouseLeave:Connect(function()
		face.Position = UDim2.new()
		to(1, 0.09)
	end)
end
playBtn.Activated:Connect(function()
	lplay("Open")
	remotes:WaitForChild("GoPlay"):FireServer()
end)
-- A pad UI (config/party) owns the bottom-center while it's up — Play steps aside (see setPanelMode).
gui:GetAttributeChangedSignal("PadMode"):Connect(function()
	playBtn.Visible = (gui:GetAttribute("PadMode") or "") == ""
end)

local PANEL_W, PANEL_H = 940, 540

-- REDONE CHROME (matched to the reference image): one root assembly — the wide colored header bar
-- (title left, red X inside its right end) with the dark body tucked underneath. invPanel is the BODY;
-- its Visible flag stays the open/closed source of truth (openScreen and friends toggle it) and the
-- root mirrors it so the header follows. Coins live in the always-on top-left counter, not the header.
local invPanel, invTitle, invClose, invRecolor
do
	local root
	root, invPanel, invTitle, invClose, invRecolor = chromePanel(invGui, PANEL_W, PANEL_H, LC.HEADER_COLORS.guns, "LOCKER")
	invPanel.Visible = false
	invPanel:GetPropertyChangedSignal("Visible"):Connect(function()
		root.Visible = invPanel.Visible
	end)
end

-- (No tab strip: GUNS and CASES are separate screens sharing this panel; the header shows which.)

-- Same 3-region skeleton as the SHOP: card grid (left) | featured pane, always visible (middle) |
-- action-button stack (right).
local CONTENT_Y = 24 -- the header lives ABOVE the body now, so content starts near the top
-- INSPECT-VIEW LAYOUT (approved plan): GRID mode = a full-width 6-column grid; clicking a card flips
-- the panel into INSPECT mode — a full-size page for that item. Two sibling frames, one Visible toggle.
local invGrid = Instance.new("ScrollingFrame")
invGrid.Position = UDim2.fromOffset(16, CONTENT_Y); invGrid.Size = UDim2.fromOffset(PANEL_W - 32, PANEL_H - CONTENT_Y - 16 - 24)
invGrid.BackgroundTransparency = 1; invGrid.BorderSizePixel = 0; invGrid.ScrollBarThickness = 6
invGrid.CanvasSize = UDim2.new(); invGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y; invGrid.Parent = invPanel
local invGridLayout = Instance.new("UIGridLayout")
invGridLayout.CellSize = UDim2.fromOffset(138, 158); invGridLayout.CellPadding = UDim2.fromOffset(11, 11); invGridLayout.Parent = invGrid -- ticket cards, 138x158 per the mock

local invHint = Instance.new("TextLabel") -- "CLICK A GUN TO INSPECT IT" strip under the grid
invHint.AnchorPoint = Vector2.new(0, 1); invHint.Position = UDim2.new(0, 16, 1, -12)
invHint.Size = UDim2.fromOffset(PANEL_W - 32, 18); invHint.BackgroundTransparency = 1
invHint.FontFace = BODYB_FACE; invHint.TextSize = 12; invHint.TextColor3 = DIMTEXT
invHint.Text = "CLICK SOMETHING TO INSPECT IT"; invHint.Parent = invPanel

local invDetail = Instance.new("Frame") -- INSPECT mode: fills the whole panel body
invDetail.Position = UDim2.fromOffset(16, CONTENT_Y)
invDetail.Size = UDim2.fromOffset(PANEL_W - 32, PANEL_H - CONTENT_Y - 16)
invDetail.Visible = false -- GRID mode by default; selecting a card flips this on (and the grid off)
invDetail.BackgroundTransparency = 1; invDetail.BorderSizePixel = 0; invDetail.Parent = invPanel

local invActs = Instance.new("Frame") -- (legacy right stack — the sheet owns all actions now)
invActs.AnchorPoint = Vector2.new(1, 0); invActs.Position = UDim2.new(1, -16, 0, CONTENT_Y)
invActs.Size = UDim2.fromOffset(250, PANEL_H - CONTENT_Y - 16); invActs.BackgroundTransparency = 1
invActs.Visible = false; invActs.Parent = invPanel

local selectedInv = nil -- { kind = "weapon"|"case"|"potion", id } — drives the featured pane

local renderActive -- forward decl (grid + detail render)
local playReel -- forward decl (the reel section below assigns it)

-- WEAPON CATEGORY sub-tabs: LEVEL / CRATE / EVENT. Only shown on the WEAPONS screen; the current pick
-- rides on invGrid:GetAttribute("WeaponCat") (an attribute, not a new local — the client is at Luau's
-- 200-local ceiling). Guns declare which bucket they live in via WEAPONS[id].source ("level" default).
do
	local catRow = Instance.new("Frame")
	catRow.Name = "WeaponCatRow"
	catRow.Position = UDim2.fromOffset(96, CONTENT_Y)
	catRow.Size = UDim2.fromOffset(PANEL_W - 32, 34)
	catRow.BackgroundTransparency = 1
	catRow.Visible = false
	catRow.Parent = invPanel
	local ll = Instance.new("UIListLayout")
	ll.FillDirection = Enum.FillDirection.Horizontal
	ll.Padding = UDim.new(0, 8)
	ll.Parent = catRow
	invGrid:SetAttribute("WeaponCat", "level")
	local defs = { { "level", "LEVEL" }, { "event", "EVENT" } } -- CRATE tab removed (collided with the CRATES side tab)
	local btns = {}
	local function paint()
		local cur = invGrid:GetAttribute("WeaponCat") or "level"
		for _, b in btns do
			local on = b:GetAttribute("cat") == cur
			b.BackgroundColor3 = on and ACCENT or CARD
			b.TextColor3 = on and Color3.new(1, 1, 1) or TEXTCOL
		end
	end
	for i, d in defs do
		local b = Instance.new("TextButton")
		b.Name = "Cat_" .. d[1]
		b:SetAttribute("cat", d[1])
		b.LayoutOrder = i
		b.Size = UDim2.fromOffset(122, 34)
		b.BackgroundColor3 = CARD
		b.AutoButtonColor = true
		b.FontFace = BODYB_FACE
		b.TextSize = 15
		b.TextColor3 = TEXTCOL
		b.Text = d[2]
		b.Parent = catRow
		corner(b, 6)
		ledge(b, TBLACK, 2)
		table.insert(btns, b)
		b.Activated:Connect(function()
			if invGrid:GetAttribute("WeaponCat") == d[1] then
				return
			end
			invGrid:SetAttribute("WeaponCat", d[1])
			lplay("Click")
			paint()
			if renderActive then renderActive() end
		end)
	end
	paint()
end

local function invSelect(kind, id)
	print(("[LobbyInv] card clicked: %s %s"):format(tostring(kind), tostring(id))) -- diagnostic breadcrumb
	selectedInv = { kind = kind, id = id } -- pane is permanent; clicking just features the item
	renderActive()
end

local function clearChildren(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

-- v3 TICKET card (the approved, engine-true design): dark art window with a faint rarity tint up
-- top, and a SOLID rarity bar on the bottom third carrying the name in white sticker text + the
-- rarity word. No glows, no fakes — every element is a flat fill, one vertical gradient, or a stroke.
local BAR_H = 32
local function invCard(opts)
	local col = opts.color
	local isSel = selectedInv and selectedInv.kind == opts.kind and selectedInv.id == opts.id

	local f = Instance.new("TextButton")
	f.BackgroundColor3 = Color3.fromRGB(28, 33, 23)
	f.AutoButtonColor = true
	f.Text = ""
	f.BorderSizePixel = 0
	f.ClipsDescendants = true
	f.LayoutOrder = opts.order or 0
	f.Parent = invGrid
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 12)
	fc.Parent = f
	-- Ring states: selected gold / next-unlock gold / plain black.
	-- EQUIPPED guns wear a thick TOXIC ring (gold stays for selection/next-up)
	ledge(f, (opts.equipped and ACCENT) or ((isSel or opts.nextUp) and GOLD) or TBLACK,
		(opts.equipped or isSel or opts.nextUp) and 3.5 or 3)

	-- ART WINDOW: white frame + absolute-color gradient (gradients only multiply, same trick as the
	-- buttons) — faint rarity tint at the top fading to near-black.
	local art = Instance.new("Frame")
	art.Size = UDim2.new(1, 0, 1, -(BAR_H + 3))
	art.BackgroundColor3 = Color3.new(1, 1, 1)
	art.BorderSizePixel = 0
	art.Parent = f
	local ag = Instance.new("UIGradient")
	if opts.locked then
		ag.Color = ColorSequence.new(Color3.fromRGB(36, 41, 32), Color3.fromRGB(24, 28, 19))
	else
		ag.Color = ColorSequence.new(Color3.fromRGB(32, 38, 26):Lerp(col, 0.16), Color3.fromRGB(25, 30, 20))
	end
	ag.Rotation = 90
	ag.Parent = art

	-- 3px black separator between the window and the bar.
	local sep = Instance.new("Frame")
	sep.AnchorPoint = Vector2.new(0, 1)
	sep.Position = UDim2.new(0, 0, 1, -BAR_H)
	sep.Size = UDim2.new(1, 0, 0, 3)
	sep.BackgroundColor3 = TBLACK
	sep.BorderSizePixel = 0
	sep.ZIndex = 3
	sep.Parent = f

	-- The item, big in the window (static — only the inspect page spins).
	local showedModel = false
	if opts.kind == "weapon" or opts.kind == "case" or opts.kind == "skin" then
		local vp
		if opts.kind == "skin" then
			local sk = skinInfo(opts.id)
			vp = makeGunViewport(opts.id, false) or (sk and makeGunViewport(sk.gun, false))
		else
			vp = makeGunViewport(opts.id, false, opts.kind == "case" and "CrateDisplay" or nil)
		end
		if vp then
			vp.AnchorPoint = Vector2.new(0.5, 0.5)
			vp.Position = UDim2.new(0.5, 0, 0.5, -math.floor((BAR_H + 3) / 2))
			vp.Size = UDim2.new(1, -10, 1, -(BAR_H + 16))
			vp.ZIndex = 2
			if opts.locked then
				vp.ImageColor3 = Color3.new(0, 0, 0) -- locked = black SILHOUETTE
				vp.ImageTransparency = 0.1
			end
			vp.Parent = f
			showedModel = true
		end
	end
	if not showedModel and typeof(opts.image) == "string" and opts.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.new(0.5, 0, 0.5, -math.floor((BAR_H + 3) / 2))
		img.Size = UDim2.new(1, -10, 1, -(BAR_H + 16))
		img.BackgroundTransparency = 1
		img.Image = opts.image
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = 2
		img.Parent = f
		showedModel = true
	end
	if not showedModel then
		-- NO MODEL YET: the name fills the window instead of leaving a hole.
		local noml = Instance.new("TextLabel")
		noml.AnchorPoint = Vector2.new(0.5, 0.5)
		noml.Position = UDim2.new(0.5, 0, 0.5, -math.floor((BAR_H + 3) / 2))
		noml.Size = UDim2.new(1, -14, 0, 40)
		noml.BackgroundTransparency = 1
		noml.FontFace = TITLE_FACE
		noml.TextSize = 14
		noml.TextWrapped = true
		noml.TextColor3 = opts.locked and DIMTEXT or col
		noml.Text = opts.name
		noml.ZIndex = 2
		noml.Parent = f
		local nstr = Instance.new("UIStroke")
		nstr.Color = TBLACK
		nstr.Thickness = 2
		nstr.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		nstr.Parent = noml
	end

	-- RARITY BAR: solid rarity color (grey when locked), white sticker name + tiny rarity word.
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 0, 1, 0)
	bar.Size = UDim2.new(1, 0, 0, BAR_H)
	bar.BackgroundColor3 = opts.locked and Color3.fromRGB(58, 65, 52) or col
	bar.BorderSizePixel = 0
	bar.ZIndex = 3
	bar.Parent = f
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(4, 2)
	nm.Size = UDim2.new(1, -8, 0, 16)
	nm.BackgroundTransparency = 1
	nm.FontFace = TITLE_FACE
	nm.TextSize = 13
	nm.ZIndex = 4
	nm.TextTruncate = Enum.TextTruncate.AtEnd
	nm.TextColor3 = opts.locked and DIMTEXT or Color3.new(1, 1, 1)
	nm.Text = string.upper(opts.name or "")
	nm.Parent = bar
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = TBLACK
	nmStroke.Thickness = 2
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nmStroke.Parent = nm
	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(4, 18)
	sub.Size = UDim2.new(1, -8, 0, 11)
	sub.BackgroundTransparency = 1
	sub.FontFace = BODYB_FACE
	sub.TextSize = 9
	sub.ZIndex = 4
	sub.TextColor3 = TBLACK
	sub.TextTransparency = 0.25
	sub.Text = opts.subText or ""
	sub.Parent = bar

	if opts.equipped then
		-- EQUIPPED: a full-width toxic band sitting right on top of the rarity bar — unmissable, and it
		-- stays off the gun art (the old floating chip covered the render).
		local band = Instance.new("TextLabel")
		band.AnchorPoint = Vector2.new(0, 1)
		band.Position = UDim2.new(0, 0, 1, -BAR_H)
		band.Size = UDim2.new(1, 0, 0, 18)
		band.BackgroundColor3 = ACCENT
		band.BorderSizePixel = 0
		band.ZIndex = 4
		band.FontFace = TITLE_FACE
		band.TextSize = 12
		band.TextColor3 = Color3.new(1, 1, 1)
		band.Text = "✓ EQUIPPED"
		band.Parent = f
		local bs = Instance.new("UIStroke")
		bs.Color = TBLACK
		bs.Thickness = 2
		bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		bs.Parent = band
		local seam = Instance.new("Frame")
		seam.AnchorPoint = Vector2.new(0, 0)
		seam.Position = UDim2.new(0, 0, 0, 0)
		seam.Size = UDim2.new(1, 0, 0, 2)
		seam.BackgroundColor3 = TBLACK
		seam.BorderSizePixel = 0
		seam.ZIndex = 5
		seam.Parent = band
	end
	if opts.chip then -- sticker chip hanging top-left (NEXT UP gold / PRIM etc.)
		local isGoldChip = opts.chip == "NEXT UP"
		local chip = Instance.new("TextLabel")
		chip.Position = UDim2.fromOffset(6, 6)
		chip.AutomaticSize = Enum.AutomaticSize.X
		chip.Size = UDim2.fromOffset(0, 19)
		chip.BackgroundColor3 = isGoldChip and GOLD or ACCENT
		chip.BorderSizePixel = 0
		chip.ZIndex = 4
		chip.FontFace = TITLE_FACE
		chip.TextSize = 10
		chip.TextColor3 = isGoldChip and TBLACK or Color3.new(1, 1, 1)
		chip.Text = opts.chip
		chip.Parent = f
		local chPad = Instance.new("UIPadding")
		chPad.PaddingLeft = UDim.new(0, 6)
		chPad.PaddingRight = UDim.new(0, 6)
		chPad.Parent = chip
		local chc = Instance.new("UICorner")
		chc.CornerRadius = UDim.new(0, 7)
		chc.Parent = chip
		ledge(chip, TBLACK, 2.5)
		if not isGoldChip then
			local chStroke = Instance.new("UIStroke")
			chStroke.Color = TBLACK
			chStroke.Thickness = 1.5
			chStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			chStroke.Parent = chip
		end
	end
	if opts.count then -- gold ×n pill, top-right (crate counts)
		local cnt = Instance.new("TextLabel")
		cnt.AnchorPoint = Vector2.new(1, 0)
		cnt.Position = UDim2.new(1, -6, 0, 6)
		cnt.AutomaticSize = Enum.AutomaticSize.X
		cnt.Size = UDim2.fromOffset(0, 19)
		cnt.BackgroundColor3 = GOLD
		cnt.BorderSizePixel = 0
		cnt.ZIndex = 4
		cnt.FontFace = TITLE_FACE
		cnt.TextSize = 12
		cnt.TextColor3 = TBLACK
		cnt.Text = "×" .. tostring(opts.count)
		cnt.Parent = f
		local cnPad = Instance.new("UIPadding")
		cnPad.PaddingLeft = UDim.new(0, 6)
		cnPad.PaddingRight = UDim.new(0, 6)
		cnPad.Parent = cnt
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(1, 0)
		cc.Parent = cnt
		ledge(cnt, TBLACK, 2.5)
	end
	if opts.lockLevel then -- gold LV plate over the silhouette
		local plate = Instance.new("TextLabel")
		plate.AnchorPoint = Vector2.new(0.5, 0)
		plate.Position = UDim2.new(0.5, 0, 0, 46)
		plate.Size = UDim2.fromOffset(110, 22)
		plate.BackgroundTransparency = 1
		plate.ZIndex = 4
		plate.FontFace = TITLE_FACE
		plate.TextSize = 17
		plate.TextColor3 = GOLD
		plate.Text = "LV " .. tostring(opts.lockLevel)
		plate.Parent = f
		local pStroke = Instance.new("UIStroke")
		pStroke.Color = TBLACK
		pStroke.Thickness = 2.5
		pStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		pStroke.Parent = plate
	end

	f.Activated:Connect(function()
		invSelect(opts.kind, opts.id)
	end)
	return f
end

-- Themed action button for the detail pane. LC.GHOSTA/LC.GHOSTB sit a step lighter than the pane itself so
-- neutral buttons still read as buttons (they used to use PANEL2-on-PANEL2 and vanished).
LC.GHOSTA = Color3.fromRGB(54, 60, 42)
LC.GHOSTB = Color3.fromRGB(42, 47, 33)
local function bigButton(parent, textStr, fillA, fillB, textCol)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = fillA; b.BorderSizePixel = 0; b.AutoButtonColor = true
	b.FontFace = TITLE_FACE; b.TextSize = 18; b.TextColor3 = textCol; b.Text = textStr; b.Parent = parent
	corner(b, 5); ledge(b, TBLACK, 3)
	lbevel(b) -- full 3D treatment (gradient + slab lip + press) derived from fillA
	return b
end
local function paneButton(textStr, fillA, fillB, textCol)
	return bigButton(invDetail, textStr, fillA, fillB, textCol) -- actions live ON the sliding sheet now
end

-- ===== FEATURED PANE (middle) + ACTION STACK (right) =====
local function renderInvDetail()
	clearChildren(invDetail)
	clearChildren(invActs)
	-- MODE FLIP — the whole mechanism: inspecting shows this frame and hides the grid. One boolean.
	local showing = invData ~= nil and selectedInv ~= nil
	invDetail.Visible = showing
	invGrid.Visible = not showing
	invHint.Visible = not showing
	if not showing then
		return
	end
	local kind, id = selectedInv.kind, selectedInv.id
	print(("[LobbyInv] inspect -> %s %s"):format(tostring(kind), tostring(id)))

	local entry, tint
	if kind == "weapon" then entry = weaponInfo(id); tint = entry and rarityColor(entry.rarity)
	elseif kind == "case" then entry = invData.catalog.cases[id]; tint = rarityColor(id) end
	if not entry then
		selectedInv = nil
		invDetail.Visible = false
		invGrid.Visible = true
		invHint.Visible = true
		return
	end

	local W = PANEL_W - 32
	local H = PANEL_H - CONTENT_Y - 16
	local LEFT_W = 380
	local RIGHT_X = LEFT_W + 14
	local RIGHT_W = W - RIGHT_X

	-- LEFT: the display well — big spinning model, rarity line, BACK, prev/next arrows.
	local ileft = Instance.new("Frame")
	ileft.Size = UDim2.fromOffset(LEFT_W, H)
	ileft.BackgroundColor3 = tint:Lerp(LC.BLACK, 0.72); ileft.BorderSizePixel = 0; ileft.Parent = invDetail
	corner(ileft, 8); ledge(ileft, TBLACK, 2.5); cardShade(ileft, 0.3)

	-- NEW: a weapon renders with its EQUIPPED skin — the skin's own model if the owner built one,
	-- else the base gun tinted with the skin color — so equipping a skin visibly changes the page.
	local wellVp
	if kind == "weapon" then
		local eqSkin = invData.skins and invData.skins.equipped and invData.skins.equipped[id]
		if eqSkin then
			wellVp = makeGunViewport(id .. "_" .. eqSkin, true)
			if not wellVp then
				local sn = invData.catalog.skins[id .. "_" .. eqSkin]
				wellVp = makeGunViewport(id, true, nil, sn and sn.tint)
			end
		end
	end
	wellVp = wellVp or makeGunViewport(id, true, kind == "case" and "CrateDisplay" or nil)
	if wellVp then
		wellVp.Position = UDim2.fromOffset(14, 44); wellVp.Size = UDim2.new(1, -28, 1, -134); wellVp.Parent = ileft
	elseif typeof(entry.image) == "string" and entry.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.Position = UDim2.fromOffset(14, 44); img.Size = UDim2.new(1, -28, 1, -134)
		img.BackgroundTransparency = 1; img.Image = entry.image; img.ScaleType = Enum.ScaleType.Fit; img.Parent = ileft
	else
		local plate = Instance.new("TextLabel")
		plate.Position = UDim2.fromOffset(14, 44); plate.Size = UDim2.new(1, -28, 1, -134)
		plate.BackgroundTransparency = 1; plate.FontFace = TITLE_FACE; plate.TextSize = 26
		plate.TextColor3 = tint; plate.Text = "NO MODEL YET"; plate.Parent = ileft
	end

	local rar = Instance.new("TextLabel")
	rar.AnchorPoint = Vector2.new(0.5, 1); rar.Position = UDim2.new(0.5, 0, 1, -62)
	rar.Size = UDim2.new(1, -20, 0, 20); rar.BackgroundTransparency = 1
	rar.FontFace = BODYB_FACE; rar.TextSize = 13; rar.TextColor3 = tint:Lerp(Color3.new(1, 1, 1), 0.35)
	if kind == "weapon" then
		rar.Text = (((invData.catalog.rarities[entry.rarity] or {}).name or ""):upper())
			.. " · " .. ((entry.slot == "secondary") and "SECONDARY" or "PRIMARY")
	else
		rar.Text = ("YOU HAVE ×%d"):format(invData.cases[id] or 0)
	end
	rar.Parent = ileft

	local back = bigButton(ileft, "← BACK", LC.GHOSTA, LC.GHOSTB, TEXTCOL)
	back.Position = UDim2.fromOffset(10, 10); back.Size = UDim2.fromOffset(96, 34); back.TextSize = 14
	back.Activated:Connect(function()
		lplay("Close")
		selectedInv = nil
		renderActive()
	end)

	-- ◀ ▶ flip through the SAME list the grid shows (renderActive stashes it on the snapshot).
	local entries = (invData and invData._entries) or {}
	local function arrow(sym, xOff, dir)
		local a = bigButton(ileft, sym, LC.GHOSTA, LC.GHOSTB, TEXTCOL)
		a.AnchorPoint = Vector2.new(0.5, 1); a.Position = UDim2.new(0.5, xOff, 1, -12)
		a.Size = UDim2.fromOffset(46, 34); a.TextSize = 15
		a.Activated:Connect(function()
			if #entries == 0 then
				return
			end
			local idx
			for i, e in entries do
				if e.kind == kind and e.id == id then
					idx = i
					break
				end
			end
			idx = ((idx or 1) - 1 + dir) % #entries + 1
			lplay("Click")
			selectedInv = { kind = entries[idx].kind, id = entries[idx].id }
			renderActive()
		end)
		return a
	end
	arrow("◀", -30, -1)
	arrow("▶", 30, 1)

	-- RIGHT: everything about the item.
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(RIGHT_X, 2); nm.Size = UDim2.fromOffset(RIGHT_W, 32)
	nm.BackgroundTransparency = 1; nm.FontFace = TITLE_FACE; nm.TextSize = 24
	nm.TextXAlignment = Enum.TextXAlignment.Left; nm.TextColor3 = tint
	nm.Text = entry.name; nm.Parent = invDetail
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = TBLACK; nmStroke.Thickness = 1.6
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; nmStroke.Parent = nm

	if kind == "weapon" then
		local w = entry
		-- STATE CHIP after the name.
		do
			local owned = ownsGun(id)
			local isEq = invData.loadout[1] == id or invData.loadout[2] == id
			local nextUnlockId
			do
				local ladder = {}
				for gid in invData.catalog.weapons do
					table.insert(ladder, gid)
				end
				table.sort(ladder, function(a, b)
					local wa, wb = weaponInfo(a), weaponInfo(b)
					if (wa.unlock or 0) ~= (wb.unlock or 0) then
						return (wa.unlock or 0) < (wb.unlock or 0)
					end
					return a < b
				end)
				for _, gid in ladder do
					if not ownsGun(gid) then
						nextUnlockId = gid
						break
					end
				end
			end
			local chipText, chipCol
			if isEq then
				chipText, chipCol = "EQUIPPED", ACCENT
			elseif owned then
				chipText, chipCol = "OWNED", DIMTEXT
			elseif id == nextUnlockId then
				chipText, chipCol = "NEXT UP", GOLD
			else
				chipText, chipCol = "LOCKED", DIMTEXT
			end
			local chip = Instance.new("TextLabel")
			chip.Size = UDim2.fromOffset(math.max(60, #chipText * 8 + 20), 20)
			chip.BackgroundColor3 = darker(chipCol, 0.72); chip.BorderSizePixel = 0
			chip.FontFace = BODYB_FACE; chip.TextSize = 11; chip.TextColor3 = chipCol
			chip.Text = chipText; chip.Parent = invDetail
			corner(chip, 8); ledge(chip, TBLACK, 2)
			chip.Position = UDim2.fromOffset(RIGHT_X + 220, 8)
			task.defer(function()
				if chip.Parent then
					chip.Position = UDim2.fromOffset(RIGHT_X + math.min(nm.TextBounds.X, RIGHT_W - 90) + 12, 8)
				end
			end)
		end
		-- STAT BARS — DAMAGE / FIRE RATE / RANGE / KNOCKBACK.
		do
			local maxD, maxR, maxRng, maxK = 1, 1, 1, 1
			for _, ww in invData.catalog.weapons do
				maxD = math.max(maxD, (ww.damage or 0) * (ww.pellets or 1))
				maxR = math.max(maxR, ww.fireRate or 0)
				maxRng = math.max(maxRng, ww.range or 0)
				maxK = math.max(maxK, ww.knockback or 0)
			end
			local rows = {
				{ "DAMAGE", (w.damage or 0) * (w.pellets or 1), maxD },
				{ "FIRE RATE", w.fireRate or 0, maxR },
				{ "RANGE", w.range or 0, maxRng },
				{ "KNOCKBACK", w.knockback or 0, maxK, GOLD },
			}
			for ri, r in rows do
				local y = 56 + (ri - 1) * 27
				local lab = Instance.new("TextLabel")
				lab.Position = UDim2.fromOffset(RIGHT_X, y); lab.Size = UDim2.fromOffset(92, 15)
				lab.BackgroundTransparency = 1; lab.FontFace = BODYB_FACE; lab.TextSize = 13
				lab.TextXAlignment = Enum.TextXAlignment.Left; lab.TextColor3 = DIMTEXT
				lab.Text = r[1]; lab.Parent = invDetail
				local trk = Instance.new("Frame")
				trk.Position = UDim2.fromOffset(RIGHT_X + 100, y + 2)
				trk.Size = UDim2.fromOffset(RIGHT_W - 100 - 56, 11)
				trk.BackgroundColor3 = darker(TRACK, 0.25); trk.BorderSizePixel = 0; trk.Parent = invDetail
				corner(trk, 2); ledge(trk, TBLACK, 1.8)
				local fil = Instance.new("Frame")
				fil.Size = UDim2.fromScale(math.clamp(r[2] / r[3], 0.03, 1), 1)
				fil.BackgroundColor3 = r[4] or ACCENT; fil.BorderSizePixel = 0; fil.Parent = trk
				corner(fil, 2)
				local num = Instance.new("TextLabel")
				num.AnchorPoint = Vector2.new(1, 0); num.Position = UDim2.fromOffset(RIGHT_X + RIGHT_W, y)
				num.Size = UDim2.fromOffset(50, 15); num.BackgroundTransparency = 1
				num.FontFace = BODYB_FACE; num.TextSize = 13; num.TextXAlignment = Enum.TextXAlignment.Right
				num.TextColor3 = TEXTCOL; num.Text = tostring(math.floor(r[2] * 10 + 0.5) / 10); num.Parent = invDetail
			end
		end
		if ownsGun(id) then
			-- SKINS — click to equip.
			if invData.catalog.skins then
				local cap = Instance.new("TextLabel")
				cap.Position = UDim2.fromOffset(RIGHT_X, 178); cap.Size = UDim2.fromOffset(RIGHT_W, 14)
				cap.BackgroundTransparency = 1; cap.FontFace = BODYB_FACE; cap.TextSize = 11
				cap.TextXAlignment = Enum.TextXAlignment.Left; cap.TextColor3 = DIMTEXT
				cap.Text = "SKINS — CLICK TO EQUIP"; cap.Parent = invDetail
				local strip = Instance.new("Frame")
				strip.Position = UDim2.fromOffset(RIGHT_X, 198); strip.Size = UDim2.fromOffset(RIGHT_W, 58)
				strip.BackgroundTransparency = 1; strip.Parent = invDetail
				local slay = Instance.new("UIListLayout")
				slay.FillDirection = Enum.FillDirection.Horizontal; slay.Padding = UDim.new(0, 8); slay.Parent = strip
				local skinIds = {}
				for sid, sk in invData.catalog.skins do
					if sk.gun == id then
						table.insert(skinIds, sid)
					end
				end
				table.sort(skinIds)
				for _, sid in skinIds do
					local sk = invData.catalog.skins[sid]
					local sOwned = ownsSkin(sid)
					local isOn = sOwned and invData.skins.equipped and invData.skins.equipped[id] == sk.skin
					-- REDONE swatch: uniform dark card for every skin; ring = GREEN when equipped, the
					-- skin's rarity color when owned, near-black when locked; locked art is dimmed with
					-- a padlock. Clicking a locked one explains itself instead of doing nothing.
					local sw = Instance.new("TextButton")
					sw.Size = UDim2.fromOffset(56, 56); sw.Text = ""
					sw.BackgroundColor3 = darker(PANEL2, 0.35)
					sw.BorderSizePixel = 0; sw.AutoButtonColor = true; sw.Parent = strip
					corner(sw, 5)
					ledge(sw, isOn and ACCENT or (sOwned and rarityColor(sk.rarity) or darker(TRACK, 0.3)), isOn and 3 or 2.5)
					local svp
					if sk.image then -- the owner's art for this skin
						svp = Instance.new("ImageLabel")
						svp.BackgroundTransparency = 1
						svp.Image = sk.image
						svp.ScaleType = Enum.ScaleType.Fit
					else -- its model, else the base gun tinted with the skin color
						svp = makeGunViewport(sid, false) or makeGunViewport(sk.gun, false, nil, sk.tint)
					end
					if svp then
						svp.Position = UDim2.fromOffset(3, 3)
						svp.Size = UDim2.new(1, -6, 1, -12)
						if not sOwned then
							svp.ImageColor3 = Color3.fromRGB(55, 55, 55)
						end
						svp.Parent = sw
					end
					if not sOwned then
						local lock = Instance.new("TextLabel")
						lock.AnchorPoint = Vector2.new(0.5, 0.5); lock.Position = UDim2.fromScale(0.5, 0.45)
						lock.Size = UDim2.fromOffset(24, 24); lock.BackgroundTransparency = 1
						lock.FontFace = BODYB_FACE; lock.TextSize = 17; lock.TextColor3 = TEXTCOL
						lock.Text = "🔒"; lock.ZIndex = 4; lock.Parent = sw
					end
					local rbar = Instance.new("Frame")
					rbar.AnchorPoint = Vector2.new(0, 1); rbar.Position = UDim2.new(0, 4, 1, -3)
					rbar.Size = UDim2.new(1, -8, 0, 4)
					rbar.BackgroundColor3 = sOwned and rarityColor(sk.rarity) or darker(TRACK, 0.15)
					rbar.BorderSizePixel = 0; rbar.ZIndex = 3; rbar.Parent = sw
					corner(rbar, 2)
					sw.Activated:Connect(function()
						if sOwned then
							lplay("Equip")
							EquipSkin:FireServer({ weaponId = id, skinId = (not isOn) and sk.skin or false })
						else
							lplay("Error")
							cap.Text = ("LOCKED — %s DROPS FROM CRATES"):format((sk.name or sid):upper())
							cap.TextColor3 = ORANGE
							task.delay(2, function()
								if cap.Parent then
									cap.Text = "SKINS — CLICK TO EQUIP"
									cap.TextColor3 = DIMTEXT
								end
							end)
						end
					end)
				end
			end
			-- EQUIP / UNEQUIP — the page's big CTA.
			local slIdx = (w.slot == "secondary") and 2 or 1
			local equipped = (invData.loadout[slIdx] == id)
			local eqBtn = bigButton(invDetail,
				equipped and "UNEQUIP" or "EQUIP",
				equipped and ORANGE or ACCENT,
				equipped and darker(ORANGE, 0.4) or darker(ACCENT, 0.5),
				Color3.new(1, 1, 1))
			eqBtn.Position = UDim2.fromOffset(RIGHT_X, H - 62); eqBtn.Size = UDim2.fromOffset(RIGHT_W, 54)
			eqBtn.Activated:Connect(function()
				lplay("Equip")
				EquipSlot:FireServer({ slot = slIdx, weaponId = equipped and false or id })
				-- OPTIMISTIC: flip the local loadout NOW so the page updates instantly; the server's
				-- InvSync lands right after and confirms (or corrects) it.
				invData.loadout[slIdx] = (not equipped) and id or nil
				renderActive()
			end)
		else
			local reqLevel = tonumber(w.unlock) or 0
			local lockLbl = Instance.new("TextLabel")
			lockLbl.Position = UDim2.fromOffset(RIGHT_X, 190); lockLbl.Size = UDim2.fromOffset(RIGHT_W, 22)
			lockLbl.BackgroundTransparency = 1; lockLbl.FontFace = BODYB_FACE; lockLbl.TextSize = 17
			lockLbl.TextXAlignment = Enum.TextXAlignment.Left; lockLbl.TextColor3 = DIMTEXT
			lockLbl.Text = "🔒 UNLOCKS AT LEVEL " .. reqLevel; lockLbl.Parent = invDetail
			local note = bigButton(invDetail, ("REACH LV %d TO UNLOCK"):format(reqLevel), LC.GHOSTA, LC.GHOSTB, TEXTCOL)
			note.AutoButtonColor = false
			note.Position = UDim2.fromOffset(RIGHT_X, H - 62); note.Size = UDim2.fromOffset(RIGHT_W, 54)
		end
	elseif kind == "case" then
		local count = invData.cases[id] or 0
		local oddsHead = Instance.new("TextLabel")
		oddsHead.Position = UDim2.fromOffset(RIGHT_X, 44); oddsHead.Size = UDim2.fromOffset(RIGHT_W, 16)
		oddsHead.BackgroundTransparency = 1; oddsHead.FontFace = BODYB_FACE; oddsHead.TextSize = 12
		oddsHead.TextXAlignment = Enum.TextXAlignment.Left; oddsHead.TextColor3 = DIMTEXT
		oddsHead.Text = "WHAT'S INSIDE"; oddsHead.Parent = invDetail
		local list = Instance.new("ScrollingFrame")
		list.Position = UDim2.fromOffset(RIGHT_X, 66); list.Size = UDim2.fromOffset(RIGHT_W, H - 66 - 132)
		list.BackgroundTransparency = 1; list.BorderSizePixel = 0; list.ScrollBarThickness = 4
		list.CanvasSize = UDim2.new(); list.AutomaticCanvasSize = Enum.AutomaticSize.Y; list.Parent = invDetail
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 5); ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Parent = list
		local function lootRow(order, leftText, leftCol, rightText)
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -6, 0, 22); row.BackgroundColor3 = darker(PANEL2, 0.35)
			row.BorderSizePixel = 0; row.LayoutOrder = order; row.Parent = list
			corner(row, 4); ledge(row, TBLACK, 1.5)
			local lt = Instance.new("TextLabel")
			lt.Position = UDim2.fromOffset(9, 0); lt.Size = UDim2.new(1, -74, 1, 0); lt.BackgroundTransparency = 1
			lt.FontFace = BODYB_FACE; lt.TextSize = 13; lt.TextXAlignment = Enum.TextXAlignment.Left
			lt.TextTruncate = Enum.TextTruncate.AtEnd; lt.TextColor3 = leftCol; lt.Text = leftText; lt.Parent = row
			local rt = Instance.new("TextLabel")
			rt.AnchorPoint = Vector2.new(1, 0); rt.Position = UDim2.new(1, -9, 0, 0); rt.Size = UDim2.fromOffset(58, 22)
			rt.BackgroundTransparency = 1; rt.FontFace = BODYB_FACE; rt.TextSize = 13
			rt.TextXAlignment = Enum.TextXAlignment.Right; rt.TextColor3 = DIMTEXT; rt.Text = rightText; rt.Parent = row
		end
		local order = 0
		for _, e in (entry.loot or {}) do
			order += 1
			if e.kind == "gun" then
				local gw = weaponInfo(e.id)
				lootRow(order, "WEAPON — " .. (gw and gw.name or e.id):upper(), GOLD, ("%.1f%%"):format(e.pct or 0))
			elseif e.kind == "guns" then -- the GUN pack: whole gun-rarity rows
				local rname = ((invData.catalog.rarities[e.rarity] or {}).name or e.rarity):upper()
				lootRow(order, "GUNS — " .. rname, rarityColor(e.rarity), ("%.1f%%"):format(e.pct or 0))
			else
				local rname = ((invData.catalog.rarities[e.rarity] or {}).name or e.rarity):upper()
				lootRow(order, "SKINS — " .. rname, rarityColor(e.rarity), ("%.1f%%"):format(e.pct or 0))
			end
		end
		lootRow(order + 1, "DUPLICATE → COINS", DIMTEXT, "—")

		if count > 0 then
			local open1 = paneButton("OPEN 1", GOLD, darker(GOLD, 0.45), Color3.new(1, 1, 1))
			open1.Position = UDim2.fromOffset(RIGHT_X, H - 124); open1.Size = UDim2.fromOffset(RIGHT_W, 54)
			open1.Activated:Connect(function()
				if rolling then return end
				rolling = true
				invPanel:SetAttribute("OpenQueue", 0)
				armRollTimeout()
				OpenCase:FireServer({ caseId = id })
			end)
			if count > 1 then
				local openAll = paneButton(("OPEN ALL (%d)"):format(count), LC.GHOSTA, LC.GHOSTB, TEXTCOL)
				openAll.Position = UDim2.fromOffset(RIGHT_X, H - 60); openAll.Size = UDim2.fromOffset(RIGHT_W, 50)
				openAll.Activated:Connect(function()
					if rolling then return end
					rolling = true
					invPanel:SetAttribute("QueueCase", id)
					invPanel:SetAttribute("OpenQueue", count - 1)
					armRollTimeout()
					OpenCase:FireServer({ caseId = id })
				end)
			end
		else
			local open = paneButton("NONE LEFT", LC.GHOSTA, LC.GHOSTB, TEXTCOL)
			open.AutoButtonColor = false
			open.Position = UDim2.fromOffset(RIGHT_X, H - 60); open.Size = UDim2.fromOffset(RIGHT_W, 54)
		end
	end
end

-- ===== GRID RENDERS ===== each returns the ordered id list so the pane can default to the first item.
local function renderWeaponsGrid()
	-- EVERY gun in the SELECTED category shows (locked ones carry their unlock). Category comes from the
	-- LEVEL/CRATE/EVENT sub-tabs (invGrid attribute); a gun's bucket is WEAPONS[id].source (default level).
	local cat = invGrid:GetAttribute("WeaponCat") or "level"
	local ids = {}
	for id in invData.catalog.weapons do
		if (weaponInfo(id).source or "level") == cat then
			table.insert(ids, id)
		end
	end
	if #ids == 0 then
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.fromOffset(360, 60); msg.BackgroundTransparency = 1; msg.FontFace = BODYB_FACE
		msg.TextSize = 14; msg.TextWrapped = true; msg.TextColor3 = DIMTEXT
		msg.Text = (cat == "crate") and "No crate guns yet — pull them from CRATES in the shop!"
			or (cat == "event") and "No event guns right now — check back during events!"
			or "No guns here yet."
		msg.Parent = invGrid
		return {}
	end
	table.sort(ids, function(a, b) -- LADDER order: the grid IS the unlock road
		local wa, wb = weaponInfo(a), weaponInfo(b)
		if (wa.unlock or 0) ~= (wb.unlock or 0) then
			return (wa.unlock or 0) < (wb.unlock or 0)
		end
		if (wa.tier or 0) ~= (wb.tier or 0) then
			return (wa.tier or 0) < (wb.tier or 0)
		end
		return a < b
	end)
	local nextUnlockId
	for _, id in ids do -- first gun you don't own, in ladder order = the NEXT unlock (the hero card)
		if not ownsGun(id) then
			nextUnlockId = id
			break
		end
	end
	local out = {}
	for i, id in ids do
		local w = weaponInfo(id)
		local owned = ownsGun(id)
		local isEq = invData.loadout[1] == id or invData.loadout[2] == id
		table.insert(out, { kind = "weapon", id = id })
		invCard({
			kind = "weapon", id = id, name = w.name, color = rarityColor(w.rarity),
			order = i, image = w.image,
			nextUp = (id == nextUnlockId) or nil,
			lockLevel = (not owned) and (w.unlock or 0) or nil,
			equipped = isEq or nil,
			chip = ((id == nextUnlockId) and "NEXT UP") or nil,
			subText = owned and ((invData.catalog.rarities[w.rarity] or {}).name or ""):upper() or "",
			locked = not owned,
		})
	end
	return out
end

local function renderCasesGrid()
	-- The INVENTORY screen: JUST the crates you HAVE (only owned ones — no empty placeholders). Guns live
	-- on the WEAPONS screen now (removed here per owner request). Skins live on each gun's info sheet.
	local out = {}
	for _, caseId in invData.catalog.rarityOrder do
		local disp = invData.catalog.cases[caseId]
		local count = invData.cases[caseId] or 0
		if disp and count > 0 then
			table.insert(out, { kind = "case", id = caseId })
			local rname = ((invData.catalog.rarities[caseId] or {}).name or caseId):upper()
			invCard({
				kind = "case", id = caseId, order = #out, image = disp.image,
				name = rname, color = rarityColor(caseId), count = count, subText = "CRATE",
			})
		end
	end
	if #out == 0 then
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.fromOffset(320, 60); msg.BackgroundTransparency = 1; msg.FontFace = BODYB_FACE
		msg.TextSize = 14; msg.TextWrapped = true; msg.TextColor3 = DIMTEXT
		msg.Text = "No crates right now — kill BOSSES in runs (or hit the SHOP stall) to get more!"; msg.Parent = invGrid
	end
	return out
end

-- ===== SCREEN SWITCHING + MASTER RENDER ===== ("weapons" = the GUNS tab, "cases" = the CRATES tab)
local function showTab(id)
	activeTab = id
	selectedInv = nil -- switching screens resets the featured pane
	invTitle.Text = "LOCKER" -- one identity; the GUNS/CRATES tabs carry which screen you're on
	invDetail.Visible = false; invGrid.Visible = true; invHint.Visible = true -- back to GRID mode
	-- repaint the side rail (selected = bright ring + full-brightness photo; others dim)
	local rail = invPanel:FindFirstChild("LockerTabs")
	if rail then
		for _, h in rail:GetChildren() do
			local b = h:IsA("Frame") and h:FindFirstChildWhichIsA("ImageButton")
			if b then
				local on = (b.Name == "Tab_" .. id)
				b.BackgroundColor3 = on and SELBG or CARD
				b.ImageTransparency = on and 0 or 0.35
				local st = b:FindFirstChildOfClass("UIStroke")
				if st then
					st.Color = on and ACCENT or TBLACK
					st.Thickness = on and 3.5 or 2.5
				end
			end
		end
	end
	-- GUNS carries the LEVEL/CRATE/EVENT category row across the top; CRATES doesn't. Content sits
	-- RIGHT of the image rail (68px + gutter).
	local catRow = invPanel:FindFirstChild("WeaponCatRow")
	if catRow then catRow.Visible = (id == "weapons") end
	local gy = (id == "weapons") and (CONTENT_Y + 44) or CONTENT_Y
	invGrid.Position = UDim2.fromOffset(96, gy)
	invGrid.Size = UDim2.fromOffset(PANEL_W - 112, PANEL_H - gy - 16 - 24)
	invRecolor(LC.HEADER_COLORS.guns) -- one LOCKER header color on both tabs
end

-- ===== LOCKER SIDE TABS ===== a LEFT column of IMAGE buttons (dock-style): GUNS (the old Weapons
-- photo) over CRATES (the old Inventory photo). Named children so showTab repaints without new
-- top-level locals (200-local ceiling).
do
	local rail = Instance.new("Frame")
	rail.Name = "LockerTabs"
	rail.Position = UDim2.fromOffset(16, CONTENT_Y)
	rail.Size = UDim2.fromOffset(68, PANEL_H - CONTENT_Y - 16)
	rail.BackgroundTransparency = 1
	rail.Parent = invPanel
	local ll = Instance.new("UIListLayout")
	ll.FillDirection = Enum.FillDirection.Vertical
	ll.Padding = UDim.new(0, 12)
	ll.Parent = rail
	for i, d in { { "weapons", "GUNS", "rbxassetid://102091580612843" },
		{ "cases", "CRATES", "rbxassetid://119161862051444" } } do
		local holder = Instance.new("Frame")
		holder.Name = "Hold_" .. d[1]
		holder.LayoutOrder = i
		holder.Size = UDim2.fromOffset(68, 86)
		holder.BackgroundTransparency = 1
		holder.Parent = rail
		local b = Instance.new("ImageButton")
		b.Name = "Tab_" .. d[1]
		b.Position = UDim2.fromOffset(2, 0)
		b.Size = UDim2.fromOffset(64, 64)
		b.BackgroundColor3 = CARD
		b.AutoButtonColor = true
		b.Image = d[3]
		b.ScaleType = Enum.ScaleType.Crop
		b.Parent = holder
		corner(b, 10)
		ledge(b, TBLACK, 2.5)
		local nm = Instance.new("TextLabel")
		nm.AnchorPoint = Vector2.new(0.5, 1)
		nm.Position = UDim2.new(0.5, 0, 1, 0)
		nm.Size = UDim2.fromOffset(68, 16)
		nm.BackgroundTransparency = 1
		nm.FontFace = BODYB_FACE
		nm.TextSize = 12
		nm.TextColor3 = TEXTCOL
		nm.Text = d[2]
		nm.Parent = holder
		local ns = Instance.new("UIStroke")
		ns.Color = TBLACK
		ns.Thickness = 2
		ns.Parent = nm
		b.Activated:Connect(function()
			if activeTab == d[1] then
				return
			end
			lplay("Click")
			showTab(d[1])
			renderActive()
		end)
	end
	-- INSPECT mode owns the whole panel — the rail ducks out (its BACK button sat right on CRATES).
	invDetail:GetPropertyChangedSignal("Visible"):Connect(function()
		rail.Visible = not invDetail.Visible
	end)
end

renderActive = function()
	if not invData then return end
	local function paintGrid()
		clearChildren(invGrid)
		if activeTab == "weapons" then return renderWeaponsGrid()
		else return renderCasesGrid() end
	end
	local okG, entries = pcall(paintGrid)
	if not okG then
		warn("[LobbyInv] grid render failed: " .. tostring(entries))
		entries = {}
	end
	invData._entries = entries -- the inspect page's ◀ ▶ arrows flip through exactly what the grid shows
	-- Drop a selection that no longer exists. NO auto-select: the panel's default view is the GRID.
	if selectedInv then
		local valid = false
		for _, e in entries do
			if e.kind == selectedInv.kind and e.id == selectedInv.id then
				valid = true
				break
			end
		end
		if not valid then
			selectedInv = nil
		end
	end
	local okD, errD = pcall(renderInvDetail)
	if not okD then
		warn("[LobbyInv] inspect render failed: " .. tostring(errD))
		invDetail.Visible = false -- fail SAFE: never strand the panel in a half-built inspect view
		invGrid.Visible = true
		invHint.Visible = true
	end
end

-- Reusable INVENTORY-CARD FACE (the v3 ticket look) as a plain Frame — so the reel tiles, the reveal,
-- and the multi-open summary all render the SAME card as the inventory/weapons grid. Fills `parent`.
-- opts = { kind, id, name, color, rarityName, locked?, image?, barH?, corner?, ring?, ringW? }
local function cardFace(parent, opts)
	local col = opts.color or Color3.fromRGB(150, 150, 160)
	local barH = opts.barH or 30
	-- Z BASE: this GUI renders under ZIndexBehavior.Global, so a card placed over an OPAQUE background
	-- (the reel window) needs its layers lifted above it — pass opts.z. Default 1 = the inventory look.
	local z = opts.z or 1
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.fromRGB(28, 33, 23)
	f.BorderSizePixel = 0
	f.ClipsDescendants = true
	f.ZIndex = z
	f.Parent = parent
	corner(f, opts.corner or 12)
	ledge(f, opts.ring or TBLACK, opts.ringW or 3)
	local art = Instance.new("Frame") -- white base + rarity-tint vertical gradient (same as invCard)
	art.Size = UDim2.new(1, 0, 1, -(barH + 3))
	art.BackgroundColor3 = Color3.new(1, 1, 1)
	art.BorderSizePixel = 0
	art.ZIndex = z
	art.Parent = f
	local ag = Instance.new("UIGradient")
	if opts.locked then
		ag.Color = ColorSequence.new(Color3.fromRGB(36, 41, 32), Color3.fromRGB(24, 28, 19))
	else
		ag.Color = ColorSequence.new(Color3.fromRGB(32, 38, 26):Lerp(col, 0.16), Color3.fromRGB(25, 30, 20))
	end
	ag.Rotation = 90
	ag.Parent = art
	local sep = Instance.new("Frame") -- 3px black separator over the bar
	sep.AnchorPoint = Vector2.new(0, 1)
	sep.Position = UDim2.new(0, 0, 1, -barH)
	sep.Size = UDim2.new(1, 0, 0, 3)
	sep.BackgroundColor3 = TBLACK
	sep.BorderSizePixel = 0
	sep.ZIndex = z + 2
	sep.Parent = f
	local showed = false
	local vp
	if opts.kind == "skin" then
		local sk = skinInfo(opts.id)
		vp = makeGunViewport(opts.id, false) or (sk and makeGunViewport(sk.gun, false, nil, sk.tint))
	elseif opts.kind == "weapon" then
		vp = makeGunViewport(opts.id, false)
	elseif opts.kind == "case" then
		vp = makeGunViewport(opts.id, false, "CrateDisplay")
	end
	if vp then
		vp.AnchorPoint = Vector2.new(0.5, 0.5)
		vp.Position = UDim2.new(0.5, 0, 0.5, -math.floor((barH + 3) / 2))
		vp.Size = UDim2.new(1, -10, 1, -(barH + 16))
		vp.ZIndex = z + 1
		if opts.locked then
			vp.ImageColor3 = Color3.new(0, 0, 0)
			vp.ImageTransparency = 0.1
		end
		vp.Parent = f
		showed = true
	end
	if not showed and typeof(opts.image) == "string" and opts.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.new(0.5, 0, 0.5, -math.floor((barH + 3) / 2))
		img.Size = UDim2.new(1, -10, 1, -(barH + 16))
		img.BackgroundTransparency = 1
		img.Image = opts.image
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = z + 1
		img.Parent = f
		showed = true
	end
	if not showed then
		local noml = Instance.new("TextLabel")
		noml.AnchorPoint = Vector2.new(0.5, 0.5)
		noml.Position = UDim2.new(0.5, 0, 0.5, -math.floor((barH + 3) / 2))
		noml.Size = UDim2.new(1, -14, 0, 40)
		noml.BackgroundTransparency = 1
		noml.FontFace = TITLE_FACE
		noml.TextSize = 14
		noml.TextWrapped = true
		noml.TextColor3 = opts.locked and DIMTEXT or col
		noml.Text = opts.name or ""
		noml.ZIndex = z + 1
		noml.Parent = f
		local nstr = Instance.new("UIStroke")
		nstr.Color = TBLACK
		nstr.Thickness = 2
		nstr.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		nstr.Parent = noml
	end
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 0, 1, 0)
	bar.Size = UDim2.new(1, 0, 0, barH)
	bar.BackgroundColor3 = opts.locked and Color3.fromRGB(58, 65, 52) or col
	bar.BorderSizePixel = 0
	bar.ZIndex = z + 2
	bar.Parent = f
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromOffset(4, 2)
	nm.Size = UDim2.new(1, -8, 0, barH > 24 and 16 or barH - 4)
	nm.BackgroundTransparency = 1
	nm.FontFace = TITLE_FACE
	nm.TextSize = barH > 24 and 13 or 11
	nm.ZIndex = z + 3
	nm.TextTruncate = Enum.TextTruncate.AtEnd
	nm.TextColor3 = opts.locked and DIMTEXT or Color3.new(1, 1, 1)
	nm.Text = string.upper(opts.name or "")
	nm.Parent = bar
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = TBLACK
	nmStroke.Thickness = 2
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nmStroke.Parent = nm
	if barH > 24 and opts.rarityName then
		local sub = Instance.new("TextLabel")
		sub.Position = UDim2.fromOffset(4, 18)
		sub.Size = UDim2.new(1, -8, 0, 11)
		sub.BackgroundTransparency = 1
		sub.FontFace = BODYB_FACE
		sub.TextSize = 9
		sub.ZIndex = z + 3
		sub.TextColor3 = TBLACK
		sub.TextTransparency = 0.25
		sub.Text = string.upper(opts.rarityName)
		sub.Parent = bar
	end
	return f
end

-- Card opts for a rolled item id (skin or weapon), + the rarity info.
local function itemCardOpts(id, extra)
	local info = skinInfo(id)
	local kind = "skin"
	if not info then
		info = weaponInfo(id)
		kind = "weapon"
	end
	local rname = ""
	if info and invData and invData.catalog.rarities[info.rarity] then
		rname = invData.catalog.rarities[info.rarity].name
	elseif info then
		rname = info.rarity
	end
	local o = {
		kind = kind,
		id = id,
		name = (info and info.name) or id,
		color = info and rarityColor(info.rarity) or Color3.fromRGB(150, 150, 160),
		rarityName = rname,
	}
	if extra then
		for k, v in extra do
			o[k] = v
		end
	end
	return o, info
end

-- ===== CASE-OPENING REEL (CS:GO-style horizontal scroll) =====
local TILE_W, GAP = 100, 8
local STEP = TILE_W + GAP
LC.N_TILES = 50
LC.WIN_INDEX = 44
LC.REEL_W = 540
local REEL_H = 120

-- The reel lives on its OWN top layer (not inside the inventory panel) so BUY & OPEN can spin it from
-- the shop too — it draws over whichever panel launched it.
local reelGui = Instance.new("ScreenGui")
reelGui.Name = "LobbyCaseReel"; reelGui.ResetOnSpawn = false; reelGui.IgnoreGuiInset = true; reelGui.DisplayOrder = 13
reelGui.Parent = playerGui
lattach(reelGui)

local reel = Instance.new("Frame") -- overlay while opening
reel.AnchorPoint = Vector2.new(0.5, 0.5); reel.Position = UDim2.fromScale(0.5, 0.5)
reel.Size = UDim2.fromOffset(760, 480); reel.BackgroundColor3 = darker(PANEL, 0.45); reel.BackgroundTransparency = 0
-- ZINDEX (this GUI is ZIndexBehavior.Global, so children do NOT auto-draw above parents): the reel bg
-- sits at 1; the opaque window at 3; the scrolling tiles at 5+ (cardFace z=5) so they clear the window;
-- fades/title/result 12; ribbon 14/15; pointer 16; summary 18-24; the SKIP/CONTINUE button on top at 26.
reel.BorderSizePixel = 0; reel.Visible = false; reel.ZIndex = 1; reel.Parent = reelGui; corner(reel, 8)
lstuds(reel); ledge(reel, TBLACK, 3); ledge(reel, ACCENT, 1, 0.45)
local reelTitle = Instance.new("TextLabel")
reelTitle.Position = UDim2.new(0, 0, 0, 40); reelTitle.Size = UDim2.new(1, 0, 0, 30); reelTitle.BackgroundTransparency = 1
reelTitle.FontFace = TITLE_FACE; reelTitle.TextSize = 18; reelTitle.TextColor3 = DIMTEXT
reelTitle.Text = "OPENING..."; reelTitle.ZIndex = 12; reelTitle.Parent = reel
local window = Instance.new("Frame")
window.AnchorPoint = Vector2.new(0.5, 0.5); window.Position = UDim2.fromScale(0.5, 0.5); window.Size = UDim2.fromOffset(LC.REEL_W, REEL_H)
window.BackgroundColor3 = darker(PANEL, 0.35); window.BorderSizePixel = 0; window.ClipsDescendants = true; window.ZIndex = 3; window.Parent = reel
corner(window, 10)
local strip = Instance.new("Frame")
strip.Position = UDim2.fromOffset(0, 0); strip.Size = UDim2.fromOffset(LC.N_TILES * STEP, REEL_H); strip.BackgroundTransparency = 1; strip.ZIndex = 4; strip.Parent = window
-- EDGE FADES: tiles dissolve into the panel colour at both ends of the window (classic case feel).
local RV = {} -- reel-effect state, collapsed into one local (200-local ceiling)
RV.reelBG = darker(PANEL, 0.35)
RV.fadeL = Instance.new("Frame")
RV.fadeL.AnchorPoint = Vector2.new(0, 0.5); RV.fadeL.Position = UDim2.new(0, 0, 0.5, 0); RV.fadeL.Size = UDim2.new(0, 96, 1, 0)
RV.fadeL.BackgroundColor3 = RV.reelBG; RV.fadeL.BorderSizePixel = 0; RV.fadeL.ZIndex = 12; RV.fadeL.Parent = window
do
	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	g.Parent = RV.fadeL
end
RV.fadeR = Instance.new("Frame")
RV.fadeR.AnchorPoint = Vector2.new(1, 0.5); RV.fadeR.Position = UDim2.new(1, 0, 0.5, 0); RV.fadeR.Size = UDim2.new(0, 96, 1, 0)
RV.fadeR.BackgroundColor3 = RV.reelBG; RV.fadeR.BorderSizePixel = 0; RV.fadeR.ZIndex = 12; RV.fadeR.Parent = window
do
	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
	g.Parent = RV.fadeR
end
-- GLOWING DOUBLE POINTER (over the window centre, in `reel` so it isn't clipped): line + two diamonds.
local pointer = Instance.new("Frame")
pointer.AnchorPoint = Vector2.new(0.5, 0.5); pointer.Position = UDim2.fromScale(0.5, 0.5); pointer.Size = UDim2.fromOffset(3, REEL_H)
pointer.BackgroundColor3 = ACCENT; pointer.BorderSizePixel = 0; pointer.ZIndex = 16; pointer.Parent = reel
do
	local ps = Instance.new("UIStroke"); ps.Color = ACCENT; ps.Thickness = 3; ps.Transparency = 0.55; ps.Parent = pointer -- soft glow
	for _, top in { true, false } do
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = UDim2.new(0.5, 0, top and 0 or 1, top and -3 or 3)
		d.Size = UDim2.fromOffset(16, 16)
		d.Rotation = 45
		d.BackgroundColor3 = ACCENT
		d.BorderSizePixel = 0
		d.ZIndex = 16
		d.Parent = pointer
		ledge(d, TBLACK, 2)
	end
end
-- RARITY GLOW behind the window centre + a starburst — hidden during the spin, bloom in on RV.reveal.
RV.reveal = Instance.new("Frame")
RV.reveal.AnchorPoint = Vector2.new(0.5, 0.5); RV.reveal.Position = UDim2.fromScale(0.5, 0.5); RV.reveal.Size = UDim2.fromOffset(LC.REEL_W, REEL_H)
RV.reveal.BackgroundTransparency = 1; RV.reveal.ZIndex = 4; RV.reveal.Visible = false; RV.reveal.Parent = reel
RV.burst = Instance.new("Frame")
RV.burst.AnchorPoint = Vector2.new(0.5, 0.5); RV.burst.Position = UDim2.fromScale(0.5, 0.5); RV.burst.Size = UDim2.fromOffset(2, 2)
RV.burst.BackgroundTransparency = 1; RV.burst.ZIndex = 4; RV.burst.Parent = RV.reveal
RV.burstRays = {}
for i = 1, 12 do
	local ray = Instance.new("Frame")
	ray.AnchorPoint = Vector2.new(0.5, 0.5); ray.Position = UDim2.fromScale(0.5, 0.5)
	ray.Size = UDim2.fromOffset(6, 320); ray.Rotation = (i - 1) * 30
	ray.BackgroundColor3 = ACCENT; ray.BackgroundTransparency = 0.75; ray.BorderSizePixel = 0
	ray.ZIndex = 4; ray.Parent = RV.burst
	RV.burstRays[i] = ray
end
RV.ribbon = Instance.new("Frame") -- rarity RV.ribbon banner above the winning card
RV.ribbon.AnchorPoint = Vector2.new(0.5, 1); RV.ribbon.Position = UDim2.new(0.5, 0, 0.5, -(REEL_H / 2) - 6)
RV.ribbon.Size = UDim2.fromOffset(150, 26); RV.ribbon.BackgroundColor3 = ACCENT; RV.ribbon.BorderSizePixel = 0
RV.ribbon.ZIndex = 14; RV.ribbon.Visible = false; RV.ribbon.Parent = reel
corner(RV.ribbon, 6); ledge(RV.ribbon, TBLACK, 2.5)
RV.ribbonLbl = Instance.new("TextLabel")
RV.ribbonLbl.Size = UDim2.fromScale(1, 1); RV.ribbonLbl.BackgroundTransparency = 1; RV.ribbonLbl.FontFace = TITLE_FACE
RV.ribbonLbl.TextSize = 15; RV.ribbonLbl.TextColor3 = Color3.new(1, 1, 1); RV.ribbonLbl.ZIndex = 15; RV.ribbonLbl.Text = ""; RV.ribbonLbl.Parent = RV.ribbon
do
	local rs = Instance.new("UIStroke"); rs.Color = TBLACK; rs.Thickness = 2.5
	rs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; rs.Parent = RV.ribbonLbl
end
local resultLabel = Instance.new("TextLabel")
resultLabel.AnchorPoint = Vector2.new(0.5, 0); resultLabel.Position = UDim2.new(0.5, 0, 0.5, REEL_H / 2 + 16); resultLabel.Size = UDim2.fromOffset(560, 30)
resultLabel.BackgroundTransparency = 1; resultLabel.FontFace = TITLE_FACE; resultLabel.TextSize = 26; resultLabel.Text = ""
resultLabel.TextColor3 = TEXTCOL; resultLabel.ZIndex = 12; resultLabel.Parent = reel
local reelBtn = Instance.new("TextButton") -- doubles as Skip (while rolling) and Continue (after)
reelBtn.AnchorPoint = Vector2.new(0.5, 1); reelBtn.Position = UDim2.new(0.5, 0, 1, -34); reelBtn.Size = UDim2.fromOffset(200, 44)
reelBtn.BackgroundColor3 = CARD; reelBtn.FontFace = BODYB_FACE; reelBtn.TextSize = 18; reelBtn.TextColor3 = TEXTCOL
-- ZIndex 26: its lbevel Face/Label land at 27/28 — clearly above the summary (18-24) and
-- window (6) in every state (SKIP / CONTINUE / CLAIM), so the button never sits under another layer.
reelBtn.Text = "SKIP"; reelBtn.ZIndex = 26; reelBtn.Parent = reel; corner(reelBtn, 8); ledge(reelBtn, TBLACK, 2.5); lbevel(reelBtn)

-- MULTI-OPEN SUMMARY: a grid of the SAME cards for x3/x10 (so it isn't N slow reveals). Hidden by default.
RV.summary = Instance.new("Frame")
RV.summary.Size = UDim2.fromScale(1, 1); RV.summary.BackgroundTransparency = 1; RV.summary.ZIndex = 18
RV.summary.Visible = false; RV.summary.Parent = reel
RV.summaryTitle = Instance.new("TextLabel")
RV.summaryTitle.Position = UDim2.fromOffset(0, 22); RV.summaryTitle.Size = UDim2.new(1, 0, 0, 30)
RV.summaryTitle.BackgroundTransparency = 1; RV.summaryTitle.FontFace = TITLE_FACE; RV.summaryTitle.TextSize = 22
RV.summaryTitle.TextColor3 = GOLD; RV.summaryTitle.Text = ""; RV.summaryTitle.ZIndex = 19; RV.summaryTitle.Parent = RV.summary
do
	local st = Instance.new("UIStroke"); st.Color = TBLACK; st.Thickness = 2.5
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; st.Parent = RV.summaryTitle
end
RV.summaryGrid = Instance.new("Frame")
RV.summaryGrid.AnchorPoint = Vector2.new(0.5, 0); RV.summaryGrid.Position = UDim2.new(0.5, 0, 0, 64)
RV.summaryGrid.Size = UDim2.fromOffset(680, 300); RV.summaryGrid.BackgroundTransparency = 1; RV.summaryGrid.ZIndex = 19; RV.summaryGrid.Parent = RV.summary
do
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(126, 118); gl.CellPadding = UDim2.fromOffset(8, 8)
	gl.HorizontalAlignment = Enum.HorizontalAlignment.Center; gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = RV.summaryGrid
end
RV.summaryFoot = Instance.new("TextLabel")
RV.summaryFoot.AnchorPoint = Vector2.new(0.5, 1); RV.summaryFoot.Position = UDim2.new(0.5, 0, 1, -92)
RV.summaryFoot.Size = UDim2.new(1, 0, 0, 24); RV.summaryFoot.BackgroundTransparency = 1; RV.summaryFoot.FontFace = BODYB_FACE
RV.summaryFoot.TextSize = 16; RV.summaryFoot.TextColor3 = ACCENT; RV.summaryFoot.Text = ""; RV.summaryFoot.ZIndex = 19; RV.summaryFoot.Parent = RV.summary

local activeTween = nil
local finishReel = nil
RV.reelBatch = {} -- accumulates every pull of a multi-open, drives the RV.summary grid
RV.reelFF = false -- fast-forwarding the rest of a batch (no reels for pulls 2..N)
RV.reelPackName = "PACK"

playReel = function(caseId, wonId, res)
	local disp = invData.catalog.cases[caseId]
	local poolIds = disp and disp.poolIds or { wonId }
	for _, c in strip:GetChildren() do c:Destroy() end
	for i = 1, LC.N_TILES do
		local id = (i == LC.WIN_INDEX) and wonId or poolIds[math.random(1, #poolIds)]
		local holder = Instance.new("Frame") -- each reel tile is the SAME inventory card, via cardFace
		holder.Position = UDim2.fromOffset((i - 1) * STEP, 8)
		holder.Size = UDim2.fromOffset(TILE_W, REEL_H - 16)
		holder.BackgroundTransparency = 1
		holder.ZIndex = 5
		holder.Parent = strip
		cardFace(holder, itemCardOpts(id, { barH = 24, corner = 10, z = 5 })) -- z=5: clears the window bg (3)
	end

	RV.summary.Visible = false
	RV.reveal.Visible = false
	RV.ribbon.Visible = false
	window.Visible = true
	pointer.Visible = true
	reelTitle.Text = "OPENING " .. (disp and disp.name or "CASE"):upper()
	reelTitle.Visible = true
	resultLabel.Text = ""
	resultLabel.Visible = true
	reelBtn.Text = "SKIP"; reelBtn.BackgroundColor3 = CARD; reelBtn.TextColor3 = TEXTCOL
	reel.Visible = true

	local jitter = math.random(-10, 10) + (TILE_W * 0.5) * (math.random() - 0.5)
	local target = math.floor(LC.REEL_W / 2 - ((LC.WIN_INDEX - 1) * STEP + TILE_W / 2) + jitter)
	strip.Position = UDim2.fromOffset(0, 0)

	local revealed = false
	finishReel = function()
		if revealed then return end
		revealed = true
		if activeTween then activeTween:Cancel() end
		strip.Position = UDim2.fromOffset(target, 0)
		local info = skinInfo(wonId) or weaponInfo(wonId)
		local col = info and rarityColor(info.rarity) or TEXTCOL
		local wonName = info and info.name or wonId
		local r = info and info.rarity or "common"
		local rname = (info and invData.catalog.rarities[info.rarity] and invData.catalog.rarities[info.rarity].name) or r
		local hi = (r == "legendary" or r == "divine" or r == "mythic" or r == "epic")
		-- EFFECTS: rarity glow RV.burst + starburst behind the winning card, a rarity RV.ribbon above it, and
		-- the result line below. The RV.burst blooms bigger/brighter the rarer the pull.
		for _, ray in RV.burstRays do
			ray.BackgroundColor3 = col
			ray.BackgroundTransparency = 1
			ray.Size = UDim2.fromOffset(6, 40)
		end
		RV.reveal.Visible = true
		local bloom = hi and 1 or 0.55
		for _, ray in RV.burstRays do
			TweenService:Create(ray, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = hi and 0.7 or 0.86, Size = UDim2.fromOffset(6, 340 * bloom) }):Play()
		end
		TweenService:Create(RV.burst, TweenInfo.new(9, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1),
			{ Rotation = 360 }):Play() -- slow shimmer
		RV.ribbon.BackgroundColor3 = col
		RV.ribbonLbl.Text = string.upper(rname)
		RV.ribbon.Visible = true
		RV.ribbon.Size = UDim2.fromOffset(60, 26)
		TweenService:Create(RV.ribbon, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromOffset(150, 26) }):Play()
		if res.unlocked then
			resultLabel.TextColor3 = col
			resultLabel.Text = ("★ NEW — %s UNLOCKED!"):format(string.upper(wonName))
		else
			resultLabel.TextColor3 = Color3.fromRGB(255, 213, 122)
			resultLabel.Text = ("DUPLICATE %s → 🪙 %d"):format(string.upper(wonName), tonumber(res.coins) or 0)
		end
		reelBtn.Text = "CONTINUE"; reelBtn.BackgroundColor3 = SELBG; reelBtn.TextColor3 = TEXTCOL
		-- a little screen-punch on the reel, bigger for rarer pulls
		local kick = hi and 6 or 3
		TweenService:Create(reel, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, math.random(-kick, kick), 0.5, math.random(-kick, kick)) }):Play()
		task.delay(0.08, function()
			TweenService:Create(reel, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Position = UDim2.fromScale(0.5, 0.5) }):Play()
		end)
		if res.unlocked and (r == "legendary" or r == "divine") or r == "divine" then
			lplay("RevealJackpot")
		elseif r == "epic" or r == "legendary" then
			lplay("RevealHigh")
		else
			lplay("RevealLow")
		end
	end

	activeTween = TweenService:Create(strip, TweenInfo.new(4.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(target, 0) })
	activeTween.Completed:Connect(function()
		finishReel()
	end)
	activeTween:Play()

	-- Tick as tiles sweep past the pointer (self-disconnects at RV.reveal).
	local lastTickIdx = math.floor(-strip.Position.X.Offset / STEP)
	local tickConn
	tickConn = RunService.RenderStepped:Connect(function()
		if revealed then
			tickConn:Disconnect()
			return
		end
		local idx = math.floor(-strip.Position.X.Offset / STEP)
		if idx ~= lastTickIdx then
			lastTickIdx = idx
			lplay("ReelTick", 0.95 + math.random() * 0.1)
		end
	end)
end

-- Build the multi-open RV.summary grid (same cards) once a batch finishes fast-forwarding.
local function showSummary()
	window.Visible = false
	pointer.Visible = false
	RV.reveal.Visible = false
	RV.ribbon.Visible = false
	reelTitle.Visible = false
	resultLabel.Visible = false
	for _, c in RV.summaryGrid:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local newCount, dupeCoins = 0, 0
	for i, e in ipairs(RV.reelBatch) do
		if e.unlocked then
			newCount += 1
		else
			dupeCoins += tonumber(e.coins) or 0
		end
		local holder = Instance.new("Frame")
		holder.LayoutOrder = i
		holder.BackgroundTransparency = 1
		holder.Parent = RV.summaryGrid
		cardFace(holder, itemCardOpts(e.id, { barH = 22, corner = 10, z = 19 })) -- z=19: above the summary bg (18)
		if e.unlocked then
			local nb = Instance.new("TextLabel")
			nb.Position = UDim2.fromOffset(5, 5); nb.Size = UDim2.fromOffset(36, 16)
			nb.BackgroundColor3 = Color3.fromRGB(224, 28, 14); nb.BorderSizePixel = 0
			nb.FontFace = TITLE_FACE; nb.TextSize = 10; nb.TextColor3 = Color3.new(1, 1, 1)
			nb.Text = "NEW"; nb.ZIndex = 24; nb.Parent = holder
			corner(nb, 4); ledge(nb, Color3.new(1, 1, 1), 1.5, 0.4)
		end
	end
	RV.summaryTitle.Text = ("YOU OPENED %d× %s"):format(#RV.reelBatch, string.upper(RV.reelPackName))
	RV.summaryFoot.Text = ("%d NEW · %d DUPES → 🪙 %d COINS"):format(newCount, #RV.reelBatch - newCount, dupeCoins)
	RV.summary.Visible = true
	reelBtn.Text = "CLAIM"; reelBtn.BackgroundColor3 = GOLD; reelBtn.TextColor3 = Color3.new(1, 1, 1)
	lplay("RevealHigh")
end

reelBtn.Activated:Connect(function()
	if not finishReel then return end
	if reelBtn.Text == "SKIP" then
		finishReel() -- snap to the result
		return
	end
	-- CONTINUE / CLAIM.
	if RV.summary.Visible then -- end of a multi-open: close out
		reel.Visible = false
		rolling = false
		RV.reelFF = false
		renderActive()
		return
	end
	local q = invPanel:GetAttribute("OpenQueue") or 0
	local qc = invPanel:GetAttribute("QueueCase")
	if q > 0 and typeof(qc) == "string" and invData and (invData.cases[qc] or 0) > 0 then
		-- FAST-FORWARD the rest of the batch straight into the RV.summary grid (no more slow reels).
		RV.reelFF = true
		invPanel:SetAttribute("OpenQueue", q - 1)
		RV.reveal.Visible = false
		RV.ribbon.Visible = false
		reelTitle.Text = "OPENING THE REST..."
		armRollTimeout()
		OpenCase:FireServer({ caseId = qc }) -- `rolling` stays true until the batch ends
		return
	end
	-- single open finished
	reel.Visible = false
	rolling = false
	renderActive()
end)

-- Watchdog: `rolling` is set the moment an open is requested; if no CaseResult ever arrives (server
-- rejected silently, remote lost), unlock the UI instead of soft-locking the panels until rejoin.
armRollTimeout = function()
	rollToken += 1
	local myToken = rollToken
	task.delay(6, function()
		-- fires if a reply is lost while chaining (reel hidden) OR fast-forwarding (reel up, reelFF set)
		if rolling and myToken == rollToken and (not reel.Visible or RV.reelFF) then
			RV.reelFF = false
			rolling = false
			reel.Visible = false
			renderActive()
		end
	end)
end

-- ===== OPEN / CLOSE + REMOTE WIRING =====
local function openScreen(tab)
	-- Same screen while open = toggle closed (except mid case-open); other screen = switch in place.
	if invPanel.Visible and activeTab == tab then
		if rolling then return end
		hideTip()
		lplay("Close")
		invPanel.Visible = false
		uiFocusClose()
		return
	end
	if not invPanel.Visible then uiFocusOpen() end
	lplay("Open")
	InvRequest:FireServer()
	showTab(tab)
	renderActive()
	invPanel.Visible = true
end
gunsBtn.Activated:Connect(function()
	openScreen("weapons")
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.B then
		openScreen("weapons")
	end
end)
invClose.Activated:Connect(function()
	if rolling then return end -- don't close mid-open
	hideTip()
	lplay("Close")
	if invPanel.Visible then uiFocusClose() end
	invPanel.Visible = false
end)

InvSync.OnClientEvent:Connect(function(snap)
	if typeof(snap) ~= "table" then return end
	invData = snap
	-- Bump a version attribute so the XP bar recomputes its "next unlock" once the catalog is available.
	localPlayer:SetAttribute("InvVersion", (localPlayer:GetAttribute("InvVersion") or 0) + 1)
	-- Dock badge: unopened crate count on the Inventory button.
	local crates = 0
	if typeof(snap.cases) == "table" then
		for _, n in snap.cases do
			crates += tonumber(n) or 0
		end
	end
	dockBtns.weaponsBadge.Visible = crates > 0
	dockBtns.weaponsBadge.N.Text = crates > 99 and "99+" or tostring(crates)
	if invPanel.Visible then
		renderActive()
	end
end)

CaseResult.OnClientEvent:Connect(function(res)
	rollToken += 1 -- a reply arrived; disarm the watchdog
	if typeof(res) ~= "table" or res.failed or not res.caseId then
		lplay("Error")
		invPanel:SetAttribute("OpenQueue", 0)
		RV.reelFF = false
		rolling = false
		if invPanel.Visible then
			renderActive() -- restore any "..." button state
		end
		return
	end
	if invPanel.Visible then
		showTab("cases") -- make sure we're on the cases view behind the reel
		selectedInv = { kind = "case", id = res.caseId } -- CONTINUE lands back on this crate's page
	end
	RV.reelPackName = (invData and invData.catalog.cases[res.caseId] and invData.catalog.cases[res.caseId].name) or "PACK"
	-- NEW: server-initiated multi-opens (the Robux pack) ride in with a `chain` count — queue the rest.
	if tonumber(res.chain) and res.chain > 0 then
		invPanel:SetAttribute("QueueCase", res.caseId)
		invPanel:SetAttribute("OpenQueue", res.chain)
	end
	if RV.reelFF then
		-- fast-forwarding pulls 2..N of a batch: accumulate silently, no reel; resolve into the RV.summary
		table.insert(RV.reelBatch, { id = res.wonId, unlocked = res.unlocked, coins = res.coins })
		local q = invPanel:GetAttribute("OpenQueue") or 0
		local qc = invPanel:GetAttribute("QueueCase")
		if q > 0 and typeof(qc) == "string" and invData and (invData.cases[qc] or 0) > 0 then
			invPanel:SetAttribute("OpenQueue", q - 1)
			armRollTimeout()
			OpenCase:FireServer({ caseId = qc })
		else
			RV.reelFF = false
			showSummary()
		end
		return
	end
	-- FIRST pull of a (possibly multi-) open: start a fresh batch and play the full reel.
	RV.reelBatch = { { id = res.wonId, unlocked = res.unlocked, coins = res.coins } }
	rolling = true -- a reel is on screen (Robux opens arrive without a client-side request)
	playReel(res.caseId, res.wonId, res)
end)

-- =====================================================================================================
-- ===== EXCLUSIVE SHOP ===== the approved S3 DOCK-DRIVEN build (per the final mock):
--   · NO tabs anywhere — the dock's Shop/Daily/Pass/Codes buttons ARE the navigation, each deep-links
--     straight to its page; the header retitles per page (the old left tab rail is deleted)
--   · FEATURED — pull ticker, the pack (band w/ LIMITED chip + GONE IN, big tier cards, gold footer
--     with the three ×N Robux pills + ONE gold GIFT button), labeled pity meter
--   · DAILY — the wheel: 8 reward chips in a ring, light-chaser spin, one FREE spin/day + Robux
--     re-spins, streak flame chip (the streak fattens the jackpot slice server-side)
--   · PASSES & COINS — the 3 gamepasses, 4 coin bundles, one-time STARTER PACK
--   · CODES — the redeem bar
-- Everything scoped in this do-block (the 200-local ceiling).
-- =====================================================================================================
do
	local ShopSync   = remotes:WaitForChild("ShopSync")
	local ShopClose  = remotes:WaitForChild("ShopClose")
	local ShopRedeem = remotes:WaitForChild("ShopRedeem")
	local ShopGift   = remotes:WaitForChild("ShopGift")
	local PackGranted = remotes:WaitForChild("PackGranted")
	local WheelSpin  = remotes:WaitForChild("WheelSpin")
	local ShopTicker = remotes:WaitForChild("ShopTicker")
	local MarketplaceService = game:GetService("MarketplaceService")

	-- ===== TUNABLES =====
	-- (the shop button moved into the DOCK — its image lives in DOCK_ICONS.shop up top)
	local SHOP_GOLD = Color3.fromRGB(240, 165, 10)
	-- CHANGED (S3): no tab buttons anymore — just the page ids + what the header says on each.
	-- CHANGED: no more "passes" tab — Passes & Coins now scroll UNDER the pack on the featured page.
	-- Wheel + Codes stay their own dock-opened pages.
	local TABS = {
		order = { "featured", "daily", "codes" },
		titles = { featured = "EXCLUSIVE SHOP", daily = "DAILY WHEEL", codes = "CODES" },
	}
	-- Paste each gamepass id when you create it (Creator Hub → Passes). 0 = the card answers SOON.
	local GAMEPASSES = {
		{ name = "2x COINS", sub = "FOREVER, EVERY RUN", id = 1906963090, emblem = "coins", color = Color3.fromRGB(58, 134, 184), color2 = Color3.fromRGB(27, 74, 104) },
		{ name = "2x XP", sub = "LEVEL TWICE AS FAST", id = 1907131130, emblem = "xp", color = Color3.fromRGB(217, 166, 22), color2 = Color3.fromRGB(138, 100, 8) },
		{ name = "VIP", sub = "VIP TAG + A FREE RARE CRATE DAILY", id = 1906069123, emblem = "vip", color = Color3.fromRGB(217, 122, 46), color2 = Color3.fromRGB(138, 68, 16) },
	}
	local BODY_W, BODY_H = 660, 400 -- (trimmed: the featured tab was leaving a dead band at the bottom)

	local S = { data = nil, deadline = 0, tab = "featured", tickerQ = {}, spinning = false } -- one local holds it all

	-- Absolute vertical gradient over a white base (UIGradient multiplies; white = exact colors).
	local function absGrad(o, c0, c1, mid)
		o.BackgroundColor3 = Color3.new(1, 1, 1)
		local g = Instance.new("UIGradient")
		if mid then
			g.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, c0),
				ColorSequenceKeypoint.new(0.55, mid),
				ColorSequenceKeypoint.new(1, c1),
			})
		else
			g.Color = ColorSequence.new(c0, c1)
		end
		g.Rotation = 90
		g.Parent = o
		return g
	end

	-- White sticker text with the fat dark outline.
	local function sticker(parent, textStr, textSize, colr)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = TITLE_FACE
		l.TextSize = textSize
		l.TextColor3 = colr or Color3.new(1, 1, 1)
		l.ZIndex = 4
		local st = Instance.new("UIStroke")
		st.Color = TBLACK
		st.Thickness = math.clamp(textSize / 8, 2, 3.5)
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Parent = l
		l.Text = textStr
		l.Parent = parent
		return l
	end

	-- Drawn Robux mark: white tilted rounded square with a dark center hole.
	local function robuxGem(parent, d)
		local gem = Instance.new("Frame")
		gem.Size = UDim2.fromOffset(d, d)
		gem.Rotation = 45
		gem.BackgroundColor3 = Color3.fromRGB(246, 246, 246)
		gem.BorderSizePixel = 0
		gem.ZIndex = 6
		gem.Parent = parent
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 3)
		c.Parent = gem
		ledge(gem, TBLACK, 2)
		local hole = Instance.new("Frame")
		hole.AnchorPoint = Vector2.new(0.5, 0.5)
		hole.Position = UDim2.fromScale(0.5, 0.5)
		hole.Size = UDim2.fromScale(0.36, 0.36)
		hole.BackgroundColor3 = Color3.fromRGB(60, 66, 48)
		hole.BorderSizePixel = 0
		hole.ZIndex = 7
		hole.Parent = gem
		local hc = Instance.new("UICorner")
		hc.CornerRadius = UDim.new(0, 1)
		hc.Parent = hole
		return gem
	end

	S.gui = Instance.new("ScreenGui")
	S.gui.Name = "LobbyShop"
	S.gui.ResetOnSpawn = false
	S.gui.IgnoreGuiInset = true
	S.gui.DisplayOrder = 12 -- above the inventory (11), below the reel (13)
	S.gui.Parent = playerGui
	lattach(S.gui)

	S.root, S.panel, S.title, S.x = chromePanel(S.gui, BODY_W, BODY_H, SHOP_GOLD, "EXCLUSIVE SHOP")
	S.root.Size += UDim2.fromOffset(0, 32) -- room for the shared status line under the body

	S.msg = sticker(S.root, "", 14) -- verdicts: codes / gift confirms / soon notes
	S.msg.Position = UDim2.new(0, 22, 0, 50 + BODY_H + 8)
	S.msg.Size = UDim2.fromOffset(BODY_W, 22)
	S.say = function(textStr, colr)
		S.msg.Text = textStr
		S.msg.TextColor3 = colr or TEXTCOL
	end

	-- ===== THE FOUR TAB PAGES ===== one frame each fills the body; setTab flips Visible.
	S.page = {}
	for _, id in TABS.order do
		local pg = Instance.new("Frame")
		pg.Name = "Page_" .. id
		pg.Position = UDim2.fromOffset(14, 12)
		pg.Size = UDim2.new(1, -28, 1, -24)
		pg.BackgroundTransparency = 1
		pg.Visible = (id == "featured")
		pg.Parent = S.panel
		S.page[id] = pg
	end

	-- FEATURED is a vertical SCROLL now: the fixed bundle pack rides at the top and Passes & Coins scroll
	-- below it. The dock's Shop/Daily/Codes buttons are the only navigation (no in-shop tab rail).
	S.featScroll = Instance.new("ScrollingFrame")
	S.featScroll.Size = UDim2.fromScale(1, 1)
	S.featScroll.BackgroundTransparency = 1
	S.featScroll.BorderSizePixel = 0
	S.featScroll.ScrollBarThickness = 8
	S.featScroll.ScrollBarImageColor3 = Color3.fromRGB(180, 186, 160)
	S.featScroll.ScrollBarImageTransparency = 0.2
	S.featScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	S.featScroll.CanvasSize = UDim2.fromOffset(0, 712) -- pack (~344) + the passes block (~360)
	-- ZIndexBehavior.Global: the scrollbar draws at the frame's OWN ZIndex, so it must out-rank the pack
	-- (2) + its band/foot/buy (3-5) + the passes cards (6) or it gets painted over and vanishes.
	S.featScroll.ZIndex = 8
	S.featScroll.Parent = S.page.featured
	-- Page_passes still exists (the passes builder fills it) but now lives INSIDE the featured scroll,
	-- below the pack, always visible — NOT a nav page (setTab skips it).
	S.page.passes = Instance.new("Frame")
	S.page.passes.Name = "Page_passes"
	S.page.passes.Position = UDim2.fromOffset(0, 360)
	S.page.passes.Size = UDim2.fromOffset(628, 344)
	S.page.passes.BackgroundTransparency = 1
	S.page.passes.Parent = S.featScroll

	S.setTab = function(id)
		S.tab = id
		for k, pg in S.page do
			if k ~= "passes" then -- passes isn't a nav page; it lives in the featured scroll
				pg.Visible = (k == id)
			end
		end
		S.title.Text = TABS.titles[id] or S.title.Text
	end

	-- =====================================================================================================
	-- ===== TAB 1: FEATURED ===== ticker → the pack → pity bar
	-- =====================================================================================================
	-- The live pull ticker: HIDDEN until a real legendary+ pull happens (no placeholder sentences).
	-- While hidden the pack slides up to fill the row; a pull slides everything into place.
	S.ticker = Instance.new("TextLabel")
	S.ticker.Size = UDim2.new(1, 0, 0, 24)
	S.ticker.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
	S.ticker.BorderSizePixel = 0
	S.ticker.FontFace = BODYB_FACE
	S.ticker.TextSize = 12
	S.ticker.TextColor3 = Color3.fromRGB(255, 210, 62)
	S.ticker.TextTruncate = Enum.TextTruncate.AtEnd
	S.ticker.Text = ""
	S.ticker.Visible = false
	S.ticker.Parent = S.featScroll
	corner(S.ticker, 4)
	ledge(S.ticker, TBLACK, 2.5)
	S.layoutFeatured = function() -- the pack rides up when there's no ticker row
		S.pack.Position = UDim2.fromOffset(0, S.ticker.Visible and 32 or 4) -- x=0: aligns with ticker + passes
	end

	S.pack = Instance.new("Frame")
	S.pack.Position = UDim2.fromOffset(0, 32)
	S.pack.Size = UDim2.fromOffset(628, 304)
	S.pack.BorderSizePixel = 0
	S.pack.ClipsDescendants = true
	S.pack.ZIndex = 2
	S.pack.Parent = S.featScroll
	corner(S.pack, 6)
	absGrad(S.pack, Color3.fromRGB(32, 24, 8), Color3.fromRGB(14, 11, 4))
	ledge(S.pack, ORANGE, 3.5)

	do -- gold TITLE BAND across the pack's top — carries the GONE IN timer chip + a light sweep
		local band = Instance.new("Frame")
		band.Size = UDim2.new(1, 0, 0, 34)
		band.BorderSizePixel = 0
		band.ClipsDescendants = true
		band.ZIndex = 3
		band.Parent = S.pack
		absGrad(band, Color3.fromRGB(255, 210, 62), Color3.fromRGB(212, 138, 0))
		local seam = Instance.new("Frame")
		seam.AnchorPoint = Vector2.new(0, 1)
		seam.Position = UDim2.new(0, 0, 1, 0)
		seam.Size = UDim2.new(1, 0, 0, 2)
		seam.BackgroundColor3 = TBLACK
		seam.BorderSizePixel = 0
		seam.ZIndex = 4
		seam.Parent = band
		local sheen = Instance.new("Frame") -- gradient streak (rotated frames escape clipping)
		sheen.Size = UDim2.fromScale(1, 1)
		sheen.BackgroundColor3 = Color3.new(1, 1, 1)
		sheen.BorderSizePixel = 0
		sheen.ZIndex = 3
		sheen.Parent = band
		local sg = Instance.new("UIGradient")
		sg.Rotation = 20
		sg.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.44, 0.78),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		sg.Parent = sheen
		S.packTitle = sticker(band, "PACK", 20)
		S.packTitle.Position = UDim2.fromOffset(14, 0)
		S.packTitle.Size = UDim2.fromOffset(280, 32)
		S.packTitle.TextXAlignment = Enum.TextXAlignment.Left
		S.packTitle.AutomaticSize = Enum.AutomaticSize.X
		local lim = Instance.new("Frame") -- NEW: the LIMITED chip riding next to the title
		lim.AnchorPoint = Vector2.new(0, 0.5)
		lim.Position = UDim2.fromOffset(14, 16)
		lim.Size = UDim2.fromOffset(74, 20)
		lim.BorderSizePixel = 0
		lim.ZIndex = 5
		lim.Parent = band
		local lc = Instance.new("UICorner")
		lc.CornerRadius = UDim.new(1, 0)
		lc.Parent = lim
		absGrad(lim, Color3.fromRGB(255, 138, 92), Color3.fromRGB(180, 30, 14))
		ledge(lim, TBLACK, 2)
		local ll2 = sticker(lim, "LIMITED", 11)
		ll2.Size = UDim2.fromScale(1, 1)
		ll2.ZIndex = 6
		S.packTitle:GetPropertyChangedSignal("TextBounds"):Connect(function()
			lim.Position = UDim2.fromOffset(14 + S.packTitle.TextBounds.X + 12, 16)
		end)
		local gl = Instance.new("TextLabel") -- "GONE IN" in the band's own dark red, not sticker white
		gl.AnchorPoint = Vector2.new(1, 0.5)
		gl.Position = UDim2.new(1, -96, 0.5, -1)
		gl.Size = UDim2.fromOffset(70, 16)
		gl.BackgroundTransparency = 1
		gl.FontFace = BODYB_FACE
		gl.TextSize = 12
		gl.TextColor3 = Color3.fromRGB(122, 26, 16)
		gl.TextXAlignment = Enum.TextXAlignment.Right
		gl.Text = "GONE IN"
		gl.ZIndex = 5
		gl.Parent = band
		local chip = Instance.new("Frame") -- the dark timer chip
		chip.AnchorPoint = Vector2.new(1, 0.5)
		chip.Position = UDim2.new(1, -10, 0.5, -1)
		chip.Size = UDim2.fromOffset(80, 24)
		chip.BackgroundColor3 = Color3.fromRGB(10, 11, 8)
		chip.BorderSizePixel = 0
		chip.ZIndex = 5
		chip.Parent = band
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 6)
		cc.Parent = chip
		S.timer = Instance.new("TextLabel")
		S.timer.Size = UDim2.fromScale(1, 1)
		S.timer.BackgroundTransparency = 1
		S.timer.FontFace = TITLE_FACE
		S.timer.TextSize = 15
		S.timer.TextColor3 = Color3.fromRGB(255, 90, 46)
		S.timer.Text = "--:--"
		S.timer.ZIndex = 6
		S.timer.Parent = chip
	end

	S.items = Instance.new("Frame") -- rebuilt every render: the four tier CARDS (your gun in each skin)
	S.items.Position = UDim2.fromOffset(0, 34)
	S.items.Size = UDim2.new(1, 0, 0, 198)
	S.items.BackgroundTransparency = 1
	S.items.ZIndex = 2
	S.items.Parent = S.pack

	S.foot = Instance.new("Frame") -- gold footer: GONE IN + the three BIG Open stacks
	S.foot.AnchorPoint = Vector2.new(0, 1)
	S.foot.Position = UDim2.new(0, 0, 1, 0)
	S.foot.Size = UDim2.new(1, 0, 0, 72)
	S.foot.BorderSizePixel = 0
	S.foot.ZIndex = 3
	S.foot.Parent = S.pack
	absGrad(S.foot, Color3.fromRGB(224, 165, 46), Color3.fromRGB(150, 102, 14))
	do
		local seam = Instance.new("Frame")
		seam.Size = UDim2.new(1, 0, 0, 3)
		seam.BackgroundColor3 = TBLACK
		seam.BorderSizePixel = 0
		seam.ZIndex = 4
		seam.Parent = S.foot
		S.footCap = Instance.new("TextLabel") -- says WHAT you're buying + which gun is modeling
		S.footCap.Position = UDim2.fromOffset(14, 0)
		S.footCap.Size = UDim2.fromOffset(346, 72)
		S.footCap.BackgroundTransparency = 1
		S.footCap.FontFace = BODYB_FACE
		S.footCap.TextSize = 11
		S.footCap.TextColor3 = Color3.fromRGB(255, 237, 189)
		S.footCap.TextWrapped = true
		S.footCap.TextXAlignment = Enum.TextXAlignment.Left
		S.footCap.ZIndex = 4
		S.footCap.TextXAlignment = Enum.TextXAlignment.Left
		S.footCap.Text = "EVERYTHING IN ONE BUY · A GUN YOU ALREADY OWN PAYS OUT AS COINS"
		S.footCap.Parent = S.foot
		local capS = Instance.new("UIStroke")
		capS.Color = TBLACK
		capS.Thickness = 1.5
		capS.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		capS.Parent = S.footCap
	end

	-- ONE fixed-bundle BUY button (Robux) — the pack is not a gacha, this grants everything at once.
	S.buyPack = Instance.new("TextButton")
	S.buyPack.AnchorPoint = Vector2.new(1, 0.5)
	S.buyPack.Position = UDim2.new(1, -14, 0.5, 0)
	S.buyPack.Size = UDim2.fromOffset(250, 52)
	S.buyPack.BorderSizePixel = 0
	S.buyPack.AutoButtonColor = true
	S.buyPack.Text = ""
	S.buyPack.ZIndex = 5
	S.buyPack.Parent = S.foot
	corner(S.buyPack, 6)
	absGrad(S.buyPack, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
	ledge(S.buyPack, TBLACK, 3)
	do
		local wrap = Instance.new("Frame")
		wrap.Size = UDim2.fromScale(1, 1); wrap.BackgroundTransparency = 1; wrap.ZIndex = 6; wrap.Parent = S.buyPack
		local ll = Instance.new("UIListLayout")
		ll.FillDirection = Enum.FillDirection.Horizontal; ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
		ll.VerticalAlignment = Enum.VerticalAlignment.Center; ll.Padding = UDim.new(0, 8); ll.Parent = wrap
		local buyTxt = sticker(wrap, "BUY PACK", 20)
		buyTxt.AutomaticSize = Enum.AutomaticSize.X; buyTxt.Size = UDim2.fromOffset(0, 26); buyTxt.ZIndex = 6
		S.buyGem = robuxGem(wrap, 16)
		S.buyPrice = sticker(wrap, "SOON", 20)
		S.buyPrice.AutomaticSize = Enum.AutomaticSize.X; S.buyPrice.Size = UDim2.fromOffset(0, 26); S.buyPrice.ZIndex = 6
	end
	S.buyPack.Activated:Connect(function()
		local pk = S.data and S.data.pack
		local pid = pk and tonumber(pk.productId) or 0
		if pid < 1 then
			lplay("Error")
			S.say("PACK PRODUCT NOT SET UP YET — COMING SOON", DIMTEXT)
			return
		end
		lplay("Buy")
		MarketplaceService:PromptProductPurchase(localPlayer, pid)
	end)
	-- price / SOON state for the BUY button (mirrors the old pill logic)
	S.setBuy = function(robux)
		if robux then
			S.buyPrice.Text = fmt(robux); S.buyPrice.TextSize = 20; S.buyGem.Visible = true
		else
			S.buyPrice.Text = "SOON"; S.buyPrice.TextSize = 16; S.buyGem.Visible = false
		end
	end

	-- (No pity meter — the bundle is a fixed one-shot buy, not a gacha.)
	S.layoutFeatured() -- ticker starts hidden → the pack rides up

	-- =====================================================================================================
	-- ===== TAB 2: DAILY WHEEL ===== 8 reward chips in a ring + light-chaser spin.
	-- =====================================================================================================
	do
		local cap = sticker(S.page.daily, "TODAY'S WHEEL", 13, Color3.fromRGB(255, 210, 62))
		cap.Position = UDim2.fromOffset(20, 16)
		cap.Size = UDim2.fromOffset(240, 18)
		local wheel = Instance.new("Frame")
		wheel.Position = UDim2.fromOffset(20, 42)
		wheel.Size = UDim2.fromOffset(240, 240)
		wheel.BackgroundColor3 = Color3.fromRGB(22, 25, 16)
		wheel.BorderSizePixel = 0
		wheel.Parent = S.page.daily
		local wc = Instance.new("UICorner")
		wc.CornerRadius = UDim.new(1, 0)
		wc.Parent = wheel
		ledge(wheel, TBLACK, 4)
		ledge(wheel, Color3.fromRGB(255, 210, 62), 1.5, 0.5)
		S.wheelFace = wheel
		local hub = Instance.new("Frame")
		hub.AnchorPoint = Vector2.new(0.5, 0.5)
		hub.Position = UDim2.fromScale(0.5, 0.5)
		hub.Size = UDim2.fromOffset(72, 72)
		hub.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
		hub.BorderSizePixel = 0
		hub.ZIndex = 5
		hub.Parent = wheel
		local hc = Instance.new("UICorner")
		hc.CornerRadius = UDim.new(1, 0)
		hc.Parent = hub
		ledge(hub, TBLACK, 3)
		local hl = sticker(hub, "SPIN!", 15)
		hl.Size = UDim2.fromScale(1, 1)
		hl.ZIndex = 6
		local ptr = Instance.new("Frame") -- white diamond pointer at the top rim
		ptr.AnchorPoint = Vector2.new(0.5, 0.5)
		ptr.Position = UDim2.new(0.5, 0, 0, 2)
		ptr.Size = UDim2.fromOffset(18, 18)
		ptr.Rotation = 45
		ptr.BackgroundColor3 = Color3.new(1, 1, 1)
		ptr.BorderSizePixel = 0
		ptr.ZIndex = 7
		ptr.Parent = wheel
		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, 4)
		pc.Parent = ptr
		ledge(ptr, TBLACK, 2.5)

		S.wheelResult = sticker(S.page.daily, "", 15, ACCENT)
		S.wheelResult.Position = UDim2.fromOffset(0, 288)
		S.wheelResult.Size = UDim2.fromOffset(280, 40)
		S.wheelResult.TextWrapped = true

		-- Right column (renovated): title → streak flame chip → pitch → big SPIN FREE → dark re-spin card.
		local t = sticker(S.page.daily, "ONE FREE SPIN EVERY DAY", 19)
		t.Position = UDim2.fromOffset(292, 14)
		t.Size = UDim2.fromOffset(338, 26)
		t.TextXAlignment = Enum.TextXAlignment.Left
		S.streakChip = Instance.new("Frame") -- the streak lives up top as a gold-ringed chip now
		S.streakChip.Position = UDim2.fromOffset(292, 46)
		S.streakChip.Size = UDim2.fromOffset(338, 26)
		S.streakChip.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
		S.streakChip.BorderSizePixel = 0
		S.streakChip.Parent = S.page.daily
		corner(S.streakChip, 13)
		ledge(S.streakChip, Color3.fromRGB(255, 210, 62), 2, 0.35)
		S.streakLbl = sticker(S.streakChip, "", 12, Color3.fromRGB(255, 210, 62))
		S.streakLbl.Position = UDim2.fromOffset(12, 0)
		S.streakLbl.Size = UDim2.new(1, -20, 1, 0)
		S.streakLbl.TextXAlignment = Enum.TextXAlignment.Left
		S.streakLbl.TextTruncate = Enum.TextTruncate.AtEnd
		S.streakLbl.ZIndex = 5
		local d = Instance.new("TextLabel")
		d.Position = UDim2.fromOffset(292, 82)
		d.Size = UDim2.fromOffset(338, 48)
		d.BackgroundTransparency = 1
		d.FontFace = BODYB_FACE
		d.TextSize = 12
		d.TextColor3 = DIMTEXT
		d.TextWrapped = true
		d.TextXAlignment = Enum.TextXAlignment.Left
		d.TextYAlignment = Enum.TextYAlignment.Top
		d.Text = "COINS · CRATES · A SKIN · JACKPOT: A DIVINE CRATE. Come back daily — claim streaks make the jackpot slice fatter."
		d.Parent = S.page.daily

		S.spinBtn = Instance.new("TextButton")
		S.spinBtn.Position = UDim2.fromOffset(292, 138)
		S.spinBtn.Size = UDim2.fromOffset(338, 58)
		S.spinBtn.BorderSizePixel = 0
		S.spinBtn.AutoButtonColor = true
		S.spinBtn.Text = ""
		S.spinBtn.Parent = S.page.daily
		corner(S.spinBtn, 6)
		absGrad(S.spinBtn, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
		ledge(S.spinBtn, TBLACK, 3)
		S.spinBtnLbl = sticker(S.spinBtn, "SPIN FREE", 21)
		S.spinBtnLbl.Size = UDim2.fromScale(1, 1)
		S.spinBtnLbl.ZIndex = 6
		S.spinBtn.Activated:Connect(function()
			if S.spinning then
				return
			end
			local w = S.data and S.data.wheel
			if not w then
				return
			end
			if w.freeUsed then
				lplay("Error")
				S.say("FREE SPIN USED — COME BACK TOMORROW", DIMTEXT)
				return
			end
			lplay("Click")
			WheelSpin:FireServer()
		end)

		local rb = Instance.new("TextButton") -- CHANGED: dark secondary card (SPIN FREE is the hero)
		rb.Position = UDim2.fromOffset(292, 208)
		rb.Size = UDim2.fromOffset(338, 46)
		rb.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
		rb.BorderSizePixel = 0
		rb.AutoButtonColor = true
		rb.Text = ""
		rb.Parent = S.page.daily
		corner(rb, 8)
		ledge(rb, TBLACK, 3)
		ledge(rb, Color3.fromRGB(89, 193, 34), 1.5, 0.45)
		do
			local wrap = Instance.new("Frame")
			wrap.Size = UDim2.fromScale(1, 1)
			wrap.BackgroundTransparency = 1
			wrap.ZIndex = 6
			wrap.Parent = rb
			local ll = Instance.new("UIListLayout")
			ll.FillDirection = Enum.FillDirection.Horizontal
			ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
			ll.VerticalAlignment = Enum.VerticalAlignment.Center
			ll.Padding = UDim.new(0, 6)
			ll.Parent = wrap
			S.respinGem = robuxGem(wrap, 13)
			S.respinLbl = sticker(wrap, "SPIN AGAIN", 15)
			S.respinLbl.AutomaticSize = Enum.AutomaticSize.X
			S.respinLbl.Size = UDim2.fromOffset(0, 24)
			S.respinLbl.ZIndex = 6
		end
		S.respinNote = Instance.new("TextLabel")
		S.respinNote.Position = UDim2.fromOffset(292, 258)
		S.respinNote.Size = UDim2.fromOffset(338, 16)
		S.respinNote.BackgroundTransparency = 1
		S.respinNote.FontFace = BODYB_FACE
		S.respinNote.TextSize = 10
		S.respinNote.TextColor3 = DIMTEXT
		S.respinNote.TextXAlignment = Enum.TextXAlignment.Left
		S.respinNote.Text = "(Robux re-spins, up to 3/day)"
		S.respinNote.Parent = S.page.daily
		rb.Activated:Connect(function()
			if S.spinning then
				return
			end
			local w = S.data and S.data.wheel
			if not w then
				return
			end
			local pid = tonumber(w.respinProduct) or 0
			if pid < 1 then
				lplay("Error")
				S.say("RE-SPIN PRODUCT NOT SET UP YET — COMING SOON", DIMTEXT)
				return
			end
			if (w.paidLeft or 0) <= 0 then
				lplay("Error")
				S.say("NO RE-SPINS LEFT TODAY", ORANGE)
				return
			end
			lplay("Buy")
			MarketplaceService:PromptProductPurchase(localPlayer, pid)
		end)

	end

	-- Build the 8 reward chips around the wheel once the segment data arrives.
	S.wheelChips = {}
	S.buildWheel = function(segs)
		if #S.wheelChips > 0 then
			return
		end
		local total = 0
		for _, s in segs do
			total += s.weight or 0
		end
		for i, s in ipairs(segs) do
			local a = math.rad((i - 1) * (360 / #segs)) -- chip 1 at the top, clockwise
			local cx = 120 + math.sin(a) * 86
			local cy = 120 - math.cos(a) * 86
			local chip = Instance.new("Frame")
			chip.AnchorPoint = Vector2.new(0.5, 0.5)
			chip.Position = UDim2.fromOffset(cx, cy)
			chip.Size = UDim2.fromOffset(62, 50)
			chip.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
			chip.BorderSizePixel = 0
			chip.ZIndex = 3
			chip.Parent = S.wheelFace
			local cc = Instance.new("UICorner")
			cc.CornerRadius = UDim.new(0, 8)
			cc.Parent = chip
			local ring = ledge(chip, s.jackpot and Color3.fromRGB(255, 210, 62) or TBLACK, 2.5)
			-- DRAWN icon per reward kind (no 9px essays): coin discs / the crate's render / a tinted gun.
			local icon = Instance.new("Frame")
			icon.AnchorPoint = Vector2.new(0.5, 0)
			icon.Position = UDim2.new(0.5, 0, 0, 2)
			icon.Size = UDim2.fromOffset(34, 24)
			icon.BackgroundTransparency = 1
			icon.ZIndex = 4
			icon.Parent = chip
			if s.kind == "coins" then
				for k = 1, 2 do -- a little stack of gold coins
					local disc = Instance.new("Frame")
					disc.Position = UDim2.fromOffset(2 + (k - 1) * 12, 4 + (k % 2) * 3)
					disc.Size = UDim2.fromOffset(16, 16)
					disc.BackgroundColor3 = GOLD
					disc.BorderSizePixel = 0
					disc.ZIndex = 4 + k
					disc.Parent = icon
					local dc = Instance.new("UICorner")
					dc.CornerRadius = UDim.new(1, 0)
					dc.Parent = disc
					ledge(disc, TBLACK, 2)
				end
			elseif s.kind == "case" and s.case then
				local vp = makeGunViewport(s.case, false, "CrateDisplay")
				if vp then
					vp.Size = UDim2.fromScale(1, 1)
					vp.ZIndex = 4
					vp.Parent = icon
				else
					local sq = Instance.new("Frame") -- no crate model yet: a rarity-colored crate block
					sq.AnchorPoint = Vector2.new(0.5, 0.5)
					sq.Position = UDim2.fromScale(0.5, 0.5)
					sq.Size = UDim2.fromOffset(18, 16)
					sq.BackgroundColor3 = rarityColor(s.case)
					sq.BorderSizePixel = 0
					sq.ZIndex = 4
					sq.Parent = icon
					local sc = Instance.new("UICorner")
					sc.CornerRadius = UDim.new(0, 4)
					sc.Parent = sq
					ledge(sq, TBLACK, 2)
				end
			else -- random skin: a pink-tinted gun
				local vp = makeGunViewport("pistol", false, nil, Color3.fromRGB(255, 105, 190))
				if vp then
					vp.Size = UDim2.fromScale(1, 1)
					vp.ZIndex = 4
					vp.Parent = icon
				end
			end
			local lbl = Instance.new("TextLabel")
			lbl.Position = UDim2.fromOffset(2, 27)
			lbl.Size = UDim2.new(1, -4, 0, 11)
			lbl.BackgroundTransparency = 1
			lbl.FontFace = BODYB_FACE
			lbl.TextSize = 9
			lbl.TextColor3 = s.jackpot and Color3.fromRGB(255, 210, 62) or TEXTCOL
			lbl.ZIndex = 4
			lbl.Text = s.kind == "coins" and fmt(s.amount or 0) or (s.kind == "case" and (s.case or ""):upper() or "SKIN")
			lbl.Parent = chip
			local pct = Instance.new("TextLabel")
			pct.AnchorPoint = Vector2.new(0.5, 1)
			pct.Position = UDim2.new(0.5, 0, 1, -1)
			pct.Size = UDim2.fromOffset(50, 10)
			pct.BackgroundTransparency = 1
			pct.FontFace = BODYB_FACE
			pct.TextSize = 9
			pct.TextColor3 = DIMTEXT
			pct.ZIndex = 4
			pct.Text = total > 0 and ("%d%%"):format(math.floor((s.weight or 0) / total * 100 + 0.5)) or ""
			pct.Parent = chip
			S.wheelChips[i] = { chip = chip, ring = ring, jackpot = s.jackpot }
		end
	end

	-- The spin: a light chases around the chips, decelerating, and lands on the server's segment.
	S.spinTo = function(idx, rewardText, jackpotHit)
		if #S.wheelChips == 0 then
			S.wheelResult.Text = rewardText -- wheel not built (no data yet): just show the prize
			return
		end
		S.spinning = true
		S.wheelResult.Text = ""
		task.spawn(function()
			local n = #S.wheelChips
			local steps = n * 2 + (idx - 1) -- two laps, then land on idx (chase starts at chip 1)
			local prev = nil
			for s = 0, steps do
				local at = (s % n) + 1
				if prev then
					local pc = S.wheelChips[prev]
					pc.ring.Color = pc.jackpot and Color3.fromRGB(255, 210, 62) or TBLACK
					pc.ring.Thickness = 2.5
				end
				local c = S.wheelChips[at]
				c.ring.Color = Color3.new(1, 1, 1)
				c.ring.Thickness = 4
				prev = at
				lplay("ReelTick", 0.9 + (s / steps) * 0.25)
				task.wait(0.05 + (s / steps) ^ 2 * 0.32)
			end
			lplay(jackpotHit and "RevealJackpot" or "RevealHigh")
			S.wheelResult.Text = rewardText
			S.spinning = false
		end)
	end

	WheelSpin.OnClientEvent:Connect(function(res)
		if typeof(res) ~= "table" then
			return
		end
		if res.failed then
			lplay("Error")
			S.say(tostring(res.msg or "TRY AGAIN LATER"), ORANGE)
			return
		end
		local seg = tonumber(res.seg) or 1
		local jackpot = S.wheelChips[seg] and S.wheelChips[seg].jackpot or false
		S.spinTo(seg, tostring(res.reward or ""), jackpot)
	end)

	-- =====================================================================================================
	-- ===== TAB 3: PASSES & COINS ===== gamepass cards → coin bundles → the one-time starter pack.
	-- =====================================================================================================
	do
		-- Big DRAWN emblems (flat shapes, no images needed): coin stack / XP bolt / crown.
		local function drawEmblem(parent, kind)
			local em = Instance.new("Frame")
			em.AnchorPoint = Vector2.new(0.5, 0)
			em.Position = UDim2.new(0.5, 0, 0, 8)
			em.Size = UDim2.fromOffset(52, 30)
			em.BackgroundTransparency = 1
			em.ZIndex = 5
			em.Parent = parent
			if kind == "coins" then
				for k = 1, 3 do
					local disc = Instance.new("Frame")
					disc.Position = UDim2.fromOffset((k - 1) * 14, (k % 2) * 5 + 2)
					disc.Size = UDim2.fromOffset(22, 22)
					disc.BackgroundColor3 = GOLD
					disc.BorderSizePixel = 0
					disc.ZIndex = 5 + k
					disc.Parent = em
					local dc = Instance.new("UICorner")
					dc.CornerRadius = UDim.new(1, 0)
					dc.Parent = disc
					ledge(disc, TBLACK, 2)
				end
			elseif kind == "xp" then
				for k, rot in { -24, 24 } do -- two slanted strokes = a chunky bolt
					local barF = Instance.new("Frame")
					barF.AnchorPoint = Vector2.new(0.5, 0.5)
					barF.Position = UDim2.fromOffset(20 + (k - 1) * 12, 9 + (k - 1) * 12)
					barF.Size = UDim2.fromOffset(11, 22)
					barF.Rotation = rot
					barF.BackgroundColor3 = Color3.fromRGB(255, 236, 120)
					barF.BorderSizePixel = 0
					barF.ZIndex = 6
					barF.Parent = em
					local bc = Instance.new("UICorner")
					bc.CornerRadius = UDim.new(0, 3)
					bc.Parent = barF
					ledge(barF, TBLACK, 2)
				end
			else -- vip crown: a gold base bar + three diamond points
				local base = Instance.new("Frame")
				base.AnchorPoint = Vector2.new(0.5, 1)
				base.Position = UDim2.new(0.5, 0, 1, 0)
				base.Size = UDim2.fromOffset(42, 11)
				base.BackgroundColor3 = GOLD
				base.BorderSizePixel = 0
				base.ZIndex = 6
				base.Parent = em
				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 3)
				bc.Parent = base
				ledge(base, TBLACK, 2)
				for k = 1, 3 do
					local pt = Instance.new("Frame")
					pt.AnchorPoint = Vector2.new(0.5, 0.5)
					pt.Position = UDim2.new(0.5, (k - 2) * 15, 0, k == 2 and 8 or 12)
					pt.Size = UDim2.fromOffset(12, 12)
					pt.Rotation = 45
					pt.BackgroundColor3 = GOLD
					pt.BorderSizePixel = 0
					pt.ZIndex = 5
					pt.Parent = em
					local pc = Instance.new("UICorner")
					pc.CornerRadius = UDim.new(0, 2)
					pc.Parent = pt
					ledge(pt, TBLACK, 2)
				end
			end
		end
		for i, gp in GAMEPASSES do
			local card = Instance.new("TextButton")
			card.Position = UDim2.fromOffset((i - 1) * 216, 0)
			card.Size = UDim2.fromOffset(200, 132) -- CHANGED: taller — the subtitle gets 2 real lines
			card.BorderSizePixel = 0
			card.AutoButtonColor = true
			card.Text = ""
			card.Parent = S.page.passes
			corner(card, 8)
			absGrad(card, gp.color, gp.color2)
			ledge(card, TBLACK, 3)
			ledge(card, Color3.new(1, 1, 1), 1.5, 0.82) -- faint inner rim, same glass trick as the dock
			drawEmblem(card, gp.emblem)
			local nm = sticker(card, gp.name, 18)
			nm.Position = UDim2.fromOffset(0, 44)
			nm.Size = UDim2.new(1, 0, 0, 22)
			nm.ZIndex = 5
			local sub = Instance.new("TextLabel")
			sub.Position = UDim2.fromOffset(10, 68)
			sub.Size = UDim2.new(1, -20, 0, 24)
			sub.BackgroundTransparency = 1
			sub.FontFace = BODYB_FACE
			sub.TextSize = 10
			sub.TextColor3 = Color3.new(1, 1, 1)
			sub.TextTransparency = 0.2
			sub.TextWrapped = true
			sub.TextYAlignment = Enum.TextYAlignment.Top
			sub.ZIndex = 5
			sub.Text = gp.sub
			sub.Parent = card
			local pricePill = Instance.new("Frame")
			pricePill.AnchorPoint = Vector2.new(0.5, 1)
			pricePill.Position = UDim2.new(0.5, 0, 1, -8)
			pricePill.Size = UDim2.fromOffset(110, 32)
			pricePill.BorderSizePixel = 0
			pricePill.ZIndex = 5
			pricePill.Parent = card
			corner(pricePill, 5)
			absGrad(pricePill, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
			ledge(pricePill, TBLACK, 2.5)
			local wrap = Instance.new("Frame")
			wrap.Size = UDim2.fromScale(1, 1)
			wrap.BackgroundTransparency = 1
			wrap.ZIndex = 6
			wrap.Parent = pricePill
			local ll = Instance.new("UIListLayout")
			ll.FillDirection = Enum.FillDirection.Horizontal
			ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
			ll.VerticalAlignment = Enum.VerticalAlignment.Center
			ll.Padding = UDim.new(0, 5)
			ll.Parent = wrap
			local gem = robuxGem(wrap, 12)
			local priceLbl = sticker(wrap, "SOON", 14)
			priceLbl.AutomaticSize = Enum.AutomaticSize.X
			priceLbl.Size = UDim2.fromOffset(0, 22)
			priceLbl.ZIndex = 6
			gem.Visible = false -- shown once a real price lands
			local owned = false
			if gp.id and gp.id > 0 then
				task.spawn(function() -- live price + already-owned state
					local okO, has = pcall(function()
						return MarketplaceService:UserOwnsGamePassAsync(localPlayer.UserId, gp.id)
					end)
					if okO and has then
						owned = true
						priceLbl.Text = "OWNED"
						gem.Visible = false
						card.AutoButtonColor = false
						return
					end
					local ok, info = pcall(function()
						return MarketplaceService:GetProductInfo(gp.id, Enum.InfoType.GamePass)
					end)
					if ok and info and tonumber(info.PriceInRobux) then
						priceLbl.Text = fmt(info.PriceInRobux)
						priceLbl.TextSize = 15
						gem.Visible = true
					else
						-- id exists but no price came back (off-sale / lookup hiccup): still buyable,
						-- never pretend it's unwired
						priceLbl.Text = "BUY"
					end
				end)
			end
			card.Activated:Connect(function()
				if owned then
					lplay("Error")
					S.say(gp.name .. " — ALREADY OWNED", DIMTEXT)
				elseif gp.id and gp.id > 0 then
					MarketplaceService:PromptGamePassPurchase(localPlayer, gp.id)
				else
					lplay("Error")
					S.say(gp.name .. " — COMING SOON", DIMTEXT)
				end
			end)
		end

		local bt = sticker(S.page.passes, "COIN BUNDLES", 14, Color3.fromRGB(255, 210, 62))
		bt.Position = UDim2.fromOffset(0, 144)
		bt.Size = UDim2.fromOffset(130, 18)
		bt.TextXAlignment = Enum.TextXAlignment.Left
		local rule = Instance.new("Frame") -- hairline pulling the section together
		rule.Position = UDim2.fromOffset(138, 152)
		rule.Size = UDim2.new(1, -140, 0, 2)
		rule.BackgroundColor3 = Color3.fromRGB(255, 210, 62)
		rule.BackgroundTransparency = 0.75
		rule.BorderSizePixel = 0
		rule.Parent = S.page.passes

		S.bundleBtns = {}
		for i = 1, 4 do
			local card = Instance.new("TextButton")
			card.Position = UDim2.fromOffset((i - 1) * 161, 170)
			card.Size = UDim2.fromOffset(150, 96)
			card.BorderSizePixel = 0
			card.AutoButtonColor = true
			card.Text = ""
			card.Parent = S.page.passes
			corner(card, 8)
			absGrad(card, Color3.fromRGB(37, 74, 99), Color3.fromRGB(19, 42, 58))
			ledge(card, TBLACK, 3)
			local ci = Instance.new("ImageLabel") -- the real coin art, not a text row
			ci.AnchorPoint = Vector2.new(0.5, 0)
			ci.Position = UDim2.new(0.5, 0, 0, 6)
			ci.Size = UDim2.fromOffset(26, 26)
			ci.BackgroundTransparency = 1
			ci.ScaleType = Enum.ScaleType.Fit
			ci.Image = "rbxassetid://84729396970772"
			ci.ZIndex = 5
			ci.Parent = card
			local amt = sticker(card, "--", 15, Color3.fromRGB(255, 210, 62))
			amt.Position = UDim2.fromOffset(0, 34)
			amt.Size = UDim2.new(1, 0, 0, 20)
			amt.ZIndex = 5
			local pill = Instance.new("Frame")
			pill.AnchorPoint = Vector2.new(0.5, 1)
			pill.Position = UDim2.new(0.5, 0, 1, -10)
			pill.Size = UDim2.fromOffset(96, 30)
			pill.BorderSizePixel = 0
			pill.ZIndex = 5
			pill.Parent = card
			corner(pill, 5)
			absGrad(pill, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
			ledge(pill, TBLACK, 2.5)
			local wrap = Instance.new("Frame")
			wrap.Size = UDim2.fromScale(1, 1)
			wrap.BackgroundTransparency = 1
			wrap.ZIndex = 6
			wrap.Parent = pill
			local ll = Instance.new("UIListLayout")
			ll.FillDirection = Enum.FillDirection.Horizontal
			ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
			ll.VerticalAlignment = Enum.VerticalAlignment.Center
			ll.Padding = UDim.new(0, 5)
			ll.Parent = wrap
			local gem = robuxGem(wrap, 12)
			local priceLbl = sticker(wrap, "SOON", 13)
			priceLbl.AutomaticSize = Enum.AutomaticSize.X
			priceLbl.Size = UDim2.fromOffset(0, 20)
			priceLbl.ZIndex = 6
			local badge = sticker(card, "", 11, Color3.new(1, 1, 1))
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, -4, 0, -10)
			badge.Size = UDim2.fromOffset(52, 18)
			badge.BackgroundTransparency = 0
			badge.BackgroundColor3 = Color3.fromRGB(255, 122, 226)
			badge.Visible = false
			badge.ZIndex = 6
			do
				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 6)
				bc.Parent = badge
				ledge(badge, TBLACK, 2)
			end
			S.bundleBtns[i] = { amt = amt, price = priceLbl, badge = badge, gem = gem }
			card.Activated:Connect(function()
				local b = S.data and S.data.bundles and S.data.bundles[i]
				local pid = b and tonumber(b.productId) or 0
				if pid < 1 then
					lplay("Error")
					S.say("COIN BUNDLE PRODUCT NOT SET UP YET — COMING SOON", DIMTEXT)
					return
				end
				lplay("Buy")
				MarketplaceService:PromptProductPurchase(localPlayer, pid)
			end)
		end

		S.starterBar = Instance.new("TextButton")
		S.starterBar.Position = UDim2.fromOffset(0, 280)
		S.starterBar.Size = UDim2.new(1, -2, 0, 52)
		S.starterBar.BorderSizePixel = 0
		S.starterBar.AutoButtonColor = true
		S.starterBar.Text = ""
		S.starterBar.Parent = S.page.passes
		corner(S.starterBar, 6)
		absGrad(S.starterBar, Color3.fromRGB(99, 35, 79), Color3.fromRGB(52, 18, 40))
		ledge(S.starterBar, TBLACK, 3)
		do
			local nm = sticker(S.starterBar, "STARTER PACK", 17, Color3.fromRGB(255, 122, 226))
			nm.Position = UDim2.fromOffset(14, 0)
			nm.Size = UDim2.fromOffset(160, 52)
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.ZIndex = 5
			local ct = Instance.new("TextLabel")
			ct.Position = UDim2.fromOffset(184, 0)
			ct.Size = UDim2.fromOffset(260, 52)
			ct.BackgroundTransparency = 1
			ct.FontFace = BODYB_FACE
			ct.TextSize = 12
			ct.TextColor3 = TEXTCOL
			ct.TextXAlignment = Enum.TextXAlignment.Left
			ct.ZIndex = 5
			ct.Text = "3 RARE CRATES + 2,000 COINS · ONE TIME ONLY"
			ct.Parent = S.starterBar
			local pill = Instance.new("Frame")
			pill.AnchorPoint = Vector2.new(1, 0.5)
			pill.Position = UDim2.new(1, -12, 0.5, 0)
			pill.Size = UDim2.fromOffset(110, 34)
			pill.BorderSizePixel = 0
			pill.ZIndex = 5
			pill.Parent = S.starterBar
			corner(pill, 5)
			absGrad(pill, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
			ledge(pill, TBLACK, 2.5)
			local wrap = Instance.new("Frame")
			wrap.Size = UDim2.fromScale(1, 1)
			wrap.BackgroundTransparency = 1
			wrap.ZIndex = 6
			wrap.Parent = pill
			local ll = Instance.new("UIListLayout")
			ll.FillDirection = Enum.FillDirection.Horizontal
			ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
			ll.VerticalAlignment = Enum.VerticalAlignment.Center
			ll.Padding = UDim.new(0, 5)
			ll.Parent = wrap
			S.starterGem = robuxGem(wrap, 12)
			S.starterPrice = sticker(wrap, "SOON", 15)
			S.starterPrice.AutomaticSize = Enum.AutomaticSize.X
			S.starterPrice.Size = UDim2.fromOffset(0, 22)
			S.starterPrice.ZIndex = 6
		end
		S.starterBar.Activated:Connect(function()
			local st = S.data and S.data.starter
			if not st then
				return
			end
			if st.bought then
				lplay("Error")
				S.say("STARTER PACK ALREADY OWNED", DIMTEXT)
				return
			end
			local pid = tonumber(st.productId) or 0
			if pid < 1 then
				lplay("Error")
				S.say("STARTER PACK PRODUCT NOT SET UP YET — COMING SOON", DIMTEXT)
				return
			end
			lplay("Buy")
			MarketplaceService:PromptProductPurchase(localPlayer, pid)
		end)
	end

	-- =====================================================================================================
	-- ===== TAB 4: CODES ===== the redeem bar.
	-- =====================================================================================================
	do
		local t = sticker(S.page.codes, "GOT A CODE?", 20)
		t.Position = UDim2.fromOffset(0, 90)
		t.Size = UDim2.new(1, 0, 0, 26)
		S.codeBox = Instance.new("TextBox")
		S.codeBox.Position = UDim2.fromOffset(96, 140)
		S.codeBox.Size = UDim2.fromOffset(290, 46)
		S.codeBox.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
		S.codeBox.BorderSizePixel = 0
		S.codeBox.FontFace = TITLE_FACE
		S.codeBox.TextSize = 17
		S.codeBox.TextColor3 = TEXTCOL
		S.codeBox.PlaceholderText = "Enter Code..."
		S.codeBox.PlaceholderColor3 = DIMTEXT
		S.codeBox.ClearTextOnFocus = false
		S.codeBox.Text = ""
		S.codeBox.Parent = S.page.codes
		corner(S.codeBox, 10)
		ledge(S.codeBox, TBLACK, 3)
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(396, 140)
		b.Size = UDim2.fromOffset(150, 46)
		b.BorderSizePixel = 0
		b.Text = ""
		b.Parent = S.page.codes
		corner(b, 10)
		absGrad(b, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
		ledge(b, TBLACK, 3)
		local bl = sticker(b, "REDEEM", 19)
		bl.Size = UDim2.fromScale(1, 1)
		bl.ZIndex = 6
		b.Activated:Connect(function()
			local code = S.codeBox.Text
			if #code:gsub("%s", "") < 1 then
				return
			end
			S.say("CHECKING...", DIMTEXT)
			ShopRedeem:FireServer(code)
		end)
		local hint = Instance.new("TextLabel")
		hint.Position = UDim2.fromOffset(0, 210)
		hint.Size = UDim2.new(1, 0, 0, 20)
		hint.BackgroundTransparency = 1
		hint.FontFace = BODYB_FACE
		hint.TextSize = 12
		hint.TextColor3 = DIMTEXT
		hint.Text = "NEW CODES DROP ON THE GAME PAGE — REDEEM EACH ONE ONCE"
		hint.Parent = S.page.codes
	end

	-- Cancelled the purchase prompt? DISARM any pending gift so a later self-buy can't mis-deliver.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, purchased)
		if userId == localPlayer.UserId and not purchased then
			ShopGift:FireServer(nil)
		end
	end)
	-- Gift toasts: buyer gets a confirm line; the RECIPIENT gets a big center-top toast.
	S.toast = sticker(S.gui, "", 22)
	S.toast.AnchorPoint = Vector2.new(0.5, 0)
	S.toast.Position = UDim2.new(0.5, 0, 0, -60)
	S.toast.Size = UDim2.fromOffset(760, 34)
	S.toast.ZIndex = 40
	ShopGift.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then
			return
		end
		if data.sent then
			lplay("Buy")
			S.say(("GIFT SENT TO %s!"):format(tostring(data.to):upper()), ACCENT)
			return
		end
		if data.from then
			lplay("RevealHigh")
			S.toast.Text = ("🎁 %s GIFTED YOU %s ×%d — CHECK YOUR INVENTORY!"):format(
				tostring(data.from):upper(), tostring(data.name or "A PACK"):upper(), tonumber(data.count) or 1)
			local my = os.clock()
			S.toastAt = my
			TweenService:Create(S.toast, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Position = UDim2.new(0.5, 0, 0, 84) }):Play()
			task.delay(6, function()
				if S.toastAt == my then
					TweenService:Create(S.toast, TweenInfo.new(0.3), { Position = UDim2.new(0.5, 0, 0, -60) }):Play()
				end
			end)
		end
	end)

	-- The live pull ticker (last 3 legendary+ pulls on this server). First pull reveals the row.
	ShopTicker.OnClientEvent:Connect(function(t)
		if typeof(t) ~= "table" or not t.item then
			return
		end
		table.insert(S.tickerQ, 1, ("⚡ %s pulled %s!"):format(tostring(t.name or "Someone"), tostring(t.item):upper()))
		while #S.tickerQ > 3 do
			table.remove(S.tickerQ)
		end
		S.ticker.Text = table.concat(S.tickerQ, "   ·   ")
		if not S.ticker.Visible then
			S.ticker.Visible = true
			S.layoutFeatured()
		end
	end)

	-- =====================================================================================================
	-- ===== RENDER + WIRING =====
	-- =====================================================================================================
	S.render = function()
		local d = S.data
		if not d then
			return
		end
		-- FEATURED: the fixed BUNDLE — a loot card per gun (from S.data.pack.guns) + a coins card.
		local pk = d.pack
		if pk then
			S.packTitle.Text = (pk.name or "EXCLUSIVE GUN PACK"):upper()
			S.setBuy(pk.robux)
			clearChildren(S.items)
			local cards = {}
			if typeof(pk.guns) == "table" then
				for _, g in pk.guns do
					table.insert(cards, { kind = "gun", id = g.id, name = g.name, rarity = g.rarity, owned = g.owned })
				end
			end
			table.insert(cards, { kind = "coins" })
			local n = #cards
			local CARD_W, GAP = 150, 12
			local startX = math.floor((628 - (n * CARD_W + (n - 1) * GAP)) / 2)
			for i, c in cards do
				local col = (c.kind == "coins") and GOLD or rarityColor(c.rarity or "epic")
				local card = Instance.new("Frame")
				card.Position = UDim2.fromOffset(startX + (i - 1) * (CARD_W + GAP), 10)
				card.Size = UDim2.fromOffset(CARD_W, 176)
				card.BorderSizePixel = 0
				card.ClipsDescendants = true
				card.ZIndex = 3
				card.Parent = S.items
				corner(card, 6)
				absGrad(card, col:Lerp(Color3.fromRGB(20, 16, 10), 0.4), Color3.fromRGB(13, 11, 7), col:Lerp(Color3.fromRGB(16, 13, 8), 0.72))
				ledge(card, col, 3)
				if c.kind == "gun" then
					local vp = makeGunViewport(c.id, false)
					if vp then
						vp.Position = UDim2.fromOffset(0, 12)
						vp.Size = UDim2.new(1, 0, 0, 104)
						vp.ZIndex = 4
						vp.Parent = card
					else
						local ph = sticker(card, (c.name or c.id):upper(), 14, col)
						ph.Position = UDim2.fromOffset(6, 34); ph.Size = UDim2.new(1, -12, 0, 72)
						ph.TextWrapped = true; ph.ZIndex = 4
					end
					local nm = sticker(card, (c.name or c.id):upper(), 15)
					nm.Position = UDim2.fromOffset(0, 122); nm.Size = UDim2.new(1, 0, 0, 18); nm.ZIndex = 5
					local tag = sticker(card, c.owned and "OWNED → COINS" or "NEW GUN", 11, c.owned and GOLD or ACCENT)
					tag.Position = UDim2.fromOffset(0, 146); tag.Size = UDim2.new(1, 0, 0, 14); tag.ZIndex = 5
				else
					local ci = Instance.new("ImageLabel")
					ci.AnchorPoint = Vector2.new(0.5, 0)
					ci.Position = UDim2.new(0.5, 0, 0, 20)
					ci.Size = UDim2.fromOffset(58, 58)
					ci.BackgroundTransparency = 1
					ci.ScaleType = Enum.ScaleType.Fit
					ci.Image = "rbxassetid://84729396970772"
					ci.ZIndex = 4
					ci.Parent = card
					local amt = sticker(card, fmt(pk.coins or 0), 26, GOLD)
					amt.Position = UDim2.fromOffset(0, 86); amt.Size = UDim2.new(1, 0, 0, 28); amt.ZIndex = 5
					local nm = sticker(card, "COINS", 15)
					nm.Position = UDim2.fromOffset(0, 122); nm.Size = UDim2.new(1, 0, 0, 18); nm.ZIndex = 5
					local tag = sticker(card, "INSTANT CASH", 11, ACCENT)
					tag.Position = UDim2.fromOffset(0, 146); tag.Size = UDim2.new(1, 0, 0, 14); tag.ZIndex = 5
				end
			end
		end

		-- DAILY: wheel chips + button states + streak + tab badge
		local w = d.wheel
		if w then
			if typeof(w.segments) == "table" then
				S.buildWheel(w.segments)
			end
			if w.freeUsed then
				S.spinBtnLbl.Text = "COME BACK TOMORROW"
				S.spinBtnLbl.TextSize = 15
			else
				S.spinBtnLbl.Text = "SPIN FREE"
				S.spinBtnLbl.TextSize = 21
			end
			if w.respinRobux then
				S.respinLbl.Text = fmt(w.respinRobux) .. " SPIN AGAIN"
				S.respinGem.Visible = true
				S.respinNote.Text = ("(Robux re-spins, %d left today)"):format(tonumber(w.paidLeft) or 0)
			else
				S.respinLbl.Text = "RE-SPINS COMING SOON"
				S.respinGem.Visible = false
				S.respinNote.Text = ""
			end
			local streak = tonumber(w.streak) or 0
			S.streakLbl.Text = streak > 1
				and ("🔥 STREAK: %d DAYS — THE JACKPOT SLICE IS FATTER"):format(streak)
				or "CLAIM DAILY TO BUILD A STREAK — IT FATTENS THE JACKPOT"
			dockBtns.dailyBadge.Visible = not w.freeUsed -- the dock's Daily button carries the "!"
		end

		-- PASSES: bundle amounts/prices + starter state
		if typeof(d.bundles) == "table" then
			for i, e in S.bundleBtns do
				local b = d.bundles[i]
				if b then
					e.amt.Text = fmt(b.coins) .. " COINS"
					e.price.Text = b.robux and fmt(b.robux) or "SOON"
					e.gem.Visible = b.robux ~= nil
					e.badge.Visible = b.bonus ~= nil
					e.badge.Text = b.bonus or ""
				end
			end
		end
		local st = d.starter
		if st then
			if st.bought then
				S.starterPrice.Text = "OWNED"
				S.starterGem.Visible = false
				S.starterBar.AutoButtonColor = false
				S.starterBar.BackgroundTransparency = 0.4
			else
				S.starterPrice.Text = st.robux and fmt(st.robux) or "SOON"
				S.starterGem.Visible = st.robux ~= nil
				S.starterBar.AutoButtonColor = true
				S.starterBar.BackgroundTransparency = 0
			end
		end
	end

	local function closeShop()
		if S.root.Visible then
			uiFocusClose()
		end
		S.root.Visible = false
	end

	-- GONE IN countdown (hh:mm:ss).
	task.spawn(function()
		while true do
			task.wait(0.5)
			if S.root.Visible then
				local left = math.max(0, S.deadline - os.clock())
				S.timer.Text = ("%02d:%02d:%02d"):format(math.floor(left / 3600), math.floor(left / 60) % 60, math.floor(left) % 60)
			end
		end
	end)

	-- The fixed bundle landed: server already granted the guns + coins; confirm what you got.
	PackGranted.OnClientEvent:Connect(function(info)
		if typeof(info) ~= "table" then
			return
		end
		local newGuns = 0
		if typeof(info.guns) == "table" then
			for _, g in info.guns do
				if g.unlocked then
					newGuns += 1
				end
			end
		end
		local coins = tonumber(info.coins) or 0
		local dupeCoins = tonumber(info.dupeCoins) or 0
		if dupeCoins > 0 then
			S.say(("PACK CLAIMED — %d NEW GUN%s + %s COINS (incl. %s dupe payout)!"):format(
				newGuns, newGuns == 1 and "" or "S", fmt(coins + dupeCoins), fmt(dupeCoins)), ACCENT)
		else
			S.say(("PACK CLAIMED — %d NEW GUN%s + %s COINS!"):format(
				newGuns, newGuns == 1 and "" or "S", fmt(coins)), ACCENT)
		end
		lplay("RevealHigh")
	end)

	ShopSync.OnClientEvent:Connect(function(p)
		if typeof(p) ~= "table" then
			return
		end
		S.data = p
		S.deadline = os.clock() + (tonumber(p.endsIn) or 0)
		if p.enter then
			if not invData then
				InvRequest:FireServer() -- the pack pool renders from the catalog
			end
			if not S.root.Visible then
				lplay("Open")
				uiFocusOpen()
				S.root.Visible = true
				S.setTab(S.pendingTab or "featured") -- land on the tab the dock button asked for
				S.pendingTab = nil
			end
			if invPanel.Visible and not rolling then -- one panel at a time
				invPanel.Visible = false
				uiFocusClose()
			end
		end
		if S.root.Visible then
			S.render()
		else
			-- keep the DAILY badge honest even while closed (the dock button pulses interest)
			if p.wheel then
				dockBtns.dailyBadge.Visible = not p.wheel.freeUsed
			end
		end
	end)
	InvSync.OnClientEvent:Connect(function() -- the catalog just landed: fill in the pack pool
		if S.root.Visible then
			S.render()
		end
	end)
	ShopClose.OnClientEvent:Connect(closeShop)
	S.x.Activated:Connect(function()
		lplay("Close")
		closeShop()
	end)
	ShopRedeem.OnClientEvent:Connect(function(res)
		if typeof(res) ~= "table" then
			return
		end
		if res.ok then
			lplay("RevealHigh")
			S.codeBox.Text = ""
			S.say(tostring(res.msg or "REDEEMED!"), ACCENT)
		else
			lplay("Error")
			S.say(tostring(res.msg or "INVALID CODE"), ORANGE)
		end
	end)

	-- ===== DOCK WIRING ===== the dock's Shop/Daily/Pass/Codes buttons deep-link into this panel's
	-- tabs. Closed → ask the server (enter=true opens it) and remember which tab to land on.
	local function openShopTab(tab)
		lplay("Click")
		if S.root.Visible then
			if S.tab == tab then -- same button twice = toggle closed
				lplay("Close")
				closeShop()
			else
				S.setTab(tab)
			end
		else
			S.pendingTab = tab
			ShopSync:FireServer()
		end
	end
	dockBtns.shop.Activated:Connect(function()
		openShopTab("featured")
	end)
	dockBtns.daily.Activated:Connect(function()
		openShopTab("daily")
	end)
	-- The Classes dock button opens the SHOWCASE (its own block below) — here it only puts the shop away.
	dockBtns.classes.Activated:Connect(closeShop)
	dockBtns.codes.Activated:Connect(function()
		openShopTab("codes")
	end)
	-- Opening WEAPONS/INVENTORY (buttons or the B key) puts the shop away — one panel at a time.
	gunsBtn.Activated:Connect(closeShop)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.B then
			closeShop()
		end
	end)
end

-- =====================================================================================================
-- ===== CLASS SHOWCASE ===== Classes dock button → the HUD hides and the camera PANS to the owner-
-- placed display character (build a Model named "ClassCharacter" — or "ClassStage" — anywhere in the
-- lobby; code spawns NOTHING). The class list is the approved L4-style LEFT panel: rows with an icon
-- circle, name, stat line, EQUIPPED badge; the SELECT button at the bottom equips (server-validated,
-- applies NEXT RUN via the game's ClassConfig). No gun skins here. ← flies the camera home.
do
	local ClassEquipR = remotes:WaitForChild("ClassEquip")
	local TS = game:GetService("TweenService")
	local CLASSES = { -- mirrors the game's ClassConfig BY HAND; c0/c1 = each row's own colour (G watermark)
		{ id = "soldier", emoji = "🎖️", name = "SOLDIER", line = "+12% GUN DAMAGE · APPLIES NEXT RUN",
			perk = "+12% GUN DAMAGE", anim = "", gear = "",
			c0 = Color3.fromRGB(150, 30, 22), c1 = Color3.fromRGB(206, 60, 42) },
		{ id = "juggernaut", emoji = "🛡️", name = "JUGGERNAUT", line = "+50 MAX HP · APPLIES NEXT RUN",
			perk = "+50 MAX HEALTH", anim = "", gear = "vest", -- the owner-added Model in assets/classAssets
			c0 = Color3.fromRGB(29, 61, 82), c1 = Color3.fromRGB(58, 132, 178) },
		{ id = "runner", emoji = "👟", name = "RUNNER", line = "+15% MOVE SPEED · APPLIES NEXT RUN",
			perk = "+15% MOVE SPEED", anim = "", gear = "",
			c0 = Color3.fromRGB(38, 74, 20), c1 = Color3.fromRGB(96, 168, 40) },
		{ id = "scavenger", emoji = "🪙", name = "SCAVENGER", line = "+25% RUN COINS · APPLIES NEXT RUN",
			perk = "+25% RUN COINS", anim = "", gear = "",
			c0 = Color3.fromRGB(120, 88, 18), c1 = Color3.fromRGB(206, 158, 52) },
	}
	local HIDE_GUIS = { "LobbyHUD", "LobbyInventory", "LobbyXP", "LobbyQuests", "LobbySquad", "LobbyCoins",
		"LobbyShop", "LobbySettings", "LobbyDockFade" }

	local C = { open = false, sel = 1, equipped = "", rows = {}, movedCam = false } -- one table (local ceiling)

	C.gui = Instance.new("ScreenGui")
	C.gui.Name = "LobbyClassShowcase"
	C.gui.ResetOnSpawn = false
	C.gui.IgnoreGuiInset = true
	C.gui.DisplayOrder = 30
	C.gui.Enabled = false
	C.gui.Parent = playerGui
	lattach(C.gui)

	C.text = function(parent, str, size, colr)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = TITLE_FACE
		l.TextSize = size
		l.TextColor3 = colr or Color3.new(1, 1, 1)
		l.Text = str
		l.ZIndex = 6
		local st = Instance.new("UIStroke")
		st.Color = TBLACK
		st.Thickness = math.clamp(size / 8, 2, 3.5)
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Parent = l
		l.Parent = parent
		return l
	end

	-- screen title (top-left, orients the player); the panel carries its own header + red X
	do
		local t = C.text(C.gui, "CLASSES", 26)
		t.Position = UDim2.fromOffset(20, 16)
		t.Size = UDim2.fromOffset(240, 36)
		t.TextXAlignment = Enum.TextXAlignment.Left
	end

	-- THE LEFT PANEL — G watermark rows (each its own colour), red X, glow-pulse SELECT (J1)
	do
		local panel = Instance.new("Frame")
		panel.AnchorPoint = Vector2.new(0, 0.5)
		panel.Position = UDim2.new(0, 16, 0.5, 10)
		panel.Size = UDim2.fromOffset(330, 452)
		panel.BackgroundColor3 = Color3.fromRGB(14, 13, 10)
		panel.BackgroundTransparency = 0.08
		panel.BorderSizePixel = 0
		panel.Parent = C.gui
		corner(panel, 16)
		ledge(panel, TBLACK, 3)
		local t = C.text(panel, "PICK YOUR CLASS", 18)
		t.Position = UDim2.fromOffset(16, 12)
		t.Size = UDim2.new(1, -70, 0, 24)
		t.TextXAlignment = Enum.TextXAlignment.Left

		-- the chunky red X, exactly like every other panel
		local x = redX(panel, 40, 20)
		x.Position = UDim2.new(1, -8, 0, 8)
		x.ZIndex = 12
		x.Activated:Connect(function()
			lplay("Close")
			C.setOpen(false)
		end)

		C.list = Instance.new("ScrollingFrame") -- scrolls when more classes land later
		C.list.Position = UDim2.fromOffset(12, 48)
		C.list.Size = UDim2.new(1, -20, 1, -122)
		C.list.BackgroundTransparency = 1
		C.list.BorderSizePixel = 0
		C.list.ScrollBarThickness = 8 -- CHANGED: visible, so it reads as a scroll list for more classes
		C.list.ScrollBarImageColor3 = Color3.fromRGB(180, 186, 160)
		C.list.ScrollBarImageTransparency = 0.15
		C.list.ScrollingDirection = Enum.ScrollingDirection.Y
		C.list.CanvasSize = UDim2.new()
		C.list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		C.list.Parent = panel
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 9)
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Parent = C.list

		for i, e in ipairs(CLASSES) do
			local row = Instance.new("TextButton")
			row.LayoutOrder = i
			row.Size = UDim2.new(1, -6, 0, 68)
			row.BackgroundColor3 = Color3.new(1, 1, 1) -- white base; the gradient carries the class colour
			row.BorderSizePixel = 0
			row.AutoButtonColor = false
			row.ClipsDescendants = true -- the big watermark emoji bleeds inside the row
			row.Text = ""
			row.Parent = C.list
			corner(row, 14)
			local rg = Instance.new("UIGradient") -- horizontal dark→light class colour
			rg.Color = ColorSequence.new(e.c0, e.c1)
			rg.Rotation = 0
			rg.Parent = row
			local ring = ledge(row, TBLACK, 3)
			-- huge faded emblem watermark, top-right
			local wm = Instance.new("TextLabel")
			wm.AnchorPoint = Vector2.new(1, 0)
			wm.Position = UDim2.new(1, 8, 0, -14)
			wm.Size = UDim2.fromOffset(84, 84)
			wm.BackgroundTransparency = 1
			wm.FontFace = TITLE_FACE
			wm.TextSize = 76
			wm.Text = e.emoji
			wm.TextTransparency = 0.82
			wm.ZIndex = 2
			wm.Parent = row
			-- name + stat, on top
			local nm = C.text(row, e.name, 19)
			nm.Position = UDim2.fromOffset(15, 12)
			nm.Size = UDim2.new(1, -30, 0, 22)
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.ZIndex = 10 -- ABOVE the dim veil (8): the name/stat must stay readable on unselected rows
			local ln = Instance.new("TextLabel")
			ln.Position = UDim2.fromOffset(15, 37)
			ln.Size = UDim2.new(1, -30, 0, 18)
			ln.BackgroundTransparency = 1
			ln.FontFace = BODYB_FACE
			ln.TextSize = 13 -- CHANGED: bigger + white + thin stroke (was 10px near-bone, read black)
			ln.TextColor3 = Color3.new(1, 1, 1)
			ln.TextXAlignment = Enum.TextXAlignment.Left
			ln.TextTruncate = Enum.TextTruncate.AtEnd
			ln.Text = e.line
			ln.ZIndex = 10 -- ABOVE the dim veil (8) so the stat line never reads as blacked-out
			ln.Parent = row
			local lns = Instance.new("UIStroke")
			lns.Color = TBLACK
			lns.Thickness = 1
			lns.Transparency = 0.5
			lns.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			lns.Parent = ln
			-- EQUIPPED badge (shows on YOUR class), and the dim veil for un-selected rows
			local badge = C.text(row, "EQUIPPED", 9, Color3.fromRGB(210, 245, 190))
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, -10, 0, 8)
			badge.Size = UDim2.fromOffset(66, 18)
			badge.BackgroundTransparency = 0
			badge.BackgroundColor3 = Color3.fromRGB(13, 18, 6)
			badge.Visible = false
			badge.ZIndex = 12 -- above the raised name/stat (10) and the dim veil (8)
			do
				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(1, 0)
				bc.Parent = badge
				ledge(badge, Color3.fromRGB(191, 245, 138), 1.5, 0.5)
			end
			local dim = Instance.new("Frame") -- G's "unselected rows desaturate/darken"
			dim.Size = UDim2.fromScale(1, 1)
			dim.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
			dim.BackgroundTransparency = 0.5
			dim.BorderSizePixel = 0
			dim.ZIndex = 8
			dim.Parent = row
			local dc = Instance.new("UICorner")
			dc.CornerRadius = UDim.new(0, 14)
			dc.Parent = dim

			C.rows[i] = { row = row, ring = ring, badge = badge, dim = dim }
			row.Activated:Connect(function()
				lplay("Click")
				C.sel = i
				C.refresh()
			end)
		end

		-- J1 GLOW PULSE — a soft green aura BEHIND the SELECT button (stacked translucent frames), pulsing
		C.halo = Instance.new("Frame")
		C.halo.AnchorPoint = Vector2.new(0.5, 1)
		C.halo.Position = UDim2.new(0.5, 0, 1, -34)
		C.halo.Size = UDim2.new(1, -24, 0, 48)
		C.halo.BackgroundTransparency = 1
		C.halo.ZIndex = 1
		C.halo.Parent = panel
		for _, pad in { 5, 11, 18, 26 } do
			local g = Instance.new("Frame")
			g.AnchorPoint = Vector2.new(0.5, 0.5)
			g.Position = UDim2.fromScale(0.5, 0.5)
			g.Size = UDim2.new(1, pad * 2, 1, pad * 2)
			g.BackgroundColor3 = Color3.fromRGB(124, 219, 35)
			g.BackgroundTransparency = 0.5 + (pad / 26) * 0.42 -- fades outward
			g.BorderSizePixel = 0
			g.ZIndex = 1
			g.Parent = C.halo
			local gc = Instance.new("UICorner")
			gc.CornerRadius = UDim.new(0, 16)
			gc.Parent = g
		end
		local haloScale = Instance.new("UIScale")
		haloScale.Parent = C.halo
		TS:Create(haloScale, TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.06 }):Play() -- breathes forever (auto-loops); hidden when equipped

		C.selBtn = Instance.new("TextButton")
		C.selBtn.AnchorPoint = Vector2.new(0.5, 1)
		C.selBtn.Position = UDim2.new(0.5, 0, 1, -34)
		C.selBtn.Size = UDim2.new(1, -24, 0, 48)
		C.selBtn.BorderSizePixel = 0
		C.selBtn.AutoButtonColor = false
		C.selBtn.FontFace = TITLE_FACE
		C.selBtn.TextSize = 20
		C.selBtn.TextColor3 = Color3.new(1, 1, 1)
		C.selBtn.Text = "SELECT"
		C.selBtn.BackgroundColor3 = ACCENT
		C.selBtn.ZIndex = 3
		C.selBtn.Parent = panel
		corner(C.selBtn, 10)
		lbevel(C.selBtn) -- the shared slab/face 3D button (gradient + press) — matches every other CTA

		C.hint = Instance.new("TextLabel") -- shows only when the display character is missing
		C.hint.AnchorPoint = Vector2.new(0.5, 1)
		C.hint.Position = UDim2.new(0.5, 0, 1, -8)
		C.hint.Size = UDim2.new(1, -24, 0, 20)
		C.hint.BackgroundTransparency = 1
		C.hint.FontFace = BODYB_FACE
		C.hint.TextSize = 9
		C.hint.TextColor3 = ORANGE
		C.hint.Visible = false
		C.hint.Text = 'PLACE A MODEL NAMED "ClassCharacter" — THE CAMERA PANS TO IT'
		C.hint.ZIndex = 5
		C.hint.Parent = panel
		C.selBtn.Activated:Connect(function()
			local e = CLASSES[C.sel]
			if e.id == C.equipped then
				return
			end
			lplay("Equip")
			C.equipped = e.id -- optimistic; the server's StatsRemote echo confirms
			ClassEquipR:FireServer(e.id)
			C.refresh()
		end)
	end

	-- The OWNER-PLACED display character (nothing is spawned): a Model or Part named ClassCharacter /
	-- ClassStage anywhere in Workspace.
	local function findDisplay()
		for _, d in workspace:GetDescendants() do
			local n = d.Name:lower()
			if (n == "classcharacter" or n == "classstage") and (d:IsA("Model") or d:IsA("BasePart")) then
				return d
			end
		end
		return nil
	end

	-- ===== LIVE CHARACTER LOOK ===== (Pose + accessory + nameplate) — browsing a class transforms the
	-- owner-placed display character: a tinted floating nameplate (class + perk), an ambient aura, an
	-- OPTIONAL idle pose (e.anim assetid), and OPTIONAL gear (an Accessory or Model named e.gear inside a
	-- Folder named "ClassGear" in Workspace or ReplicatedStorage). Missing rig / anim / gear just skips
	-- that piece. All client-side (nothing replicates); rebuilt only when the selected class changes.
	-- Every local below lives INSIDE these functions, so the main-chunk 200-local ceiling is untouched.
	C.clearLook = function()
		if C.animTrack then
			pcall(function() C.animTrack:Stop(0.2) end)
			C.animTrack = nil
		end
		for _, k in { "gear", "aura", "plate" } do
			if C[k] then C[k]:Destroy(); C[k] = nil end
		end
		C.lastLook = nil
	end
	C.applyLook = function(e)
		local disp = findDisplay()
		if not disp then return end
		if C.lastLook == e.id then return end -- already showing this class — don't restart pose/aura
		C.lastLook = e.id
		local root, head, hum
		if disp:IsA("Model") then
			root = disp.PrimaryPart or disp:FindFirstChild("HumanoidRootPart")
				or disp:FindFirstChild("UpperTorso") or disp:FindFirstChild("Torso")
				or disp:FindFirstChildWhichIsA("BasePart")
			head = disp:FindFirstChild("Head") or root
			hum = disp:FindFirstChildOfClass("Humanoid")
		else
			root, head = disp, disp
		end
		-- NAMEPLATE (rebuilt each change so tint + text always match)
		if C.plate then C.plate:Destroy() end
		C.plate = nil
		if head then
			local bb = Instance.new("BillboardGui")
			bb.Name = "ClassPlate"; bb.Size = UDim2.fromOffset(260, 80)
			bb.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0); bb.AlwaysOnTop = true; bb.Parent = head
			local nm = Instance.new("TextLabel")
			nm.AnchorPoint = Vector2.new(0.5, 1); nm.Position = UDim2.fromScale(0.5, 0.64)
			nm.Size = UDim2.fromScale(1, 0.62); nm.BackgroundTransparency = 1
			nm.FontFace = TITLE_FACE; nm.TextSize = 30; nm.TextColor3 = Color3.new(1, 1, 1); nm.Text = e.name
			nm.Parent = bb
			local ns = Instance.new("UIStroke"); ns.Color = TBLACK; ns.Thickness = 3; ns.Parent = nm
			local pk = Instance.new("TextLabel")
			pk.AnchorPoint = Vector2.new(0.5, 0); pk.Position = UDim2.fromScale(0.5, 0.62)
			pk.Size = UDim2.fromScale(1, 0.34); pk.BackgroundTransparency = 1
			pk.FontFace = BODYB_FACE; pk.TextSize = 17; pk.TextColor3 = e.c1; pk.Text = e.perk or ""
			pk.Parent = bb
			local ps = Instance.new("UIStroke"); ps.Color = TBLACK; ps.Thickness = 2.5; ps.Parent = pk
			C.plate = bb
		end
		-- AMBIENT AURA (tinted particles) on the torso/root
		if C.aura then C.aura:Destroy() end
		C.aura = nil
		if root then
			local em = Instance.new("ParticleEmitter")
			em.Name = "ClassAura"; em.Color = ColorSequence.new(e.c1)
			em.Texture = "rbxasset://textures/particles/sparkles_main.dds" -- engine built-in (always loads)
			em.Lifetime = NumberRange.new(0.8, 1.5); em.Rate = 22; em.Speed = NumberRange.new(1.5, 3)
			em.SpreadAngle = Vector2.new(180, 180); em.LightEmission = 0.6; em.Rotation = NumberRange.new(0, 360)
			em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
			em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
			em.Parent = root
			C.aura = em
		end
		-- IDLE POSE (optional — needs a Humanoid rig + an anim id)
		if C.animTrack then pcall(function() C.animTrack:Stop(0.2) end); C.animTrack = nil end
		if hum and e.anim and e.anim ~= "" then
			local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator")
			animator.Parent = hum
			local anim = Instance.new("Animation")
			anim.AnimationId = "rbxassetid://" .. tostring(e.anim)
			local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
			if ok and track then
				track.Looped = true; track.Priority = Enum.AnimationPriority.Action
				track:Play(0.25); C.animTrack = track
			end
		end
		-- GEAR (optional — an Accessory auto-welds via the Humanoid; a Model welds to the root)
		if C.gear then C.gear:Destroy() end
		C.gear = nil
		if disp:IsA("Model") and e.gear and e.gear ~= "" then
			local RS = game:GetService("ReplicatedStorage")
			local src
			-- primary: the owner's ReplicatedStorage/assets/classAssets folder (holds the vest Model)
			local assets = RS:FindFirstChild("assets")
			local ca = assets and assets:FindFirstChild("classAssets")
			if ca then
				src = ca:FindFirstChild(e.gear)
			end
			if not src then -- fallback: a "ClassGear" folder in Workspace or ReplicatedStorage
				for _, where in { workspace, RS } do
					local folder = where:FindFirstChild("ClassGear")
					if folder then
						src = folder:FindFirstChild(e.gear)
						if src then break end
					end
				end
			end
			if src then
				local clone = src:Clone()
				if clone:IsA("Accessory") and hum then
					pcall(function() hum:AddAccessory(clone) end)
					C.gear = clone
				elseif root and clone:IsA("Model") then
					local cp = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
					if cp then
						clone:PivotTo(root.CFrame)
						for _, part in clone:GetDescendants() do
							if part:IsA("BasePart") then part.Anchored = false; part.CanCollide = false end
						end
						local w = Instance.new("Weld")
						w.Part0 = root; w.Part1 = cp; w.C0 = root.CFrame:ToObjectSpace(cp.CFrame); w.Parent = cp
						clone.Parent = disp
						C.gear = clone
					end
				end
			end
		end
	end

	C.refresh = function()
		local e = CLASSES[C.sel]
		for i, r in C.rows do
			local seld = (i == C.sel)
			r.ring.Color = seld and Color3.new(1, 1, 1) or TBLACK -- selected row gets the white ring (G)
			r.ring.Thickness = seld and 3.5 or 3
			r.dim.Visible = not seld -- only your selection stays full-colour; the rest darken
			r.badge.Visible = (CLASSES[i].id == C.equipped)
		end
		-- SELECT button + its glow: green CTA when it's not yours, dark "EQUIPPED" (no glow) when it is.
		if e.id == C.equipped then
			C.selBtn.BackgroundColor3 = Color3.fromRGB(56, 92, 34) -- clearer green (near-black read as dead)
			C.selBtn.Text = "EQUIPPED ✓"
			C.selBtn.TextColor3 = Color3.new(1, 1, 1) -- WHITE: green text read as black under the fat stroke
			C.halo.Visible = false
		else
			C.selBtn.BackgroundColor3 = ACCENT
			C.selBtn.Text = "SELECT " .. e.name
			C.selBtn.TextColor3 = Color3.new(1, 1, 1)
			C.halo.Visible = true
		end
		if C.open then
			C.applyLook(e) -- transform the display character to the class you're viewing
		end
	end

	C.setOpen = function(on)
		if C.open == on then
			return
		end
		local cam = workspace.CurrentCamera
		-- CHANGED (camera-desync guard): every transition gets a fresh token; a close tween that finishes
		-- AFTER a re-open won't yank the camera back to Custom (rapid close->reopen used to strand it).
		C.gen = (C.gen or 0) + 1
		local myGen = C.gen
		if C.camTween then
			C.camTween:Cancel() -- never let two camera tweens fight
			C.camTween = nil
		end
		if on then
			C.open = true
			lplay("Open")
			local disp = findDisplay()
			C.hint.Visible = (disp == nil)
			if disp and cam then
				-- frame THEIR character: front of its pivot, distance from its size
				local cf, size
				if disp:IsA("Model") then
					cf, size = disp:GetBoundingBox()
				else
					cf, size = disp.CFrame, disp.Size
				end
				local dist = math.max(size.X, size.Y, size.Z) * 1.35 + 4
				local camPos = cf.Position + cf.LookVector * dist + Vector3.new(0, size.Y * 0.18 + 1, 0)
				if C.savedCamCF == nil then -- only capture HOME once (a reopen mid-restore must not save a scriptable CF)
					C.savedCamCF = cam.CFrame
				end
				C.movedCam = true
				cam.CameraType = Enum.CameraType.Scriptable
				C.camTween = TS:Create(cam, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ CFrame = CFrame.lookAt(camPos, cf.Position + Vector3.new(0, size.Y * 0.05, 0)) })
				C.camTween:Play()
			end
			for _, n in HIDE_GUIS do
				local g = playerGui:FindFirstChild(n)
				if g then
					g.Enabled = false
				end
			end
			C.gui.Enabled = true
			C.refresh()
		else
			C.open = false
			lplay("Close")
			C.clearLook() -- strip the nameplate / aura / pose / gear off the display character
			C.gui.Enabled = false
			for _, n in HIDE_GUIS do
				local g = playerGui:FindFirstChild(n)
				if g then
					g.Enabled = true
				end
			end
			if cam and C.movedCam then
				C.camTween = TS:Create(cam, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ CFrame = C.savedCamCF or cam.CFrame })
				C.camTween.Completed:Once(function()
					if myGen == C.gen and not C.open then -- still the latest close → safe to hand control back
						cam.CameraType = Enum.CameraType.Custom
						C.movedCam = false
						C.savedCamCF = nil
					end
				end)
				C.camTween:Play()
			end
		end
	end

	dockBtns.classes.Activated:Connect(function()
		lplay("Click")
		C.setOpen(not C.open)
	end)
	-- A respawn/reset while the showcase is open must never strand the camera in Scriptable.
	localPlayer.CharacterAdded:Connect(function()
		if not C.open then
			return
		end
		C.open = false
		C.clearLook() -- strip the class look off the display character on respawn
		C.gen = (C.gen or 0) + 1
		if C.camTween then
			C.camTween:Cancel()
			C.camTween = nil
		end
		local cam = workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Custom -- let Roblox re-attach to the fresh character
		end
		C.movedCam = false
		C.savedCamCF = nil
		C.gui.Enabled = false
		for _, n in HIDE_GUIS do
			local g = playerGui:FindFirstChild(n)
			if g then
				g.Enabled = true
			end
		end
	end)
	StatsRemote.OnClientEvent:Connect(function(s)
		if typeof(s) == "table" and typeof(s.class) == "string" then
			C.equipped = s.class
			for i, e in ipairs(CLASSES) do
				if e.id == C.equipped then
					C.sel = i -- open on your equipped class
				end
			end
			if C.open then
				C.refresh()
			end
		end
	end)
end


-- =====================================================================================================
-- ===== GLOBAL BEST-WAVE LEADERBOARD (world board) ===== renders the server's LeaderboardSync onto a
-- SurfaceGui on a part/model named "Leaderboard" you place in the lobby (tag-driven, like the rest of
-- the map). No board placed = nothing renders (no error). Top 3 get gold/silver/bronze; your own
-- best + rank shows in the footer.
-- =====================================================================================================
do
	local LeaderboardSync = remotes:WaitForChild("LeaderboardSync")
	local MEDAL = { Color3.fromRGB(255, 213, 92), Color3.fromRGB(206, 212, 222), Color3.fromRGB(205, 140, 74) }
	local L = { rows = {}, built = false }

	local function findBoard()
		for _, d in workspace:GetDescendants() do
			if d.Name:lower() == "leaderboard" then
				if d:IsA("BasePart") then
					return d
				elseif d:IsA("Model") and d.PrimaryPart then
					return d.PrimaryPart
				end
			end
		end
		return nil
	end

	local function build(part)
		if L.built then
			return
		end
		L.built = true
		local sg = Instance.new("SurfaceGui")
		sg.Name = "LeaderboardGui"
		sg.Face = Enum.NormalId.Front
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 48
		sg.CanvasSize = Vector2.new(560, 780)
		sg.LightInfluence = 0
		sg.Adornee = part
		sg.Parent = part
		local bg = Instance.new("Frame")
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.fromRGB(14, 13, 10)
		bg.BorderSizePixel = 0
		bg.Parent = sg
		ldepth(bg)
		local title = Instance.new("TextLabel")
		title.Position = UDim2.fromOffset(0, 14); title.Size = UDim2.new(1, 0, 0, 48)
		title.BackgroundTransparency = 1; title.FontFace = TITLE_FACE; title.TextSize = 34
		title.TextColor3 = GOLD; title.Text = "TOP SURVIVORS"; title.Parent = bg
		local st = Instance.new("UIStroke"); st.Color = TBLACK; st.Thickness = 3; st.Parent = title
		local sub = Instance.new("TextLabel")
		sub.Position = UDim2.fromOffset(0, 58); sub.Size = UDim2.new(1, 0, 0, 22)
		sub.BackgroundTransparency = 1; sub.FontFace = BODYB_FACE; sub.TextSize = 15
		sub.TextColor3 = DIMTEXT; sub.Text = "HIGHEST WAVE REACHED · GLOBAL"; sub.Parent = bg
		L.list = Instance.new("Frame")
		L.list.Position = UDim2.fromOffset(16, 92); L.list.Size = UDim2.new(1, -32, 1, -150)
		L.list.BackgroundTransparency = 1; L.list.Parent = bg
		local ll = Instance.new("UIListLayout"); ll.Padding = UDim.new(0, 4); ll.Parent = L.list
		L.foot = Instance.new("TextLabel")
		L.foot.AnchorPoint = Vector2.new(0.5, 1); L.foot.Position = UDim2.new(0.5, 0, 1, -14)
		L.foot.Size = UDim2.new(1, -32, 0, 40); L.foot.BackgroundColor3 = Color3.fromRGB(28, 31, 22)
		L.foot.BorderSizePixel = 0; L.foot.FontFace = TITLE_FACE; L.foot.TextSize = 20
		L.foot.TextColor3 = ACCENT; L.foot.Text = "YOU: —"; L.foot.Parent = bg
		corner(L.foot, 8); ledge(L.foot, TBLACK, 2.5)
		local fs = Instance.new("UIStroke"); fs.Color = TBLACK; fs.Thickness = 2
		fs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; fs.Parent = L.foot
	end

	local function render(data)
		if not L.list then
			return
		end
		for _, c in L.list:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local top = (typeof(data.top) == "table") and data.top or {}
		if #top == 0 then
			local empty = Instance.new("TextLabel")
			empty.Size = UDim2.new(1, 0, 0, 40); empty.BackgroundTransparency = 1
			empty.FontFace = BODYB_FACE; empty.TextSize = 16; empty.TextColor3 = DIMTEXT
			empty.Text = "NO RUNS YET — BE THE FIRST!"; empty.Parent = L.list
			-- (a bare label in a Frame-only clear: wrap it so the clear loop above skips it next time)
			local holder = Instance.new("Frame"); holder.Size = UDim2.new(1, 0, 0, 40)
			holder.BackgroundTransparency = 1; holder.Parent = L.list
			empty.Parent = holder
		end
		for _, e in ipairs(top) do
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 26); row.BorderSizePixel = 0
			row.BackgroundColor3 = (e.rank <= 3) and Color3.fromRGB(34, 33, 24) or Color3.fromRGB(24, 25, 18)
			row.Parent = L.list
			corner(row, 5)
			local medal = MEDAL[e.rank]
			local rk = Instance.new("TextLabel")
			rk.Position = UDim2.fromOffset(8, 0); rk.Size = UDim2.fromOffset(44, 26); rk.BackgroundTransparency = 1
			rk.FontFace = TITLE_FACE; rk.TextSize = 16; rk.TextXAlignment = Enum.TextXAlignment.Left
			rk.TextColor3 = medal or DIMTEXT; rk.Text = "#" .. e.rank; rk.Parent = row
			local nm = Instance.new("TextLabel")
			nm.Position = UDim2.fromOffset(56, 0); nm.Size = UDim2.new(1, -150, 1, 0); nm.BackgroundTransparency = 1
			nm.FontFace = BODYB_FACE; nm.TextSize = 15; nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.TextTruncate = Enum.TextTruncate.AtEnd; nm.TextColor3 = medal or TEXTCOL
			nm.Text = tostring(e.name or "?"); nm.Parent = row
			local wv = Instance.new("TextLabel")
			wv.AnchorPoint = Vector2.new(1, 0); wv.Position = UDim2.new(1, -10, 0, 0); wv.Size = UDim2.fromOffset(96, 26)
			wv.BackgroundTransparency = 1; wv.FontFace = TITLE_FACE; wv.TextSize = 16
			wv.TextXAlignment = Enum.TextXAlignment.Right; wv.TextColor3 = medal or ACCENT
			wv.Text = "WAVE " .. tostring(e.wave or 0); wv.Parent = row
		end
		if L.foot then
			local you = data.you or {}
			if (you.wave or 0) <= 0 then
				L.foot.Text = "YOU: NO RUN YET"
			elseif you.rank then
				L.foot.Text = ("YOU: WAVE %d  ·  RANK #%d"):format(you.wave, you.rank)
			else
				L.foot.Text = ("YOU: WAVE %d  ·  OUTSIDE TOP %d"):format(you.wave, #top > 0 and #top or 25)
			end
		end
	end

	LeaderboardSync.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then
			return
		end
		local part = findBoard()
		if part then
			build(part)
			render(data)
		end
	end)
	-- pull on startup, then keep it fresh
	task.spawn(function()
		for _ = 1, 10 do -- give a streamed-in board a chance to appear
			LeaderboardSync:FireServer()
			if L.built then
				break
			end
			task.wait(3)
		end
		while true do
			task.wait(60)
			LeaderboardSync:FireServer()
		end
	end)
end

-- (Removed per owner request: the end-of-run summary card — "Run over — Wave N · K kills · +Coins".
-- Coins/best-wave are still banked server-side on return; we just no longer surface the stats card.)

-- =====================================================================================================
-- ===== SETTINGS (volume sliders — persists via settings.vol, shared with the game place) =============
-- =====================================================================================================
do
	local setGui = Instance.new("ScreenGui")
	setGui.Name = "LobbySettings"; setGui.ResetOnSpawn = false; setGui.IgnoreGuiInset = true; setGui.DisplayOrder = 14
	setGui.Parent = playerGui
	lattach(setGui)

	-- CHANGED: the dock's Settings button IS the toggle now (the floating corner gear is gone).
	local gear = dockBtns.settings

	-- CHANGED: dead-center chrome panel (the same modern header-bar assembly as WEAPONS/the shop)
	-- instead of the old bottom-right card.
	local sRoot, sPanel, _, sClose = chromePanel(setGui, 460, 316, LC.HEADER_COLORS.settings, "SETTINGS")
	sPanel.Visible = false
	sPanel:GetPropertyChangedSignal("Visible"):Connect(function()
		sRoot.Visible = sPanel.Visible
	end)

	local function sliderRow(y, labelText, get, set)
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromOffset(24, y); label.Size = UDim2.fromOffset(120, 18); label.BackgroundTransparency = 1
		label.FontFace = BODYB_FACE; label.TextSize = 15; label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = DIMTEXT; label.Text = labelText; label.Parent = sPanel

		local pct = Instance.new("TextLabel")
		pct.AnchorPoint = Vector2.new(1, 0); pct.Position = UDim2.new(1, -24, 0, y); pct.Size = UDim2.fromOffset(60, 18)
		pct.BackgroundTransparency = 1; pct.FontFace = BODYB_FACE; pct.TextSize = 15
		pct.TextXAlignment = Enum.TextXAlignment.Right; pct.TextColor3 = TEXTCOL; pct.Parent = sPanel

		local track = Instance.new("TextButton")
		track.Position = UDim2.fromOffset(24, y + 24); track.Size = UDim2.new(1, -48, 0, 14)
		track.BackgroundColor3 = TRACK; track.BorderSizePixel = 0; track.Text = ""; track.AutoButtonColor = false
		track:SetAttribute("NoClickSound", true); track.Parent = sPanel
		corner(track, 7); ledge(track, TBLACK, 1.5)

		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = ACCENT; fill.BorderSizePixel = 0; fill.Parent = track; corner(fill, 7)
		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0.5, 0.5); knob.Size = UDim2.fromOffset(20, 20)
		knob.BackgroundColor3 = TEXTCOL; knob.BorderSizePixel = 0; knob.ZIndex = 2; knob.Parent = track
		corner(knob, 10); ledge(knob, TBLACK, 2)

		local function render()
			local v = get()
			fill.Size = UDim2.new(v, 0, 1, 0)
			knob.Position = UDim2.new(v, 0, 0.5, 0)
			pct.Text = math.floor(v * 100 + 0.5) .. "%"
		end

		local dragging = false
		local function applyFromX(x)
			local v = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			LC.volTouched = true
			set(v)
			applySoundVol()
			render()
			queueVolSave()
		end
		track.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				applyFromX(input.Position.X)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				applyFromX(input.Position.X)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
		return render
	end

	-- On/off pill toggle (label + a sliding switch). get()/set(bool).
	local function toggleRow(y, labelText, get, set)
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromOffset(24, y); label.Size = UDim2.fromOffset(180, 26); label.BackgroundTransparency = 1
		label.FontFace = BODYB_FACE; label.TextSize = 15; label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = DIMTEXT; label.Text = labelText; label.Parent = sPanel

		local sw = Instance.new("TextButton")
		sw.AnchorPoint = Vector2.new(1, 0.5); sw.Position = UDim2.new(1, -24, 0, y + 13); sw.Size = UDim2.fromOffset(64, 30)
		sw.BorderSizePixel = 0; sw.Text = ""; sw.AutoButtonColor = false
		sw:SetAttribute("NoClickSound", true); sw.Parent = sPanel
		corner(sw, 15); ledge(sw, TBLACK, 2)

		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0.5, 0.5); knob.Size = UDim2.fromOffset(24, 24)
		knob.BackgroundColor3 = TEXTCOL; knob.BorderSizePixel = 0; knob.Parent = sw
		corner(knob, 12); ledge(knob, TBLACK, 1.5)

		local function paint()
			local on = get()
			sw.BackgroundColor3 = on and ACCENT or TRACK
			knob.Position = on and UDim2.new(1, -15, 0.5, 0) or UDim2.new(0, 15, 0.5, 0)
		end
		sw.Activated:Connect(function()
			set(not get()); paint()
		end)
		paint()
		return paint
	end

	local SetShake = remotes:WaitForChild("SetShake")
	local renders = { -- CHANGED: ys retuned for the chrome body (no in-panel header anymore)
		sliderRow(34, "MASTER", function() return volMaster end, function(v) volMaster = v end),
		sliderRow(100, "MUSIC", function() return volMusic end, function(v) volMusic = v end),
		sliderRow(166, "SFX", function() return volSfx end, function(v) volSfx = v end),
		toggleRow(232, "CAMERA SHAKE", function()
			return localPlayer:GetAttribute("ShakeOff") ~= true
		end, function(v)
			localPlayer:SetAttribute("ShakeOff", not v)
			SetShake:FireServer(v)
		end),
	}
	local function renderAll()
		for _, r in renders do r() end
	end

	-- (The XP bar lives bottom-LEFT now — no more collision with this panel; keep as a no-op hook.)
	local function syncXpBar() end
	gear.Activated:Connect(function()
		sPanel.Visible = not sPanel.Visible
		if sPanel.Visible then renderAll(); uiFocusOpen() else uiFocusClose() end
		syncXpBar()
	end)
	sClose.Activated:Connect(function()
		if sPanel.Visible then uiFocusClose() end
		sPanel.Visible = false
		syncXpBar()
	end)
	task.delay(3, renderAll) -- saved volumes arrive async via Stats
end

-- ===== SQUAD (top-center avatar party) ===== circular avatar-headshot chips for you + your buddies,
-- a "+" chip to invite (avatar picker), a red ✕ to leave, crown on the leader. Accepting an invite
-- happens on a top-center card. When the leader locks in a run on a pad, the server summons everyone.
-- =====================================================================================================
do
	local SquadSyncR = remotes:WaitForChild("SquadSync")
	local SquadInviteR = remotes:WaitForChild("SquadInvite")
	local SquadRespondR = remotes:WaitForChild("SquadRespond")
	local SquadLeaveR = remotes:WaitForChild("SquadLeave")
	local TS = game:GetService("TweenService")

	local P = { members = {} } -- one table (200-local ceiling)

	P.gui = Instance.new("ScreenGui")
	P.gui.Name = "LobbySquad"
	P.gui.ResetOnSpawn = false
	P.gui.IgnoreGuiInset = true
	P.gui.DisplayOrder = 13
	P.gui.Parent = playerGui
	lattach(P.gui)

	P.text = function(parent, str, size, colr)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = TITLE_FACE
		l.TextSize = size
		l.TextColor3 = colr or Color3.new(1, 1, 1)
		l.Text = str
		l.ZIndex = 6
		local st = Instance.new("UIStroke")
		st.Color = TBLACK
		st.Thickness = math.clamp(size / 8, 2, 3)
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Parent = l
		l.Parent = parent
		return l
	end

	P.row = Instance.new("Frame") -- the chips row, top-center
	P.row.AnchorPoint = Vector2.new(0.5, 0)
	P.row.Position = UDim2.new(0.5, 0, 0, 10)
	P.row.Size = UDim2.fromOffset(0, 66)
	P.row.AutomaticSize = Enum.AutomaticSize.X
	P.row.BackgroundTransparency = 1
	P.row.Parent = P.gui
	do
		local ll = Instance.new("UIListLayout")
		ll.FillDirection = Enum.FillDirection.Horizontal
		ll.VerticalAlignment = Enum.VerticalAlignment.Top
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Padding = UDim.new(0, 10)
		ll.Parent = P.row
	end

	P.msgLbl = P.text(P.gui, "", 13, Color3.fromRGB(255, 213, 122)) -- little status line under the row
	P.msgLbl.AnchorPoint = Vector2.new(0.5, 0)
	P.msgLbl.Position = UDim2.new(0.5, 0, 0, 78)
	P.msgLbl.Size = UDim2.fromOffset(500, 18)
	P.msg = function(t)
		P.msgLbl.Text = t
		local my = os.clock()
		P.msgAt = my
		task.delay(3.5, function()
			if P.msgAt == my then
				P.msgLbl.Text = ""
			end
		end)
	end

	-- One circular chip: avatar headshot (or a drawn glyph), rim, optional crown, name underneath.
	local function chipBase(glyph, uid, rimColor)
		local holder = Instance.new("Frame")
		holder.Size = UDim2.fromOffset(52, 66)
		holder.BackgroundTransparency = 1
		holder.Parent = P.row
		local circ = Instance.new("ImageButton")
		circ.AnchorPoint = Vector2.new(0.5, 0)
		circ.Position = UDim2.new(0.5, 0, 0, 0)
		circ.Size = UDim2.fromOffset(48, 48)
		circ.BackgroundColor3 = Color3.new(1, 1, 1)
		circ.BorderSizePixel = 0
		circ.ZIndex = 5
		circ.Parent = holder
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(1, 0)
		cc.Parent = circ
		local cg = Instance.new("UIGradient") -- dark glass base (same as the dock)
		cg.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(52, 55, 64)),
			ColorSequenceKeypoint.new(0.35, Color3.fromRGB(26, 27, 33)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 14, 18)),
		})
		cg.Rotation = 90
		cg.Parent = circ
		ledge(circ, rimColor or Color3.new(1, 1, 1), 1.6, rimColor and 0.1 or 0.75)
		if uid then
			local img = Instance.new("ImageLabel")
			img.Size = UDim2.fromScale(1, 1)
			img.BackgroundTransparency = 1
			img.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(uid)
			img.ZIndex = 6
			img.Parent = circ
			local ic = Instance.new("UICorner")
			ic.CornerRadius = UDim.new(1, 0)
			ic.Parent = img
		elseif glyph then
			local g = P.text(circ, glyph, 22)
			g.Size = UDim2.fromScale(1, 1)
			g.ZIndex = 6
		end
		-- pop-in + hover juice
		local sc = Instance.new("UIScale")
		sc.Scale = 0.6
		sc.Parent = holder
		TS:Create(sc, TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		circ.MouseEnter:Connect(function()
			TS:Create(sc, TweenInfo.new(0.09), { Scale = 1.08 }):Play()
		end)
		circ.MouseLeave:Connect(function()
			TS:Create(sc, TweenInfo.new(0.09), { Scale = 1 }):Play()
		end)
		return holder, circ
	end

	-- The invite PICKER (who's in the server, not already squadded with me).
	P.picker = Instance.new("Frame")
	P.picker.AnchorPoint = Vector2.new(0.5, 0)
	P.picker.Position = UDim2.new(0.5, 0, 0, 84)
	P.picker.Size = UDim2.fromOffset(280, 250)
	P.picker.BackgroundColor3 = Color3.fromRGB(14, 13, 10)
	P.picker.BackgroundTransparency = 0.05
	P.picker.BorderSizePixel = 0
	P.picker.Visible = false
	P.picker.ZIndex = 20
	P.picker.Parent = P.gui
	corner(P.picker, 12)
	ledge(P.picker, TBLACK, 3)
	do
		local t = P.text(P.picker, "INVITE TO SQUAD", 16)
		t.Position = UDim2.fromOffset(0, 8)
		t.Size = UDim2.new(1, 0, 0, 22)
		t.ZIndex = 21
		P.pickList = Instance.new("ScrollingFrame")
		P.pickList.Position = UDim2.fromOffset(12, 38)
		P.pickList.Size = UDim2.new(1, -24, 1, -50)
		P.pickList.BackgroundTransparency = 1
		P.pickList.BorderSizePixel = 0
		P.pickList.ScrollBarThickness = 5
		P.pickList.CanvasSize = UDim2.new()
		P.pickList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		P.pickList.ZIndex = 21
		P.pickList.Parent = P.picker
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 6)
		ll.Parent = P.pickList
	end
	P.openPicker = function()
		clearChildren(P.pickList)
		local inSquad = {}
		for _, m in P.members do
			inSquad[m.id] = true
		end
		local others = 0
		for _, plr in Players:GetPlayers() do
			if plr ~= localPlayer and not inSquad[plr.UserId] then
				others += 1
				local row = Instance.new("TextButton")
				row.Size = UDim2.new(1, -6, 0, 44)
				row.BackgroundColor3 = darker(PANEL2, 0.2)
				row.BorderSizePixel = 0
				row.Text = ""
				row.ZIndex = 21
				row.Parent = P.pickList
				corner(row, 8)
				ledge(row, TBLACK, 2)
				local av = Instance.new("ImageLabel")
				av.Position = UDim2.fromOffset(4, 4)
				av.Size = UDim2.fromOffset(36, 36)
				av.BackgroundColor3 = Color3.fromRGB(26, 27, 33)
				av.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(plr.UserId)
				av.ZIndex = 22
				av.Parent = row
				local ac = Instance.new("UICorner")
				ac.CornerRadius = UDim.new(1, 0)
				ac.Parent = av
				local nm = P.text(row, plr.DisplayName or plr.Name, 14)
				nm.Position = UDim2.fromOffset(48, 0)
				nm.Size = UDim2.new(1, -56, 1, 0)
				nm.TextXAlignment = Enum.TextXAlignment.Left
				nm.ZIndex = 22
				row.Activated:Connect(function()
					P.picker.Visible = false
					SquadInviteR:FireServer(plr.UserId)
				end)
			end
		end
		if others == 0 then
			P.msg("NO ONE ELSE HERE — INVITE A FRIEND TO THE GAME!")
			return
		end
		P.picker.Visible = true
	end

	-- The incoming-invite CARD.
	P.invite = Instance.new("Frame")
	P.invite.AnchorPoint = Vector2.new(0.5, 0)
	P.invite.Position = UDim2.new(0.5, 0, 0, -110)
	P.invite.Size = UDim2.fromOffset(320, 96)
	P.invite.BackgroundColor3 = Color3.fromRGB(14, 13, 10)
	P.invite.BackgroundTransparency = 0.05
	P.invite.BorderSizePixel = 0
	P.invite.ZIndex = 30
	P.invite.Parent = P.gui
	corner(P.invite, 12)
	ledge(P.invite, TBLACK, 3)
	ledge(P.invite, ACCENT, 1.5, 0.5)
	do
		P.invAv = Instance.new("ImageLabel")
		P.invAv.Position = UDim2.fromOffset(10, 10)
		P.invAv.Size = UDim2.fromOffset(44, 44)
		P.invAv.BackgroundColor3 = Color3.fromRGB(26, 27, 33)
		P.invAv.ZIndex = 31
		P.invAv.Parent = P.invite
		local ac = Instance.new("UICorner")
		ac.CornerRadius = UDim.new(1, 0)
		ac.Parent = P.invAv
		P.invLbl = P.text(P.invite, "", 14)
		P.invLbl.Position = UDim2.fromOffset(64, 10)
		P.invLbl.Size = UDim2.new(1, -74, 0, 44)
		P.invLbl.TextXAlignment = Enum.TextXAlignment.Left
		P.invLbl.TextWrapped = true
		P.invLbl.ZIndex = 31
		local acc = Instance.new("TextButton")
		acc.Position = UDim2.fromOffset(10, 60)
		acc.Size = UDim2.new(0.5, -15, 0, 28)
		acc.BorderSizePixel = 0
		acc.AutoButtonColor = true
		acc.Text = ""
		acc.ZIndex = 31
		acc.Parent = P.invite
		corner(acc, 8)
		acc.BackgroundColor3 = Color3.new(1, 1, 1)
		local ag = Instance.new("UIGradient")
		ag.Color = ColorSequence.new(Color3.fromRGB(198, 247, 122), Color3.fromRGB(71, 138, 22))
		ag.Rotation = 90
		ag.Parent = acc
		ledge(acc, TBLACK, 2.5)
		local al = P.text(acc, "ACCEPT", 14)
		al.Size = UDim2.fromScale(1, 1)
		al.ZIndex = 32
		local dec = Instance.new("TextButton")
		dec.AnchorPoint = Vector2.new(1, 0)
		dec.Position = UDim2.new(1, -10, 0, 60)
		dec.Size = UDim2.new(0.5, -15, 0, 28)
		dec.BackgroundColor3 = TRACK
		dec.BorderSizePixel = 0
		dec.AutoButtonColor = true
		dec.Text = ""
		dec.ZIndex = 31
		dec.Parent = P.invite
		corner(dec, 8)
		ledge(dec, TBLACK, 2.5)
		local dl = P.text(dec, "DECLINE", 14)
		dl.Size = UDim2.fromScale(1, 1)
		dl.ZIndex = 32
		P.hideInvite = function()
			TS:Create(P.invite, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 0, 0, -110) }):Play()
		end
		acc.Activated:Connect(function()
			lplay("Equip")
			SquadRespondR:FireServer(true)
			P.hideInvite()
		end)
		dec.Activated:Connect(function()
			lplay("Click")
			SquadRespondR:FireServer(false)
			P.hideInvite()
		end)
	end
	P.showInvite = function(inv)
		P.invAv.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(tonumber(inv.id) or 0)
		P.invLbl.Text = tostring(inv.name or "?"):upper() .. " WANTS TO PARTY UP"
		lplay("Open")
		TS:Create(P.invite, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 0, 0, 12) }):Play()
		local my = os.clock()
		P.invAt = my
		task.delay(30, function()
			if P.invAt == my then
				P.hideInvite()
			end
		end)
	end

	P.render = function()
		for _, c in P.row:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local n = #P.members
		if n == 0 then -- solo: YOUR avatar chip + the "party up" invite chip beside it
			local meHolder = chipBase(nil, localPlayer.UserId)
			meHolder.LayoutOrder = 1
			local meNm = P.text(meHolder, localPlayer.DisplayName or localPlayer.Name, 11)
			meNm.AnchorPoint = Vector2.new(0.5, 1)
			meNm.Position = UDim2.new(0.5, 0, 1, 0)
			meNm.Size = UDim2.fromOffset(64, 14)
			meNm.TextTruncate = Enum.TextTruncate.AtEnd
			local holder, circ = chipBase("+", nil)
			holder.LayoutOrder = 2
			local nm = P.text(holder, "Party", 11)
			nm.AnchorPoint = Vector2.new(0.5, 1)
			nm.Position = UDim2.new(0.5, 0, 1, 0)
			nm.Size = UDim2.fromOffset(60, 14)
			circ.Activated:Connect(function()
				lplay("Click")
				if P.picker.Visible then
					P.picker.Visible = false
				else
					P.openPicker()
				end
			end)
			return
		end
		local meLeader = false
		for i, m in ipairs(P.members) do
			if m.leader and m.id == localPlayer.UserId then
				meLeader = true
			end
			local holder = chipBase(nil, m.id, m.leader and GOLD or nil)
			holder.LayoutOrder = 10 + i
			if m.leader then
				local crown = P.text(holder, "👑", 14)
				crown.AnchorPoint = Vector2.new(1, 0)
				crown.Position = UDim2.new(1, 4, 0, -8)
				crown.Size = UDim2.fromOffset(20, 18)
				crown.ZIndex = 7
			end
			local nm = P.text(holder, m.name or "?", 11)
			nm.AnchorPoint = Vector2.new(0.5, 1)
			nm.Position = UDim2.new(0.5, 0, 1, 0)
			nm.Size = UDim2.fromOffset(64, 14)
			nm.TextTruncate = Enum.TextTruncate.AtEnd
		end
		if meLeader and n < 4 then -- leader can add more
			local holder, circ = chipBase("+", nil)
			holder.LayoutOrder = 90
			circ.Activated:Connect(function()
				lplay("Click")
				if P.picker.Visible then
					P.picker.Visible = false
				else
					P.openPicker()
				end
			end)
		end
		do -- leave chip (everyone)
			local holder, circ = chipBase("✕", nil)
			holder.LayoutOrder = 99
			circ.Size = UDim2.fromOffset(34, 34)
			circ.Position = UDim2.new(0.5, 0, 0, 7)
			local rim = nil
			for _, d in circ:GetChildren() do
				if d:IsA("UIStroke") then
					rim = d
				end
			end
			if rim then
				rim.Color = Color3.fromRGB(224, 60, 44)
				rim.Transparency = 0.2
			end
			circ.Activated:Connect(function()
				lplay("Close")
				SquadLeaveR:FireServer()
			end)
		end
	end
	P.render()

	SquadSyncR.OnClientEvent:Connect(function(d)
		if typeof(d) ~= "table" then
			return
		end
		if typeof(d.members) == "table" then
			P.members = d.members
			P.picker.Visible = false
			P.render()
		end
		if typeof(d.invite) == "table" then
			P.showInvite(d.invite)
		end
		if d.msg then
			P.msg(tostring(d.msg))
		end
	end)
end

-- ===== DAILY QUESTS (edge tab → stamp card) ===== the slim QUESTS rail hugging the left edge with
-- the green ▶ arrow (the picked mock's toggle); clicking it slides the STAMP CARD plate out — green
-- spine, one dark capsule per quest (gold ring + CLAIM when finished), purple all-3 bonus meter.
-- Auto-opens once whenever a claim becomes ready. Server: QuestSync / QuestClaim.
-- =====================================================================================================
do
	local QuestSyncR = remotes:WaitForChild("QuestSync")
	local QuestClaimR = remotes:WaitForChild("QuestClaim")
	local TS = game:GetService("TweenService")
	local QGOLD = Color3.fromRGB(230, 180, 76)
	local QICON = { kills = "🧟", wave = "🌊", money = "🪙", runs = "🎮", wins = "🏆", crates = "📦" }
	local PANEL_X_OPEN, PANEL_X_CLOSED = 64, -330

	local Q = { open = false, data = nil, deadline = 0, autoArmed = true } -- one table (200-local ceiling)

	Q.gui = Instance.new("ScreenGui")
	Q.gui.Name = "LobbyQuests"
	Q.gui.ResetOnSpawn = false
	Q.gui.IgnoreGuiInset = true
	Q.gui.DisplayOrder = 12
	Q.gui.Parent = playerGui
	lattach(Q.gui, "hud")

	Q.text = function(parent, str, size, colr) -- sticker text (the shop's helper is scoped to its block)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = TITLE_FACE
		l.TextSize = size
		l.TextColor3 = colr or Color3.new(1, 1, 1)
		l.Text = str
		l.ZIndex = 5
		local st = Instance.new("UIStroke")
		st.Color = TBLACK
		st.Thickness = math.clamp(size / 8, 2, 3)
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Parent = l
		l.Parent = parent
		return l
	end

	-- THE RAIL — a clean STRAIGHT-EDGED rectangle flush to the screen edge (no rounding, no tile):
	-- vertical QUESTS text, the open/close chevron at the bottom, red badge on the corner.
	Q.rail = Instance.new("TextButton")
	Q.rail.Name = "QuestRail"
	Q.rail.AnchorPoint = Vector2.new(0, 0.5)
	Q.rail.Position = UDim2.new(0, 0, 0.5, 0)
	Q.rail.Size = UDim2.fromOffset(44, 168)
	Q.rail.BackgroundColor3 = Color3.fromRGB(14, 13, 10)
	Q.rail.BackgroundTransparency = 0.08
	Q.rail.BorderSizePixel = 0
	Q.rail.AutoButtonColor = true
	Q.rail.Text = ""
	Q.rail.Parent = Q.gui
	ledge(Q.rail, TBLACK, 3)
	do
		local vt = Q.text(Q.rail, "QUESTS", 15, Color3.fromRGB(217, 247, 184))
		vt.AnchorPoint = Vector2.new(0.5, 0.5)
		vt.Position = UDim2.new(0.5, 0, 0.5, -8)
		vt.Size = UDim2.fromOffset(130, 20)
		vt.Rotation = -90
	end
	Q.arrow = Q.text(Q.rail, "▶", 13, ACCENT)
	Q.arrow.AnchorPoint = Vector2.new(0.5, 1)
	Q.arrow.Position = UDim2.new(0.5, 0, 1, -6)
	Q.arrow.Size = UDim2.fromOffset(16, 16)
	Q.badge = Instance.new("Frame")
	Q.badge.AnchorPoint = Vector2.new(1, 0)
	Q.badge.Position = UDim2.new(1, 8, 0, -8)
	Q.badge.Size = UDim2.fromOffset(24, 24)
	Q.badge.BackgroundColor3 = Color3.fromRGB(224, 28, 14)
	Q.badge.BorderSizePixel = 0
	Q.badge.Visible = false
	Q.badge.ZIndex = 6
	Q.badge.Parent = Q.rail
	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = Q.badge
		local rim = Instance.new("UIStroke")
		rim.Color = Color3.new(1, 1, 1)
		rim.Transparency = 0.15
		rim.Thickness = 1.5
		rim.Parent = Q.badge
	end
	Q.badgeN = Q.text(Q.badge, "1", 13)
	Q.badgeN.Size = UDim2.fromScale(1, 1)
	Q.badgeN.ZIndex = 7
	Q.badgeScale = Instance.new("UIScale")
	Q.badgeScale.Parent = Q.badge
	task.spawn(function() -- heartbeat while a claim is waiting
		while true do
			task.wait(1.1)
			if Q.badge.Visible then
				TS:Create(Q.badgeScale, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Scale = 1.3 }):Play()
				task.wait(0.16)
				TS:Create(Q.badgeScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Scale = 1 }):Play()
			end
		end
	end)
	do -- rail hover/press juice (same feel as the dock)
		local sc = Instance.new("UIScale")
		sc.Parent = Q.rail
		local function to(v, t, style)
			TS:Create(sc, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = v }):Play()
		end
		Q.rail.MouseEnter:Connect(function() to(1.05, 0.09) end)
		Q.rail.MouseLeave:Connect(function() to(1, 0.09) end)
		Q.rail.MouseButton1Down:Connect(function() to(0.94, 0.05) end)
		Q.rail.MouseButton1Up:Connect(function() to(1.05, 0.14, Enum.EasingStyle.Back) end)
	end

	-- THE PLATE — the stamp card that slides out.
	-- FIXED height (computed per render). AutomaticSize + the scale-height spine + a list layout fed
	-- back into each other and the plate grew to full screen height — never again.
	Q.panel = Instance.new("Frame")
	Q.panel.Name = "QuestPlate"
	Q.panel.AnchorPoint = Vector2.new(0, 0.5)
	Q.panel.Position = UDim2.new(0, PANEL_X_CLOSED, 0.5, 0)
	Q.panel.Size = UDim2.fromOffset(296, 240)
	Q.panel.BackgroundColor3 = Color3.fromRGB(14, 13, 10)
	Q.panel.BackgroundTransparency = 0.06
	Q.panel.BorderSizePixel = 0
	Q.panel.Visible = false
	Q.panel.Parent = Q.gui
	corner(Q.panel, 12)
	ledge(Q.panel, TBLACK, 3)
	-- All rows stack inside THIS frame (the header band above is absolute).
	Q.body = Instance.new("Frame")
	Q.body.Position = UDim2.fromOffset(0, 38)
	Q.body.Size = UDim2.new(1, 0, 1, -38)
	Q.body.BackgroundTransparency = 1
	Q.body.Parent = Q.panel
	do
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 12)
		pad.PaddingRight = UDim.new(0, 12)
		pad.PaddingTop = UDim.new(0, 10)
		pad.PaddingBottom = UDim.new(0, 12)
		pad.Parent = Q.body
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 8)
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Parent = Q.body
	end
	do -- CHANGED: real chrome — a green gradient header BAND across the plate's top (the flat green
		-- side-bar read as an unfinished placeholder), title on the band, timer chip in its right end.
		local band = Instance.new("Frame")
		band.Size = UDim2.new(1, 0, 0, 38)
		band.BackgroundColor3 = Color3.new(1, 1, 1)
		band.BorderSizePixel = 0
		band.ZIndex = 3
		band.Parent = Q.panel
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 12)
		bc.Parent = band
		local bg = Instance.new("UIGradient")
		bg.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(164, 222, 98)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(100, 178, 40)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(64, 118, 22)),
		})
		bg.Rotation = 90
		bg.Parent = band
		local squareOff = Instance.new("Frame") -- square off the band's bottom corners
		squareOff.AnchorPoint = Vector2.new(0, 1)
		squareOff.Position = UDim2.new(0, 0, 1, 0)
		squareOff.Size = UDim2.new(1, 0, 0, 12)
		squareOff.BackgroundColor3 = Color3.fromRGB(80, 143, 28)
		squareOff.BorderSizePixel = 0
		squareOff.ZIndex = 3
		squareOff.Parent = band
		local seam = Instance.new("Frame") -- black seam under the band, same as the shop chrome
		seam.AnchorPoint = Vector2.new(0, 1)
		seam.Position = UDim2.new(0, 0, 1, 0)
		seam.Size = UDim2.new(1, 0, 0, 2.5)
		seam.BackgroundColor3 = TBLACK
		seam.BorderSizePixel = 0
		seam.ZIndex = 4
		seam.Parent = band
		local t = Q.text(band, "DAILY QUESTS", 17)
		t.Position = UDim2.fromOffset(12, 0)
		t.Size = UDim2.fromOffset(160, 36)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.ZIndex = 5
		local chip = Instance.new("Frame") -- dark timer chip riding the band's right end
		chip.AnchorPoint = Vector2.new(1, 0.5)
		chip.Position = UDim2.new(1, -10, 0.5, -1)
		chip.Size = UDim2.fromOffset(100, 20)
		chip.BackgroundColor3 = Color3.fromRGB(10, 11, 8)
		chip.BorderSizePixel = 0
		chip.ZIndex = 5
		chip.Parent = band
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(1, 0)
		cc.Parent = chip
		Q.resetLbl = Instance.new("TextLabel")
		Q.resetLbl.Size = UDim2.fromScale(1, 1)
		Q.resetLbl.BackgroundTransparency = 1
		Q.resetLbl.FontFace = BODYB_FACE
		Q.resetLbl.TextSize = 10
		Q.resetLbl.TextColor3 = Color3.fromRGB(255, 213, 122)
		Q.resetLbl.Text = ""
		Q.resetLbl.ZIndex = 6
		Q.resetLbl.Parent = chip
	end
	do -- the purple all-3 bonus meter (bottom)
		local row = Instance.new("Frame")
		row.LayoutOrder = 99
		row.Size = UDim2.new(1, 0, 0, 24)
		row.BackgroundTransparency = 1
		row.Parent = Q.body
		local gift = Q.text(row, "🎁", 15)
		gift.Position = UDim2.fromOffset(0, 1)
		gift.Size = UDim2.fromOffset(20, 22)
		local tk = Instance.new("Frame")
		tk.Position = UDim2.fromOffset(28, 6)
		tk.Size = UDim2.new(1, -160, 0, 12)
		tk.BackgroundColor3 = Color3.fromRGB(36, 31, 46)
		tk.BorderSizePixel = 0
		tk.Parent = row
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(1, 0)
		tc.Parent = tk
		ledge(tk, TBLACK, 2)
		Q.bonusFill = Instance.new("Frame")
		Q.bonusFill.Size = UDim2.new(0, 0, 1, 0)
		Q.bonusFill.BackgroundColor3 = Color3.new(1, 1, 1)
		Q.bonusFill.BorderSizePixel = 0
		Q.bonusFill.Parent = tk
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(1, 0)
		fc.Parent = Q.bonusFill
		local fg = Instance.new("UIGradient")
		fg.Color = ColorSequence.new(Color3.fromRGB(122, 43, 216), Color3.fromRGB(201, 59, 240))
		fg.Parent = Q.bonusFill
		Q.bonusLbl = Instance.new("TextLabel")
		Q.bonusLbl.AnchorPoint = Vector2.new(1, 0)
		Q.bonusLbl.Position = UDim2.new(1, 0, 0, 1)
		Q.bonusLbl.Size = UDim2.fromOffset(124, 22)
		Q.bonusLbl.BackgroundTransparency = 1
		Q.bonusLbl.FontFace = BODYB_FACE
		Q.bonusLbl.TextSize = 10
		Q.bonusLbl.TextColor3 = Color3.fromRGB(230, 217, 251)
		Q.bonusLbl.TextXAlignment = Enum.TextXAlignment.Right
		Q.bonusLbl.Text = "ALL 3 → RARE CRATE"
		Q.bonusLbl.Parent = row
		local bs = Instance.new("UIStroke")
		bs.Color = TBLACK
		bs.Thickness = 1.5
		bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		bs.Parent = Q.bonusLbl
	end

	-- Open/close: the plate slides, the arrow flips. (The rail stays put — it's the handle.)
	Q.setOpen = function(on)
		if Q.open == on then
			return
		end
		Q.open = on
		lplay(on and "Open" or "Close")
		Q.panel.Visible = true
		TS:Create(Q.panel,
			TweenInfo.new(on and 0.3 or 0.18, on and Enum.EasingStyle.Back or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0, on and PANEL_X_OPEN or PANEL_X_CLOSED, 0.5, 0) }):Play()
		TS:Create(Q.arrow, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Rotation = on and 180 or 0 }):Play()
		if not on then
			task.delay(0.2, function()
				if not Q.open then
					Q.panel.Visible = false
				end
			end)
		end
	end
	Q.rail.Activated:Connect(function()
		Q.setOpen(not Q.open)
	end)

	Q.render = function()
		local d = Q.data
		if not d or typeof(d.list) ~= "table" then
			return
		end
		for _, c in Q.body:GetChildren() do
			if c:GetAttribute("QuestRow") then
				c:Destroy()
			end
		end
		local ready, claimedN = 0, 0
		local contentH = 38 + 10 + 24 + 12 -- header band + top pad + bonus row + bottom pad
		for i, e in ipairs(d.list) do
			local done = (e.prog or 0) >= (e.goal or 1)
			local claimable = done and not e.claimed
			if claimable then
				ready += 1
			end
			if e.claimed then
				claimedN += 1
			end
			local capH = e.claimed and 44 or (claimable and 68 or 56)
			contentH += capH + 8
			local cap = Instance.new("Frame")
			cap:SetAttribute("QuestRow", true)
			cap.LayoutOrder = 10 + i
			cap.Size = UDim2.new(1, 0, 0, capH)
			cap.BackgroundColor3 = Color3.fromRGB(30, 33, 24)
			cap.BorderSizePixel = 0
			cap.Parent = Q.body
			corner(cap, 10)
			ldepth(cap) -- subtle top-light, same depth trick as every panel card
			ledge(cap, claimable and QGOLD or TBLACK, claimable and 2.5 or 2)
			do -- the stat's icon in a dark glass circle (the dock's family) on the capsule's left
				local ic = Instance.new("Frame")
				ic.AnchorPoint = Vector2.new(0, 0.5)
				ic.Position = UDim2.new(0, 8, 0.5, 0)
				ic.Size = UDim2.fromOffset(32, 32)
				ic.BackgroundColor3 = Color3.new(1, 1, 1)
				ic.BorderSizePixel = 0
				ic.ZIndex = 3
				ic.Parent = cap
				local icc = Instance.new("UICorner")
				icc.CornerRadius = UDim.new(1, 0)
				icc.Parent = ic
				local ig = Instance.new("UIGradient")
				ig.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(52, 55, 64)),
					ColorSequenceKeypoint.new(0.35, Color3.fromRGB(26, 27, 33)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 14, 18)),
				})
				ig.Rotation = 90
				ig.Parent = ic
				ledge(ic, Color3.new(1, 1, 1), 1.2, 0.85)
				local em = Q.text(ic, QICON[e.stat] or "⭐", 16)
				em.Size = UDim2.fromScale(1, 1)
				em.ZIndex = 4
			end
			local nm = Q.text(cap, e.name, 13)
			nm.Position = UDim2.fromOffset(48, 8)
			nm.Size = UDim2.new(1, -138, 0, 16)
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.TextTruncate = Enum.TextTruncate.AtEnd
			if (e.coins or 0) > 0 and not e.claimed then -- reward: a proper little pill, not loose bits
				local pillW = 34 + #fmt(e.coins) * 8
				local rp = Instance.new("Frame")
				rp.AnchorPoint = Vector2.new(1, 0)
				rp.Position = UDim2.new(1, -9, 0, 7)
				rp.Size = UDim2.fromOffset(pillW, 19)
				rp.BackgroundColor3 = Color3.fromRGB(10, 11, 8)
				rp.BackgroundTransparency = 0.2
				rp.BorderSizePixel = 0
				rp.ZIndex = 4
				rp.Parent = cap
				local rc = Instance.new("UICorner")
				rc.CornerRadius = UDim.new(1, 0)
				rc.Parent = rp
				ledge(rp, QGOLD, 1.5, 0.45)
				local disc = Instance.new("Frame")
				disc.AnchorPoint = Vector2.new(0, 0.5)
				disc.Position = UDim2.new(0, 5, 0.5, 0)
				disc.Size = UDim2.fromOffset(12, 12)
				disc.BackgroundColor3 = GOLD
				disc.BorderSizePixel = 0
				disc.ZIndex = 5
				disc.Parent = rp
				local dc = Instance.new("UICorner")
				dc.CornerRadius = UDim.new(1, 0)
				dc.Parent = disc
				ledge(disc, TBLACK, 1.5)
				local amt = Q.text(rp, fmt(e.coins), 12, Color3.fromRGB(255, 213, 122))
				amt.AnchorPoint = Vector2.new(1, 0.5)
				amt.Position = UDim2.new(1, -7, 0.5, 0)
				amt.Size = UDim2.fromOffset(pillW - 26, 15)
				amt.TextXAlignment = Enum.TextXAlignment.Right
				amt.ZIndex = 5
			end
			if e.claimed then
				local tick = Instance.new("Frame")
				tick.Position = UDim2.fromOffset(48, 24)
				tick.Size = UDim2.fromOffset(15, 15)
				tick.BackgroundColor3 = Color3.fromRGB(63, 122, 26)
				tick.BorderSizePixel = 0
				tick.Parent = cap
				local tc2 = Instance.new("UICorner")
				tc2.CornerRadius = UDim.new(1, 0)
				tc2.Parent = tick
				ledge(tick, TBLACK, 1.5)
				local tl = Q.text(tick, "✓", 9)
				tl.Size = UDim2.fromScale(1, 1)
				local cl = Instance.new("TextLabel")
				cl.Position = UDim2.fromOffset(69, 23)
				cl.Size = UDim2.fromOffset(120, 16)
				cl.BackgroundTransparency = 1
				cl.FontFace = BODYB_FACE
				cl.TextSize = 11
				cl.TextColor3 = DIMTEXT
				cl.TextXAlignment = Enum.TextXAlignment.Left
				cl.Text = "CLAIMED"
				cl.Parent = cap
			elseif claimable then
				local btn = Instance.new("TextButton")
				btn.Position = UDim2.fromOffset(48, 30)
				btn.Size = UDim2.new(1, -60, 0, 29)
				btn.BorderSizePixel = 0
				btn.AutoButtonColor = false
				btn.Text = ""
				btn.ZIndex = 4
				btn.Parent = cap
				corner(btn, 8)
				do
					local g = Instance.new("UIGradient")
					btn.BackgroundColor3 = Color3.new(1, 1, 1)
					g.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(251, 233, 182)),
						ColorSequenceKeypoint.new(0.45, Color3.fromRGB(230, 180, 76)),
						ColorSequenceKeypoint.new(1, Color3.fromRGB(168, 122, 30)),
					})
					g.Rotation = 90
					g.Parent = btn
				end
				ledge(btn, TBLACK, 2.5)
				local bl = Q.text(btn, "CLAIM ✦", 14)
				bl.Size = UDim2.fromScale(1, 1)
				bl.ZIndex = 5
				local sc = Instance.new("UIScale")
				sc.Parent = btn
				btn.MouseEnter:Connect(function()
					TS:Create(sc, TweenInfo.new(0.09), { Scale = 1.04 }):Play()
				end)
				btn.MouseLeave:Connect(function()
					TS:Create(sc, TweenInfo.new(0.09), { Scale = 1 }):Play()
				end)
				btn.MouseButton1Down:Connect(function()
					TS:Create(sc, TweenInfo.new(0.05), { Scale = 0.93 }):Play()
				end)
				btn.Activated:Connect(function()
					lplay("Buy")
					QuestClaimR:FireServer({ i = i })
				end)
			else
				local tk = Instance.new("Frame")
				tk.Position = UDim2.fromOffset(48, 31)
				tk.Size = UDim2.new(1, -60, 0, 14)
				tk.BackgroundColor3 = Color3.fromRGB(36, 41, 28)
				tk.BorderSizePixel = 0
				tk.Parent = cap
				local kc = Instance.new("UICorner")
				kc.CornerRadius = UDim.new(1, 0)
				kc.Parent = tk
				ledge(tk, TBLACK, 1.5)
				local fill = Instance.new("Frame")
				fill.Size = UDim2.new(math.clamp((e.prog or 0) / math.max(e.goal or 1, 1), 0, 1), 0, 1, 0)
				fill.BackgroundColor3 = Color3.new(1, 1, 1)
				fill.BorderSizePixel = 0
				fill.Parent = tk
				local fc2 = Instance.new("UICorner")
				fc2.CornerRadius = UDim.new(1, 0)
				fc2.Parent = fill
				local fg2 = Instance.new("UIGradient")
				fg2.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(192, 243, 127)),
					ColorSequenceKeypoint.new(0.55, Color3.fromRGB(124, 219, 35)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(84, 148, 26)),
				})
				fg2.Rotation = 90
				fg2.Parent = fill
				local num = Instance.new("TextLabel")
				num.Size = UDim2.fromScale(1, 1)
				num.BackgroundTransparency = 1
				num.FontFace = BODYB_FACE
				num.TextSize = 10
				num.TextColor3 = TEXTCOL
				num.ZIndex = 3
				num.Text = fmt(e.prog or 0) .. " / " .. fmt(e.goal or 0)
				num.Parent = tk
				local ns = Instance.new("UIStroke")
				ns.Color = TBLACK
				ns.Thickness = 1.5
				ns.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
				ns.Parent = num
			end
		end
		-- fixed height from the actual rows (per-capsule +8 already covers every stack gap)
		Q.panel.Size = UDim2.fromOffset(296, contentH)
		-- badge + bonus meter + the once-per-readiness auto-open
		Q.badge.Visible = ready > 0
		Q.badgeN.Text = tostring(ready)
		Q.bonusFill.Size = UDim2.new(claimedN / math.max(#d.list, 1), 0, 1, 0)
		if d.bonusDone then
			Q.bonusLbl.Text = "BONUS CLAIMED ✓"
			Q.bonusLbl.TextColor3 = Color3.fromRGB(155, 226, 74)
		else
			Q.bonusLbl.Text = ("ALL %d → %s CRATE"):format(#d.list, tostring(d.bonusCase or "rare"):upper())
			Q.bonusLbl.TextColor3 = Color3.fromRGB(230, 217, 251)
		end
		if ready > 0 and Q.autoArmed then
			Q.autoArmed = false -- open ONCE per "something became claimable", not every sync
			Q.setOpen(true)
		elseif ready == 0 then
			Q.autoArmed = true
		end
	end

	QuestSyncR.OnClientEvent:Connect(function(d)
		if typeof(d) ~= "table" then
			return
		end
		Q.data = d
		Q.deadline = os.clock() + (tonumber(d.resetIn) or 0)
		Q.render()
	end)
	task.spawn(function() -- the NEW IN hh:mm:ss chip ticks while the plate is out
		while true do
			task.wait(1)
			if Q.panel.Visible and Q.resetLbl then
				local left = math.max(0, Q.deadline - os.clock())
				Q.resetLbl.Text = ("NEW IN %02d:%02d:%02d"):format(
					math.floor(left / 3600), math.floor(left / 60) % 60, math.floor(left) % 60)
			end
		end
	end)
	QuestSyncR:FireServer() -- pull the board (join-race safe, same trick as InvRequest)
end

-- ===== ACCOUNT LEVEL / XP BAR ===== (bottom-center: level, progress, and the NEXT gun you'll unlock) ====
-- =====================================================================================================
do
	local LEVEL_BASE_XP, LEVEL_GROWTH, LEVEL_MAX = 120, 1.18, 100 -- mirrors the server's accountLevel curve
	local function levelInfo(totalXP)
		local level, remaining = 1, math.max(0, tonumber(totalXP) or 0)
		while level < LEVEL_MAX do
			local need = math.floor(LEVEL_BASE_XP * (LEVEL_GROWTH ^ (level - 1)))
			if remaining < need then
				return level, remaining, need
			end
			remaining -= need
			level += 1
		end
		return LEVEL_MAX, 0, 0
	end

	local xpGui = Instance.new("ScreenGui")
	xpGui.Name = "LobbyXP"; xpGui.ResetOnSpawn = false; xpGui.IgnoreGuiInset = true; xpGui.DisplayOrder = 12
	xpGui.Parent = playerGui
	lattach(xpGui, "hud")

	-- CHANGED: bottom-RIGHT (mid-left was in the way; daily quests take that spot next).
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(1, 1); bar.Position = UDim2.new(1, -16, 1, -12); bar.Size = UDim2.fromOffset(400, 72)
	bar.BackgroundColor3 = PANEL; bar.BackgroundTransparency = 0.15; bar.BorderSizePixel = 0; bar.Parent = xpGui
	corner(bar, 8); lstuds(bar); ldepth(bar); ledge(bar, TBLACK, 3)
	ledge(bar, Color3.fromRGB(196, 200, 190), 2, 0.35) -- CHANGED: light-gray accent ring (was green)

	local lvl = Instance.new("TextLabel")
	lvl.Position = UDim2.fromOffset(14, 0); lvl.Size = UDim2.fromOffset(96, 72); lvl.BackgroundTransparency = 1
	lvl.FontFace = TITLE_FACE; lvl.TextSize = 33; lvl.TextColor3 = Color3.fromRGB(66, 165, 245); lvl.Text = "LVL 1" -- XP/level is BLUE
	lvl.TextXAlignment = Enum.TextXAlignment.Left; lvl.Parent = bar
	local lvlSt = Instance.new("UIStroke"); lvlSt.Color = TBLACK; lvlSt.Thickness = 2.5; lvlSt.Parent = lvl

	local nextLbl = Instance.new("TextLabel")
	nextLbl.Position = UDim2.fromOffset(116, 10); nextLbl.Size = UDim2.new(1, -130, 0, 22); nextLbl.BackgroundTransparency = 1
	nextLbl.FontFace = BODYB_FACE; nextLbl.TextSize = 16; nextLbl.TextXAlignment = Enum.TextXAlignment.Left
	nextLbl.TextColor3 = TEXTCOL; nextLbl.Text = ""; nextLbl.TextTruncate = Enum.TextTruncate.AtEnd; nextLbl.Parent = bar
	local nextSt = Instance.new("UIStroke"); nextSt.Color = TBLACK; nextSt.Thickness = 1.5; nextSt.Parent = nextLbl

	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0, 1); track.Position = UDim2.new(0, 116, 1, -12); track.Size = UDim2.new(1, -130, 0, 22)
	track.BackgroundColor3 = TRACK; track.BorderSizePixel = 0; track.Parent = bar
	corner(track, 8); ledge(track, TBLACK, 1.5)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0); fill.BackgroundColor3 = Color3.fromRGB(66, 165, 245); fill.BorderSizePixel = 0; fill.Parent = track
	corner(fill, 8)
	local xpTxt = Instance.new("TextLabel")
	xpTxt.Size = UDim2.fromScale(1, 1); xpTxt.BackgroundTransparency = 1; xpTxt.ZIndex = 2
	xpTxt.FontFace = BODYB_FACE; xpTxt.TextSize = 14; xpTxt.TextColor3 = TEXTCOL; xpTxt.Text = ""; xpTxt.Parent = track
	local xpSt = Instance.new("UIStroke"); xpSt.Color = TBLACK; xpSt.Thickness = 1.5; xpSt.Parent = xpTxt

	-- The lowest-level gun still above the player's level that they don't already own (drives "NEXT UNLOCK").
	local function nextUnlock(level)
		if not invData or not invData.catalog or not invData.catalog.weapons then
			return nil
		end
		local bestId, bestLvl
		for id, w in invData.catalog.weapons do
			local u = tonumber(w.unlock) or 0
			local owned = invData.owned and table.find(invData.owned, id)
			if u > level and not owned and (not bestLvl or u < bestLvl or (u == bestLvl and id < bestId)) then
				bestId, bestLvl = id, u
			end
		end
		if bestId then
			return (invData.catalog.weapons[bestId].name or bestId), bestLvl
		end
		return nil
	end

	local prevLevel = nil
	local function refresh()
		local level, into, need = levelInfo(localPlayer:GetAttribute("AccountXP") or 0)
		localPlayer:SetAttribute("AccountLevel", level) -- the shop pane reads this to gate level-locked guns
		if prevLevel and level > prevLevel then
			lplay("LevelUp") -- NEW: the owner's level-up sting
		end
		prevLevel = level
		lvl.Text = "LVL " .. level
		if need > 0 then
			fill.Size = UDim2.new(math.clamp(into / need, 0, 1), 0, 1, 0)
			xpTxt.Text = fmt(into) .. " / " .. fmt(need) .. " XP"
		else
			fill.Size = UDim2.fromScale(1, 1)
			xpTxt.Text = "MAX LEVEL"
		end
		local gunName, gunLvl = nextUnlock(level)
		if gunName then
			nextLbl.Text = ("NEXT UNLOCK:  %s  ·  Lv %d"):format(string.upper(gunName), gunLvl)
			nextLbl.TextColor3 = TEXTCOL
		else
			nextLbl.Text = "ALL GUNS UNLOCKED"
			nextLbl.TextColor3 = ACCENT
		end
	end

	localPlayer:GetAttributeChangedSignal("AccountXP"):Connect(refresh)
	localPlayer:GetAttributeChangedSignal("InvVersion"):Connect(refresh)
	task.delay(2, refresh)
	refresh()
end

-- ===== FIRST-JOIN POINTER TOUR ===== new players ONLY, once. A dim overlay spotlights each lobby system
-- in turn (coins -> shop -> classes -> daily -> play) with a callout + NEXT/SKIP, then lets them play.
-- It reads each target's LIVE AbsolutePosition (real screen pixels), so this ScreenGui is intentionally
-- NOT lattach'd. Gated on the profile's tutDone flag (mirrored to the "TutDone" player attribute above).
-- Everything hangs on one table T so the block adds a single main-chunk local (the 200-local ceiling).
do
	local T = {}
	T.done = remotes:WaitForChild("TutorialDone")
	T.i = 1
	T.gui = Instance.new("ScreenGui")
	T.gui.Name = "LobbyTutorial"
	T.gui.ResetOnSpawn = false
	T.gui.IgnoreGuiInset = true
	T.gui.DisplayOrder = 35 -- above panels/coins, below toasts(40)/warnings(90)
	T.gui.Enabled = false
	T.gui.Parent = playerGui
	lattach(T.gui) -- scale the card/text like the rest of the HUD; place() divides target coords by this scale

	T.catcher = Instance.new("TextButton") -- swallows every click to the HUD behind; NEXT/SKIP sit above it
	-- fromScale(2,2) so it still covers the whole screen after the gui's UIScale shrinks it (<1 on phones)
	T.catcher.Size = UDim2.fromScale(2, 2); T.catcher.Position = UDim2.fromScale(-0.5, -0.5)
	T.catcher.BackgroundTransparency = 1; T.catcher.Text = ""
	T.catcher.AutoButtonColor = false; T.catcher.ZIndex = 1; T.catcher.Parent = T.gui

	T.dim = {} -- four dark panels leave a clear window over the current target
	for k = 1, 4 do
		local f = Instance.new("Frame")
		-- CHANGED: much darker (0.28 -> 0.06). At 72% opacity, bright things (the PLAY button, the world
		-- spotlight on the character) bled through and it read as a bright blob instead of a clean
		-- spotlight; near-opaque, only the clear window over the target stands out.
		f.BackgroundColor3 = Color3.fromRGB(3, 4, 2); f.BackgroundTransparency = 0.06
		f.BorderSizePixel = 0; f.ZIndex = 2; f.Parent = T.gui
		T.dim[k] = f
	end

	T.ring = Instance.new("Frame")
	T.ring.BackgroundTransparency = 1; T.ring.ZIndex = 3; T.ring.Parent = T.gui
	do
		local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 14); rc.Parent = T.ring
		local rs = Instance.new("UIStroke"); rs.Color = ACCENT; rs.Thickness = 3; rs.Parent = T.ring
	end

	T.card = Instance.new("Frame")
	T.card.Size = UDim2.fromOffset(430, 210); T.card.BackgroundColor3 = PANEL -- CHANGED: bigger callout
	T.card.BorderSizePixel = 0; T.card.ZIndex = 5; T.card.Parent = T.gui
	corner(T.card, 12); ledge(T.card, TBLACK, 3.5); ledge(T.card, ACCENT, 2, 0.35)

	T.stepLbl = Instance.new("TextLabel")
	T.stepLbl.Position = UDim2.fromOffset(16, -14); T.stepLbl.Size = UDim2.fromOffset(72, 28)
	T.stepLbl.BackgroundColor3 = ACCENT; T.stepLbl.BorderSizePixel = 0
	T.stepLbl.FontFace = TITLE_FACE; T.stepLbl.TextSize = 17; T.stepLbl.TextColor3 = Color3.fromRGB(14, 18, 6)
	T.stepLbl.Text = "1 / 5"; T.stepLbl.ZIndex = 6; T.stepLbl.Parent = T.card
	corner(T.stepLbl, 6); ledge(T.stepLbl, TBLACK, 2.5)

	T.title = Instance.new("TextLabel")
	T.title.Position = UDim2.fromOffset(20, 22); T.title.Size = UDim2.new(1, -40, 0, 32)
	T.title.BackgroundTransparency = 1; T.title.FontFace = TITLE_FACE; T.title.TextSize = 26
	T.title.TextColor3 = Color3.new(1, 1, 1); T.title.TextXAlignment = Enum.TextXAlignment.Left
	T.title.ZIndex = 6; T.title.Parent = T.card

	T.body = Instance.new("TextLabel")
	T.body.Position = UDim2.fromOffset(20, 60); T.body.Size = UDim2.new(1, -40, 0, 82)
	T.body.BackgroundTransparency = 1; T.body.FontFace = BODYB_FACE; T.body.TextSize = 19
	T.body.TextColor3 = TEXTCOL; T.body.TextWrapped = true; T.body.TextXAlignment = Enum.TextXAlignment.Left
	T.body.TextYAlignment = Enum.TextYAlignment.Top; T.body.ZIndex = 6; T.body.Parent = T.card

	T.skip = Instance.new("TextButton")
	T.skip.AnchorPoint = Vector2.new(0, 1); T.skip.Position = UDim2.new(0, 20, 1, -18)
	T.skip.Size = UDim2.fromOffset(130, 34); T.skip.BackgroundTransparency = 1
	T.skip.FontFace = BODYB_FACE; T.skip.TextSize = 16; T.skip.TextColor3 = DIMTEXT
	T.skip.Text = "SKIP TUTORIAL"; T.skip.TextXAlignment = Enum.TextXAlignment.Left; T.skip.ZIndex = 6; T.skip.Parent = T.card

	T.next = Instance.new("TextButton")
	T.next.AnchorPoint = Vector2.new(1, 1); T.next.Position = UDim2.new(1, -18, 1, -16)
	T.next.Size = UDim2.fromOffset(150, 50); T.next.BackgroundColor3 = ACCENT; T.next.BorderSizePixel = 0
	T.next.FontFace = TITLE_FACE; T.next.TextSize = 22; T.next.TextColor3 = Color3.new(1, 1, 1)
	T.next.Text = "NEXT"; T.next.ZIndex = 6; T.next.Parent = T.card
	corner(T.next, 8); ledge(T.next, TBLACK, 2.5); lbevel(T.next)

	T.steps = {
		{ get = function() return coinsRow end, title = "YOUR COINS",
			body = "This is your cash. Earn it in runs, then spend it in the shop on guns and upgrades." },
		{ get = function() return dockBtns.shop end, title = "THE SHOP",
			body = "Buy new guns and upgrade the ones you own. You can open it anytime with the B key." },
		{ get = function() return dockBtns.classes end, title = "CLASSES",
			body = "Pick a class perk - extra gun damage, more health, faster move speed, or bonus coins." },
		{ get = function() return dockBtns.daily end, title = "DAILY REWARD",
			body = "Spin the wheel once a day for a free reward. Come back daily to build a streak." },
		{ get = function() return playBtn end, title = "READY?",
			body = "Step on a pad or hit PLAY to start your first run. Kill zombies, get paid, survive. Good luck!" },
	}

	T.finish = function()
		if not T.gui.Enabled then
			return
		end
		T.gui.Enabled = false
		T.done:FireServer()
	end

	T.place = function(target)
		local cam = workspace.CurrentCamera
		-- This gui is scaled by lattach; its children use PRE-scale offsets. Targets report Absolute* in
		-- REAL screen pixels, so divide everything by our scale S to place holes/ring/card in this gui's
		-- offset space (they then render back at the right real-pixel spot, aligned with the scaled HUD).
		local usc = T.gui:FindFirstChild("ResponsiveScale")
		local S = (usc and usc.Scale) or 1
		local vpr = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local VX, VY = vpr.X / S, vpr.Y / S -- full screen in offset space
		local pos, size = target.AbsolutePosition, target.AbsoluteSize
		local pad = 14
		local x = math.floor((pos.X - pad) / S)
		local y = math.floor((pos.Y - pad) / S)
		local w = math.floor((size.X + pad * 2) / S)
		local h = math.floor((size.Y + pad * 2) / S)
		T.dim[1].Position = UDim2.fromOffset(0, 0); T.dim[1].Size = UDim2.fromOffset(VX, math.max(0, y))
		T.dim[2].Position = UDim2.fromOffset(0, y + h); T.dim[2].Size = UDim2.fromOffset(VX, math.max(0, VY - (y + h)))
		T.dim[3].Position = UDim2.fromOffset(0, y); T.dim[3].Size = UDim2.fromOffset(math.max(0, x), h)
		T.dim[4].Position = UDim2.fromOffset(x + w, y); T.dim[4].Size = UDim2.fromOffset(math.max(0, VX - (x + w)), h)
		T.ring.Position = UDim2.fromOffset(x, y); T.ring.Size = UDim2.fromOffset(w, h)
		local cardW, cardH = 430, 210 -- offset-space size (matches T.card.Size); renders at cardW*S
		local tcx = (pos.X + size.X / 2) / S -- target centre X in offset space
		local cx = math.clamp(math.floor(tcx - cardW / 2), 12, math.max(12, VX - cardW - 12))
		local cy
		if (y + h / 2) > VY / 2 then -- target in the lower half → card ABOVE it
			cy = y - cardH - 22
		else
			cy = y + h + 22
		end
		cy = math.clamp(cy, 12, math.max(12, VY - cardH - 12))
		T.card.Position = UDim2.fromOffset(cx, cy)
	end

	T.show = function(i)
		local step = T.steps[i]
		if not step then
			return T.finish()
		end
		local target = step.get()
		if not target or target.AbsoluteSize.X < 2 then -- target missing/unrendered → skip it
			if i < #T.steps then
				return T.show(i + 1)
			end
			return T.finish()
		end
		T.i = i
		T.stepLbl.Text = ("%d / %d"):format(i, #T.steps)
		T.title.Text = step.title
		T.body.Text = step.body
		T.next.Text = (i >= #T.steps) and "LET'S GO" or "NEXT"
		T.place(target)
	end

	T.next.Activated:Connect(function()
		lplay("Click")
		if T.i >= #T.steps then
			T.finish()
		else
			T.show(T.i + 1)
		end
	end)
	T.skip.Activated:Connect(function()
		lplay("Click")
		T.finish()
	end)

	do
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if T.gui.Enabled and T.steps[T.i] then
					local tg = T.steps[T.i].get()
					if tg then
						T.place(tg)
					end
				end
			end)
		end
	end

	T.maybeStart = function()
		if T.ran then
			return
		end
		if localPlayer:GetAttribute("TutDone") ~= false then -- nil (not loaded yet) or true → don't run
			return
		end
		T.ran = true
		T.gui.Enabled = true
		task.wait(0.15) -- let the HUD's AbsolutePositions settle before measuring
		T.show(1)
	end
	localPlayer:GetAttributeChangedSignal("TutDone"):Connect(T.maybeStart)
	task.defer(T.maybeStart)
end

-- ===== PAD GUIDE TRAIL ===== a glowing green beam trail + a bobbing arrow from the player to the NEAREST
-- LoadingZone pad, so you always know where to go. Hides while you stand on a pad. Local-only (parented
-- under the Camera so it never replicates or collides). Everything hangs on G (one main-chunk local).
do
	local RunService = game:GetService("RunService")
	-- TUNABLE: the flowing-arrow texture (a repeating ">" chevron, like your example). Paste your own
	-- chevron asset id here for the exact look; "" falls back to a plain glowing ribbon.
	local TRAIL_TEXTURE = "rbxassetid://446111271"
	local G = {}
	G.pads = {}
	G.padsT = 0
	G.mark = Instance.new("Part") -- sits on the target pad; holds the beam's far end + the arrow billboard
	G.mark.Name = "PadGuideMark"; G.mark.Anchored = true; G.mark.CanCollide = false
	G.mark.CanQuery = false; G.mark.CanTouch = false; G.mark.Transparency = 1
	G.mark.Size = Vector3.new(1, 1, 1); G.mark.Parent = workspace.CurrentCamera
	G.a1 = Instance.new("Attachment"); G.a1.Parent = G.mark

	G.beam = Instance.new("Beam")
	G.beam.Attachment1 = G.a1
	G.beam.Color = ColorSequence.new(ACCENT)
	G.beam.LightEmission = 1
	G.beam.FaceCamera = true
	G.beam.Width0 = 2.4; G.beam.Width1 = 2.0 -- steady width so the chevrons read at both ends
	G.beam.Segments = 16
	G.beam.CurveSize0 = 4; G.beam.CurveSize1 = 4 -- a gentle arc so it reads as a path, not a laser
	if TRAIL_TEXTURE ~= "" then
		G.beam.Texture = TRAIL_TEXTURE
		G.beam.TextureMode = Enum.TextureMode.Wrap
		G.beam.TextureLength = 4 -- studs per chevron repeat
		G.beam.TextureSpeed = 2.2 -- chevrons FLOW toward the pad (A0 -> A1)
		G.beam.Transparency = NumberSequence.new(0) -- the texture carries its own alpha (transparent gaps)
	else
		G.beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0.5) })
	end
	G.beam.Enabled = false
	G.beam.Parent = G.mark

	G.bb = Instance.new("BillboardGui")
	G.bb.Name = "PadGuideArrow"; G.bb.Size = UDim2.fromOffset(150, 150); G.bb.AlwaysOnTop = true
	G.bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0); G.bb.Adornee = G.mark
	G.bb.Enabled = false; G.bb.Parent = G.mark
	G.arrow = Instance.new("TextLabel") -- default font (SourceSans) renders the down-arrow glyph reliably
	G.arrow.AnchorPoint = Vector2.new(0.5, 0.5); G.arrow.Position = UDim2.fromScale(0.5, 0.5)
	G.arrow.Size = UDim2.fromOffset(120, 120); G.arrow.BackgroundTransparency = 1
	G.arrow.TextSize = 76; G.arrow.TextColor3 = ACCENT; G.arrow.Text = "▼"; G.arrow.ZIndex = 2; G.arrow.Parent = G.bb
	do local s = Instance.new("UIStroke"); s.Color = TBLACK; s.Thickness = 3.5; s.Parent = G.arrow end
	G.hint = Instance.new("TextLabel")
	G.hint.AnchorPoint = Vector2.new(0.5, 0); G.hint.Position = UDim2.fromScale(0.5, 0.9)
	G.hint.Size = UDim2.fromOffset(190, 30); G.hint.BackgroundTransparency = 1
	G.hint.FontFace = TITLE_FACE; G.hint.TextSize = 20; G.hint.TextColor3 = Color3.new(1, 1, 1)
	G.hint.Text = "PLAY HERE"; G.hint.ZIndex = 2; G.hint.Parent = G.bb
	do local s = Instance.new("UIStroke"); s.Color = TBLACK; s.Thickness = 3; s.Parent = G.hint end

	G.hideAll = function()
		G.beam.Enabled = false
		G.bb.Enabled = false
	end

	RunService.Heartbeat:Connect(function(dt)
		-- NEW-PLAYER guide only: shows AFTER the tutorial finishes and ONLY until their first run is
		-- banked (bestWave > 0 = they've played). Veterans never see it.
		if localPlayer:GetAttribute("TutDone") ~= true
			or (tonumber(localPlayer:GetAttribute("BestWave")) or 0) > 0 then
			return G.hideAll()
		end
		local char = localPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then
			return G.hideAll()
		end
		local a0 = root:FindFirstChild("PadGuideA0")
		if not a0 then -- (re)attach the beam's near end to the current character
			a0 = Instance.new("Attachment"); a0.Name = "PadGuideA0"; a0.Parent = root
		end
		G.beam.Attachment0 = a0
		-- refresh the pad list occasionally (cheap); nearest is picked from the cache every frame
		G.padsT -= dt
		if G.padsT <= 0 then
			G.padsT = 2
			G.pads = {}
			for _, d in workspace:GetDescendants() do
				if d:IsA("BasePart") and string.lower(string.sub(d.Name, 1, 11)) == "loadingzone" then
					table.insert(G.pads, d)
				end
			end
		end
		local pad, bestD
		for _, p in G.pads do
			if p.Parent then
				local dd = (p.Position - root.Position).Magnitude
				if not bestD or dd < bestD then
					pad, bestD = p, dd
				end
			end
		end
		if not pad then
			return G.hideAll()
		end
		local dx, dz = pad.Position.X - root.Position.X, pad.Position.Z - root.Position.Z
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < (math.max(pad.Size.X, pad.Size.Z) * 0.5 + 1.5) then -- standing on the pad → hide the guide
			return G.hideAll()
		end
		G.mark.Position = Vector3.new(pad.Position.X, pad.Position.Y + pad.Size.Y * 0.5 + 0.5, pad.Position.Z)
		G.arrow.Position = UDim2.new(0.5, 0, 0.5, math.floor(math.sin(os.clock() * 4) * 8)) -- gentle bob
		G.beam.Enabled = true
		G.bb.Enabled = true
	end)
end

-- EVERYTHING is wired — now PULL a fresh snapshot. The server's join-time pushes often fire while
-- this (big) script is still loading, so the hotbar/coins/XP missed them and sat empty until some
-- other action triggered a resend. This request closes that race for good.
InvRequest:FireServer()

print("[LobbyClient] started")
