--!nonstrict
-- UITheme.lua — THE design system (gritty apocalypse). Every screen builds from these tokens + helpers,
-- so the whole game reads as one hand-made style instead of a pile of gray rounded rectangles.
--
--   LOOK: dark olive-charcoal panels with a faint STUD texture, hard 4-6px corners, black outer strokes,
--   vertical depth gradients, TOXIC GREEN as the signature accent, BLOOD ORANGE for danger/aggression,
--   stencil military headers (Black Ops One) over tech body text (Orbitron).
--
--   FONTS: Black Ops One + Orbitron come from the Creator Store (they aren't Enum.Font entries).
--   >>> Paste their family asset ids into FONT_IDS below. To get an id: create.roblox.com/store/fonts →
--   search the font → the number in the page URL is the id. Blank ids fall back to Sarpanch/Michroma
--   (closest built-ins) so nothing breaks while you fetch them. <<<
--
--   RESPONSIVE: call UITheme.Attach(screenGui) on EVERY ScreenGui — it mounts a UIScale that follows the
--   viewport live (resize/rotation), designed at 1920×1080, clamped, with a touch-device readability bump.
--
-- The LOBBY place can't require this file (separate place) — LobbyClient carries a synced copy of the
-- tokens + the same helpers. Change a color here, mirror it there.

local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local UITheme = {}

-- ===== FONT CONFIG (paste Creator Store family ids here) =====
local FONT_IDS = {
	Title = "", -- paste the "Black Ops One" font family asset id here (stencil military headers)
	Body  = "", -- paste the "Orbitron" font family asset id here (tech body text)
}
local FALLBACK_TITLE = Enum.Font.FredokaOne -- chunky rounded cartoon face (the reference look)
local FALLBACK_BODY  = Enum.Font.FredokaOne -- one face everywhere, weights differentiate

local function makeFace(id: string, weight: Enum.FontWeight, fallbackEnum: Enum.Font): Font
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

UITheme.TitleFace = makeFace(FONT_IDS.Title, Enum.FontWeight.Regular, FALLBACK_TITLE)
UITheme.BodyFace = makeFace(FONT_IDS.Body, Enum.FontWeight.Medium, FALLBACK_BODY)
UITheme.BodyBoldFace = makeFace(FONT_IDS.Body, Enum.FontWeight.Bold, FALLBACK_BODY)

-- ===== PALETTE =====
UITheme.BG       = Color3.fromRGB(12, 14, 10)   -- deepest backdrop (overlays)
UITheme.PANEL    = Color3.fromRGB(21, 24, 17)   -- main panel body
UITheme.PANEL2   = Color3.fromRGB(29, 33, 23)   -- raised cards on a panel
UITheme.TRACK    = Color3.fromRGB(36, 41, 28)   -- bar tracks / wells
UITheme.LINE     = Color3.fromRGB(74, 82, 56)   -- olive hairlines
UITheme.BLACK    = Color3.fromRGB(6, 7, 5)      -- outer strokes / text outlines
UITheme.TOXIC    = Color3.fromRGB(124, 219, 35) -- THE accent: toxic green
UITheme.TOXIC_HI = Color3.fromRGB(170, 255, 70)
UITheme.TOXIC_DK = Color3.fromRGB(58, 116, 16)
UITheme.ORANGE   = Color3.fromRGB(255, 96, 34)  -- blood orange: danger / aggression / alerts
UITheme.ORANGE_DK = Color3.fromRGB(150, 44, 12)
UITheme.TEXT     = Color3.fromRGB(222, 227, 209) -- bone white
UITheme.DIM      = Color3.fromRGB(134, 142, 116)
UITheme.GOLD     = Color3.fromRGB(230, 180, 76)  -- currency only
UITheme.DANGER   = UITheme.ORANGE

-- ===== SIZE SYSTEM (the renovation spec — every label/control maps to ONE of these) =====
-- TYPE SCALE: 7 sizes, period. Rule 1: alerts outrank ambient status. Rule 2: a badge/hint never
-- outranks the thing it labels.
UITheme.Type = {
	Hero    = 34, -- ONE per place (banner caps)
	Screen  = 28, -- panel/screen titles (GUNS, SETTINGS, ...)
	Item    = 22, -- featured item names, event banners, reel result
	Section = 18, -- section labels, big value readouts
	Value   = 16, -- ALL button text + HP/coins/cash numbers
	Body    = 14, -- stats, descriptions, grid-cell names
	Caption = 12, -- captions, chips, badges, hints — nothing renders below 12
}
-- CONTROL HEIGHTS: 4 tokens. Nothing tappable under Min.
UITheme.Ctl = {
	CTA      = 56, -- the one biggest action per screen
	Std      = 44, -- secondary actions, every close X, gear, arrows
	Min      = 36, -- toggles, slider hit-strips — the touch floor
	Launcher = 72, -- GUNS / SKIN CRATES / SHOP icon buttons (both places)
}
-- SPACING RHYTHM: one grid.
UITheme.Space = { Pad = 16, Row = 8, Section = 24, Header = 48 }
-- LAYER LADDER (ScreenGui.DisplayOrder registry): 0-9 ambient HUD · 10-19 overlays/banners ·
-- 20-29 modals · 90 critical warnings · 100 crosshair. Chrome never floats over open modals.
UITheme.Layer = {
	HUD = 4, Hotbar = 6, Boss = 8, Chrome = 8,
	Spectate = 11, Streak = 12, Toast = 14,
	ShopModal = 22, CratesModal = 24, SettingsModal = 26,
	Warning = 90, Crosshair = 100,
}

-- Studs backdrop texture (tileable). Swap the id if you prefer another studs decal.
UITheme.StudsTexture = "rbxassetid://6965996718"

-- Panels are slightly see-through so the world/studs read faintly behind (text stays solid).
UITheme.PanelAlpha = 0.12

-- Per-screen HEADER BAR colors (the solid strip across the top of a panel).
UITheme.HeaderColors = {
	guns     = Color3.fromRGB(64, 28, 102),   -- dark purple
	cases    = Color3.fromRGB(150, 66, 16),   -- dark orange
	shop     = Color3.fromRGB(140, 100, 22),  -- gold / amber
	settings = Color3.fromRGB(36, 66, 104),   -- steel blue
	play     = Color3.fromRGB(42, 82, 20),    -- toxic green (dark)
	summary  = Color3.fromRGB(120, 30, 22),   -- blood red
}

function UITheme.Darker(c: Color3, f: number): Color3
	return Color3.new(c.R * (1 - f), c.G * (1 - f), c.B * (1 - f))
end

-- ===== RESPONSIVE SCALE =====
-- Designed at 1920×1080. scale = min(vw/1920, vh/1080) clamped [0.55, 1.3]; touch devices get a small
-- bump so targets stay finger-sized. One UIScale per ScreenGui, updated live on viewport changes.
local BASE_W, BASE_H = 1920, 1080
UITheme.UIScaleMult = 1.5 -- GLOBAL in-game size dial: every attached ScreenGui renders this much bigger

local function computeScale(): number
	local cam = Workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(BASE_W, BASE_H)
	local s = math.clamp(math.min(vp.X / BASE_W, vp.Y / BASE_H), 0.55, 1.3)
	-- Touch bump AFTER the clamp — applied before, the 0.55 floor swallowed it on exactly the small
	-- phones it exists for (the audit's dead-touch-bump bug).
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		s *= 1.12 -- phones: slightly larger for touch targets
	end
	return s * UITheme.UIScaleMult
end

function UITheme.Attach(gui: ScreenGui): UIScale
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Scale = computeScale()
	scale.Parent = gui
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			scale.Scale = computeScale()
		end)
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCam = Workspace.CurrentCamera
		if newCam then
			scale.Scale = computeScale()
			newCam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				scale.Scale = computeScale()
			end)
		end
	end)
	return scale
