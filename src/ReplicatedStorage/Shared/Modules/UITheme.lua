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
local FALLBACK_TITLE = Enum.Font.Sarpanch  -- squared military-tech (until the real id is pasted)
local FALLBACK_BODY  = Enum.Font.Michroma  -- wide geometric (closest built-in to Orbitron)

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

-- Studs backdrop texture (tileable). Swap the id if you prefer another studs decal.
UITheme.StudsTexture = "rbxassetid://6965996718"

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
	local s = math.min(vp.X / BASE_W, vp.Y / BASE_H)
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		s *= 1.12 -- phones: slightly larger for touch targets
	end
	return math.clamp(s, 0.55, 1.3) * UITheme.UIScaleMult
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
function UITheme.Corner(o: Instance, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 5)
	c.Parent = o
	return c
end

-- Hard black outer edge — the gritty silhouette every panel/button gets.
function UITheme.Edge(o: Instance, color: Color3?, thickness: number?, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color or UITheme.BLACK
	s.Thickness = thickness or 2
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
	f.BackgroundTransparency = opts.alpha or 0
	f.BorderSizePixel = 0
	f.Parent = parent
	UITheme.Corner(f, opts.radius or 6)
	UITheme.Edge(f, opts.edge or UITheme.BLACK, opts.edgeThickness or 2)
	if opts.accent then
		UITheme.Edge(f, opts.accent, 1, 0.45) -- inner colored line over the black edge
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
	s.Thickness = 1.6
	s.Transparency = 0.15
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
function UITheme.Header(panel: GuiObject, titleText: string, height: number?, accent: Color3?)
	local h = height or 44
	local col = accent or UITheme.TOXIC
	local tab = Instance.new("Frame")
	tab.Name = "HeaderTab"
	tab.Position = UDim2.fromOffset(0, 10)
	tab.Size = UDim2.fromOffset(5, h - 20)
	tab.BackgroundColor3 = col
	tab.BorderSizePixel = 0
	tab.Parent = panel
	local title = UITheme.Title(panel, "HeaderTitle", 22, UITheme.TEXT)
	title.Position = UDim2.fromOffset(18, 0)
	title.Size = UDim2.new(1, -36, 0, h)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = string.upper(titleText)
	local line = Instance.new("Frame")
	line.Name = "HeaderLine"
	line.Position = UDim2.new(0, 12, 0, h)
	line.Size = UDim2.new(1, -24, 0, 1)
	line.BackgroundColor3 = UITheme.LINE
	line.BackgroundTransparency = 0.35
	line.BorderSizePixel = 0
	line.Parent = panel
	return title
end

-- A chunky action button: gradient fill, black edge, stencil label, press-pop.
-- variant: "primary" (toxic) | "danger" (orange) | "ghost" (dark) | "gold"
function UITheme.Button(parent: Instance, textStr: string, variant: string?)
	local fills = {
		primary = { UITheme.TOXIC, UITheme.TOXIC_DK, Color3.fromRGB(14, 26, 4) },
		danger = { UITheme.ORANGE, UITheme.ORANGE_DK, Color3.fromRGB(30, 10, 3) },
		gold = { UITheme.GOLD, UITheme.Darker(UITheme.GOLD, 0.45), Color3.fromRGB(34, 24, 6) },
		-- ghost buttons sit ON PANEL2 panes — they need a visibly lighter fill or they read as black
		ghost = { Color3.fromRGB(54, 60, 42), Color3.fromRGB(42, 47, 33), UITheme.TEXT },
	}
	local fill = fills[variant or "primary"] or fills.primary
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = fill[1]
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.FontFace = UITheme.TitleFace
	b.TextSize = 15
	b.TextColor3 = fill[3]
	b.Text = string.upper(textStr)
	b.Parent = parent
	UITheme.Corner(b, 5)
	UITheme.Edge(b, UITheme.BLACK, 2)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(fill[1], fill[2])
	g.Rotation = 90
	g.Parent = b
	if variant == "ghost" then
		UITheme.Edge(b, UITheme.LINE, 1, 0.5)
	end
	-- Press pop (scale dip on press, spring back on release).
	local ps = Instance.new("UIScale")
	ps.Parent = b
	b.MouseButton1Down:Connect(function()
		TweenService:Create(ps, TweenInfo.new(0.06), { Scale = 0.94 }):Play()
	end)
	local function up()
		TweenService:Create(ps, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	b.MouseButton1Up:Connect(up)
	b.MouseLeave:Connect(up)
	return b
end

-- Gray a themed button out (or restore it).
function UITheme.SetButtonEnabled(b: TextButton, enabled: boolean, disabledText: string?)
	local g = b:FindFirstChildOfClass("UIGradient")
	if enabled then
		b.AutoButtonColor = false
		b.TextTransparency = 0
		if g then g.Enabled = true end
		b.BackgroundColor3 = b.BackgroundColor3
	else
		if g then g.Enabled = false end
		b.BackgroundColor3 = UITheme.TRACK
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