end

-- ===== BUILD HELPERS =====
-- CHANGED: chunky simulator-style roundness — every radius in the game runs through this curve,
-- so the whole UI got rounder in one place (6->13, 8->16, 5->11...). Dial with CORNER_MULT.
local CORNER_MULT = 1.8
function UITheme.Corner(o: Instance, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, math.floor((r or 5) * CORNER_MULT + 2))
	c.Parent = o
	return c
end

-- Hard black outer edge — the gritty silhouette every panel/button gets.
function UITheme.Edge(o: Instance, color: Color3?, thickness: number?, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color or UITheme.BLACK
	s.Thickness = thickness or 2.5
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = o
	return s
end

-- Vertical depth gradient (subtle light top → dark bottom) for panel bodies and button fills.
function UITheme.Depth(o: Instance, strength: number?)
	local g = Instance.new("UIGradient")
	local k = strength or 0.22
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(1 - k, 1 - k, 1 - k)),
	})
	g.Rotation = 90
	g.Parent = o
	return g
end

-- The STUD backdrop: a tiled, slightly-darker layer over the panel color. Parent frame should clip.
function UITheme.Studs(frame: GuiObject, tile: number?, transparency: number?)
	frame.ClipsDescendants = true
	local img = Instance.new("ImageLabel")
	img.Name = "Studs"
	img.BackgroundTransparency = 1
	img.Image = UITheme.StudsTexture
	img.ScaleType = Enum.ScaleType.Tile
	img.TileSize = UDim2.fromOffset(tile or 42, tile or 42)
	img.ImageColor3 = UITheme.Darker(frame.BackgroundColor3, 0.45)
	img.ImageTransparency = transparency or 0.62
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = frame.ZIndex
	img.Parent = frame
	return img
end

-- A themed panel: dark body, studs, depth, hard edge. Content sits above the studs automatically
-- (siblings created after render above).
function UITheme.Panel(parent: Instance, name: string?, opts: any?)
	opts = opts or {}
	local f = Instance.new("Frame")
	f.Name = name or "Panel"
	f.BackgroundColor3 = opts.color or UITheme.PANEL
	f.BackgroundTransparency = opts.alpha or UITheme.PanelAlpha
	f.BorderSizePixel = 0
	f.Parent = parent
	UITheme.Corner(f, opts.radius or 6)
	UITheme.Edge(f, opts.edge or UITheme.BLACK, opts.edgeThickness or 2)
	if opts.accent then
		UITheme.Edge(f, opts.accent, 2.5, 0.05) -- the panel's OUTLINE = the accent color (matches the header bar)
	end
	if opts.studs ~= false then
		UITheme.Studs(f, opts.tile, opts.studsAlpha)
	end
	if opts.depth ~= false then
		UITheme.Depth(f)
	end
	return f
end

-- Stencil header text (Black Ops One), uppercase, black-outlined.
function UITheme.Title(parent: Instance, name: string?, size: number?, color: Color3?)
	local l = Instance.new("TextLabel")
	l.Name = name or "Title"
	l.BackgroundTransparency = 1
	l.FontFace = UITheme.TitleFace
	l.TextSize = size or 22
	l.TextColor3 = color or UITheme.TEXT
	l.Text = ""
	l.Parent = parent
	local s = Instance.new("UIStroke")
	s.Color = UITheme.BLACK
	s.Thickness = 3 -- thick sticker outline (the cartoon look)
	s.Transparency = 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = l
	return l
end

-- Body text (Orbitron).
function UITheme.Label(parent: Instance, name: string?, size: number?, color: Color3?, bold: boolean?)
	local l = Instance.new("TextLabel")
	l.Name = name or "Label"
	l.BackgroundTransparency = 1
	l.FontFace = bold and UITheme.BodyBoldFace or UITheme.BodyFace
	l.TextSize = size or 14
	l.TextColor3 = color or UITheme.TEXT
	l.Text = ""
	l.Parent = parent
	return l
end

-- The panel header strip: toxic tab on the left, stencil title, hairline underneath.
-- ONE height (Space.Header=48) and ONE title size (Type.Screen=28) product-wide; the title's right
-- margin reserves a slot for the standard close button (UITheme.Close) INSIDE the bar.
function UITheme.Header(panel: GuiObject, titleText: string, height: number?, accent: Color3?, barColor: Color3?)
	local h = height or UITheme.Space.Header
	local col = accent or UITheme.TOXIC
	-- Solid colored TOP BAR (per-screen identity). Rounded top corners, squared bottom via a cover strip.
	if barColor then
		local bar = Instance.new("Frame")
		bar.Name = "HeaderBar"
		bar.Position = UDim2.fromOffset(0, 0)
		bar.Size = UDim2.new(1, 0, 0, h)
		bar.BackgroundColor3 = barColor
		bar.BorderSizePixel = 0
		bar.ZIndex = 1
		bar.Parent = panel
		UITheme.Corner(bar, 6)
		local grad = Instance.new("UIGradient") -- faint sheen: flat top -> slightly darker bottom
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.new(0.82, 0.82, 0.82)),
		})
		grad.Rotation = 90
		grad.Parent = bar
		local squareOff = Instance.new("Frame") -- straighten the bar's bottom edge
		squareOff.AnchorPoint = Vector2.new(0, 1)
		squareOff.Position = UDim2.new(0, 0, 1, 0)
		squareOff.Size = UDim2.new(1, 0, 0, math.floor(h / 2))
		squareOff.BackgroundColor3 = barColor
		squareOff.BorderSizePixel = 0
		squareOff.ZIndex = 1
		squareOff.Parent = bar
		local under = Instance.new("Frame") -- thin dark seam under the bar
		under.AnchorPoint = Vector2.new(0, 1)
		under.Position = UDim2.new(0, 0, 1, 0)
		under.Size = UDim2.new(1, 0, 0, 2)
		under.BackgroundColor3 = UITheme.BLACK
		under.BackgroundTransparency = 0.2
		under.BorderSizePixel = 0
		under.ZIndex = 2
		under.Parent = bar
	end
	local tab = Instance.new("Frame")
	tab.Name = "HeaderTab"
	tab.Position = UDim2.fromOffset(0, 10)
	tab.Size = UDim2.fromOffset(5, h - 20)
	tab.BackgroundColor3 = barColor and UITheme.TEXT or col
	tab.BorderSizePixel = 0
	tab.ZIndex = 2
	tab.Parent = panel
	local title = UITheme.Title(panel, "HeaderTitle", UITheme.Type.Screen, UITheme.TEXT)
	title.ZIndex = 2
	title.Position = UDim2.fromOffset(18, 0)
	title.Size = UDim2.new(1, -18 - UITheme.Ctl.Std - 20, 0, h) -- right margin reserves the close-button slot
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = string.upper(titleText)
	if not barColor then
		local line = Instance.new("Frame")
		line.Name = "HeaderLine"
		line.Position = UDim2.new(0, 12, 0, h)
		line.Size = UDim2.new(1, -24, 0, 1)
		line.BackgroundColor3 = UITheme.LINE
		line.BackgroundTransparency = 0.35
		line.BorderSizePixel = 0
		line.Parent = panel
	end
	return title
end

-- THE close button — one size (Ctl.Std=44), one placement: inside the header bar, right side,
-- vertically centered. Every panel uses this instead of hand-rolling its own X.
function UITheme.Close(panel: GuiObject): TextButton
	local size = UITheme.Ctl.Std
	local b = Instance.new("TextButton")
	b.Name = "CloseButton"
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -8, 0, math.floor((UITheme.Space.Header - size) / 2))
	b.Size = UDim2.fromOffset(size, size)
	b.BackgroundColor3 = Color3.fromRGB(224, 34, 34)
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.ZIndex = 3
	b.Parent = panel
	UITheme.Corner(b, 6)
	UITheme.Edge(b, UITheme.BLACK, 2.5)
	UITheme.WhiteX(b)
	local red = Color3.fromRGB(224, 34, 34)
	b.BackgroundColor3 = Color3.new(1, 1, 1)
	local g = Instance.new("UIGradient") -- same one-surface fill as UITheme.Button
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, red:Lerp(Color3.new(1, 1, 1), 0.42)),
		ColorSequenceKeypoint.new(0.07, red:Lerp(Color3.new(1, 1, 1), 0.18)),
		ColorSequenceKeypoint.new(1, UITheme.Darker(red, 0.28)),
	})
	g.Rotation = 90
	g.Parent = b
	return b
end

-- Draw a white X inside a button (two rotated bars) — robust vs fonts that lack the ✕ glyph.
function UITheme.WhiteX(button: GuiObject, thickness: number?)
	button.Text = ""
	local t = thickness or 3
	for _, rot in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.new(0.5, 0, 0, t)
		bar.Rotation = rot
		bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		bar.BorderSizePixel = 0
		bar.ZIndex = (button.ZIndex or 1) + 2
		bar.Parent = button
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = bar
	end
end

-- Vertical shade for cards: multiplies the fill darker toward the BOTTOM (a subtle 3D drop).
function UITheme.CardShade(frame: GuiObject, strength: number?)
	local k = strength or 0.4
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(1 - k, 1 - k, 1 - k)),
	})
	g.Rotation = 90
	g.Parent = frame
	return g
end

-- NEW: turn a (square) button into an ICON button — an inset image that the studded plate frames,
-- an optional small caption under it (also the graceful fallback if the image id ever fails to load),
-- and an optional keybind badge top-left. Clears the button's own Text. Returns the ImageLabel.
-- opts = { inset?, caption?, captionColor?, badge?, badgeColor?, iconColor? }
-- iconColor tints the image (multiply) so a white/plain icon blends into the palette — defaults to TOXIC.
function UITheme.Icon(button: GuiObject, imageId: string, opts: any?)
	opts = opts or {}
	if button:IsA("TextButton") or button:IsA("TextLabel") then
		button.Text = ""
	end
	local pad = opts.inset or 9
	local capH = opts.caption and 14 or 0
	local img = Instance.new("ImageLabel")
	img.Name = "Icon"
	img.BackgroundTransparency = 1
	img.Image = imageId
	img.ImageColor3 = opts.iconColor or Color3.new(1, 1, 1) -- WHITE icon (the sticker look)
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0)
	img.Position = UDim2.new(0.5, 0, 0, pad)
	img.Size = UDim2.new(1, -pad * 2, 1, -pad * 2 - capH)
	img.Parent = button
	-- Caption = Type.Caption; the badge NEVER exceeds it (rule 2 of the scale). Caption scales down
	-- rather than clipping ("SKIN CRATES" used to truncate on both sides).
	if opts.caption then
		local cap = UITheme.Label(button, "IconCaption", UITheme.Type.Caption, opts.captionColor or UITheme.TEXT, true)
		cap.BackgroundColor3 = Color3.fromRGB(5, 10, 3) -- dark strip so the caption reads on any plate
		cap.BackgroundTransparency = 0.45
		local capCorner = Instance.new("UICorner")
		capCorner.CornerRadius = UDim.new(0, 5)
		capCorner.Parent = cap
		cap.AnchorPoint = Vector2.new(0.5, 1)
		cap.Position = UDim2.new(0.5, 0, 1, -5)
		cap.Size = UDim2.new(1, -6, 0, capH)
		cap.TextXAlignment = Enum.TextXAlignment.Center
		cap.TextScaled = true
		local cc = Instance.new("UITextSizeConstraint")
		cc.MaxTextSize = UITheme.Type.Caption
		cc.Parent = cap
		cap.Text = opts.caption
	end
	if opts.badge then
		-- keybind CHIP hanging off the top-left corner (was loose text floating on the icon)
		local bd = UITheme.Label(button, "IconBadge", UITheme.Type.Caption, opts.badgeColor or UITheme.GOLD, true)
		bd.BackgroundColor3 = Color3.fromRGB(28, 36, 21)
		bd.BackgroundTransparency = 0
		bd.Position = UDim2.fromOffset(-7, -7)
		bd.AutomaticSize = Enum.AutomaticSize.X
		bd.Size = UDim2.fromOffset(0, 20)
		bd.TextXAlignment = Enum.TextXAlignment.Center
		local bdPad = Instance.new("UIPadding")
		bdPad.PaddingLeft = UDim.new(0, 6); bdPad.PaddingRight = UDim.new(0, 6)
		bdPad.Parent = bd
		local bdCorner = Instance.new("UICorner")
		bdCorner.CornerRadius = UDim.new(0, 6)
		bdCorner.Parent = bd
		UITheme.Edge(bd, UITheme.BLACK, 2)
		bd.ZIndex = (button.ZIndex or 1) + 2
		bd.Text = opts.badge
	end
	return img
end

-- A chunky action button: gradient fill, black edge, stencil label, press-pop.
-- variant: "primary" (toxic) | "danger" (orange) | "ghost" (dark) | "gold"
function UITheme.Button(parent: Instance, textStr: string, variant: string?)
	local fills = { -- text is WHITE + black outline on every colored fill (sticker style)
		primary = { UITheme.TOXIC, UITheme.TOXIC_DK, Color3.new(1, 1, 1) },
		danger = { UITheme.ORANGE, UITheme.ORANGE_DK, Color3.new(1, 1, 1) },
		gold = { UITheme.GOLD, UITheme.Darker(UITheme.GOLD, 0.45), Color3.new(1, 1, 1) },
		-- ghost buttons sit ON PANEL2 panes — they need a visibly lighter fill or they read as black
		ghost = { Color3.fromRGB(54, 60, 42), Color3.fromRGB(42, 47, 33), UITheme.TEXT },
	}
	local fill = fills[variant or "primary"] or fills.primary
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = fill[1]
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.FontFace = UITheme.TitleFace
	b.TextSize = UITheme.Type.Section -- CTA text: 18, unmissable on the big 56px buttons
	b.TextColor3 = fill[3]
	b.Text = string.upper(textStr)
	b.Parent = parent
	-- ARCHITECTURE: the TextButton itself is the dark SLAB (so layouts see ONE element); a child "Face"
	-- carries the bright surface, and the visible text lives ON the face (a parent's own text renders
	-- under its children). The face slides down on press. No sibling frames — layout-safe.
	local white = Color3.new(1, 1, 1)
	local base = fill[1]
	b.BackgroundColor3 = UITheme.Darker(fill[2], 0.35) -- slab color
	b.TextTransparency = 1 -- real text is mirrored onto the face's label
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 10)
	bc.Parent = b
	UITheme.Edge(b, UITheme.BLACK, 3)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -5) -- the slab shows as a 5px lip below
	face.BackgroundColor3 = white
	face.BorderSizePixel = 0
	face.Parent = b
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 10)
	fc.Parent = face
	UITheme.Edge(face, UITheme.BLACK, 2.5) -- the face needs its OWN black ring (it covers the slab's)
	local g = Instance.new("UIGradient") -- gradients only multiply, so the face is white and the
	g.Color = ColorSequence.new({        -- gradient carries ABSOLUTE colors (bright top flash baked in)
		ColorSequenceKeypoint.new(0, base:Lerp(white, 0.42)),
		ColorSequenceKeypoint.new(0.07, base:Lerp(white, 0.18)),
		ColorSequenceKeypoint.new(1, UITheme.Darker(base, 0.28)),
	})
	g.Rotation = 90
	g.Parent = face

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = b.FontFace
	label.TextSize = b.TextSize
	label.TextColor3 = fill[3]
	label.Text = b.Text
	label.Parent = face
	local ts = Instance.new("UIStroke")
	ts.Color = UITheme.BLACK
	ts.Thickness = 2.5
	ts.Transparency = 0
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = label
	-- Callers keep talking to the BUTTON (b.Text / b.TextSize / b.TextColor3); the face label mirrors.
	b:GetPropertyChangedSignal("Text"):Connect(function()
		label.Text = b.Text
	end)
	b:GetPropertyChangedSignal("TextSize"):Connect(function()
		label.TextSize = b.TextSize
	end)
	b:GetPropertyChangedSignal("TextColor3"):Connect(function()
		label.TextColor3 = b.TextColor3
	end)

	if variant == "ghost" then
		UITheme.Edge(b, UITheme.LINE, 1, 0.5)
	end
	-- Press = the face slides DOWN onto the slab.
	b.MouseButton1Down:Connect(function()
		face.Position = UDim2.fromOffset(0, 4)
	end)
	local function up()
		face.Position = UDim2.new()
	end
	b.MouseButton1Up:Connect(up)
	b.MouseLeave:Connect(up)
	return b
end

-- Gray a themed button out (or restore it). The original fill/text colors are stashed in attributes
-- on first disable so re-enabling actually restores them (the old version restored nothing).
function UITheme.SetButtonEnabled(b: TextButton, enabled: boolean, disabledText: string?)
	local face = b:FindFirstChild("Face")
	local target = face or b
	local g = target:FindFirstChildOfClass("UIGradient")
	if enabled then
		b.AutoButtonColor = false
		b.TextTransparency = 0
		if g then g.Enabled = true end
		local bg, tc = b:GetAttribute("EnabledBG"), b:GetAttribute("EnabledText")
		if typeof(bg) == "Color3" then target.BackgroundColor3 = bg end
		if typeof(tc) == "Color3" then b.TextColor3 = tc end
	else
		if b:GetAttribute("EnabledBG") == nil then
			b:SetAttribute("EnabledBG", target.BackgroundColor3)
			b:SetAttribute("EnabledText", b.TextColor3)
		end
		if g then g.Enabled = false end
		target.BackgroundColor3 = UITheme.TRACK
		b.TextColor3 = UITheme.DIM
		if disabledText then
			b.Text = string.upper(disabledText)
		end
	end
end

-- A progress/health bar: recessed track + gradient fill. Returns (track, fill).
function UITheme.Bar(parent: Instance, name: string?, color: Color3?)
	local track = Instance.new("Frame")
	track.Name = name or "Bar"
	track.BackgroundColor3 = UITheme.Darker(UITheme.TRACK, 0.25)
	track.BorderSizePixel = 0
	track.Parent = parent
	UITheme.Corner(track, 3)
	UITheme.Edge(track, UITheme.BLACK, 1, 0.35)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = color or UITheme.TOXIC
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = track
	UITheme.Corner(fill, 3)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 150, 150))
	g.Rotation = 90
	g.Parent = fill
	return track, fill
end

-- Big-panel drop shadow: a soft dark plate parented INTO a transparent wrapper below the body.
-- Use for the large center panels (inventory/draft/shop): wrapper = Shadowed(parent, ...), build into .Body.
local SHADOW_IMG = "rbxassetid://1316045217"
function UITheme.Shadowed(parent: Instance, name: string, opts: any?)
	local wrap = Instance.new("Frame")
	wrap.Name = name
	wrap.BackgroundTransparency = 1
	wrap.Parent = parent
	local shadow = Instance.new("ImageLabel")
	shadow.Name = "Shadow"
	shadow.BackgroundTransparency = 1
	shadow.Image = SHADOW_IMG
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.45
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(10, 10, 118, 118)
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 0, 0.5, 6)
	shadow.Size = UDim2.new(1, 36, 1, 36)
	shadow.ZIndex = 0
	shadow.Parent = wrap
	local body = UITheme.Panel(wrap, "Body", opts)
	body.Size = UDim2.fromScale(1, 1)
	body.ZIndex = 1
	return wrap, body
end

return UITheme
