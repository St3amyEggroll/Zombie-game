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
local BODY_FACE  = makeFace(FONT_IDS.Body, Enum.FontWeight.Medium, Enum.Font.FredokaOne)
local BODYB_FACE = makeFace(FONT_IDS.Body, Enum.FontWeight.Bold, Enum.Font.FredokaOne)

local PANEL   = Color3.fromRGB(21, 24, 17)
local PANEL2  = Color3.fromRGB(29, 33, 23)
local TRACK   = Color3.fromRGB(36, 41, 28)
local LINE    = Color3.fromRGB(74, 82, 56)
local TBLACK  = Color3.fromRGB(6, 7, 5)
local ACCENT  = Color3.fromRGB(124, 219, 35)   -- toxic green
local ORANGE  = Color3.fromRGB(255, 96, 34)    -- blood orange
local ORANGE_DK = Color3.fromRGB(150, 44, 12)
local TEXTCOL = Color3.fromRGB(222, 227, 209)
local DIMTEXT = Color3.fromRGB(134, 142, 116)
local GOLD    = Color3.fromRGB(230, 180, 76)
local DIM = TRACK          -- (legacy name: disabled-button fill)
local CARD = PANEL2        -- (legacy name: card/button fill)
local SELBG = Color3.fromRGB(98, 182, 28) -- selected-button fill: BRIGHT toxic — the old dark shade rendered the same as unselected through the face gradient
local STUDS_TEXTURE = "rbxassetid://6965996718"

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
	img.Image = STUDS_TEXTURE
	img.ScaleType = Enum.ScaleType.Tile
	img.TileSize = UDim2.fromOffset(tile or 42, tile or 42)
	img.ImageColor3 = darker(frame.BackgroundColor3, 0.45)
	img.ImageTransparency = transparency or 0.62
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = frame.ZIndex
	img.Parent = frame
	return img
end
-- Responsive: one live UIScale per ScreenGui (designed 1920x1080, clamped, touch bump).
local UserInputService = game:GetService("UserInputService")
local UI_SCALE_MULT = 1.2 -- GLOBAL lobby size dial (game place uses its own in UITheme)
local function lattach(screenGui)
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	local function compute()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		local sc = math.clamp(math.min(vp.X / 1920, vp.Y / 1080), 0.55, 1.3)
		-- touch bump AFTER the clamp — applied before, the 0.55 floor swallowed it on small phones
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			sc *= 1.12
		end
		return sc * UI_SCALE_MULT
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

local sel = { map = "forest", difficulty = "easy", size = 1 }
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
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -5) -- the slab shows as a 5px lip below
	face.BackgroundColor3 = white
	face.BorderSizePixel = 0
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
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.FontFace = o.FontFace
		label.TextSize = o.TextSize
		label.TextColor3 = o.TextColor3
		label.Text = o.Text
		label.Parent = face
		local ls = Instance.new("UIStroke")
		ls.Color = TBLACK
		ls.Thickness = 3 -- wide sticker outline on the text, like LEAVE / SKIP WAVE
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
		bar.Size = UDim2.new(0.55, 0, 0, math.max(4, math.floor(size / 9))); bar.Rotation = rot
		bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255); bar.BorderSizePixel = 0; bar.ZIndex = 5; bar.Parent = x
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
local HEADER_COLORS = {
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
-- HEADER BAR wider than the body (big white title with a NAVY outline on the left, the red X sitting
-- INSIDE the bar's right end) and the dark BODY panel tucked underneath it. Everything lives inside
-- the root, so the header can never hang off-screen. Toggle the BODY's Visible (callers own it) and
-- mirror it onto the root. Returns root, body, title, closeX, recolor(c).
local NAVY = Color3.fromRGB(21, 36, 58) -- the reference title outline is navy, not black
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
	ts.Color = NAVY
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
local UI_FOV_PUSH, UI_FOV_EASE = 6, 6
local uiOpenCount, uiBaseFov = 0, nil
do
	RunService.RenderStepped:Connect(function(dt)
		local cam = workspace.CurrentCamera
		if not cam or uiBaseFov == nil then return end
		local target = (uiOpenCount > 0) and (uiBaseFov + UI_FOV_PUSH) or uiBaseFov
		local a = math.clamp(dt * UI_FOV_EASE, 0, 1)
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
	ReelTick      = "", -- each case-reel tile passing [tick]
	RevealLow     = "", -- common/uncommon/rare pull [small reward sting]
	RevealHigh    = "", -- epic/legendary pull [big reward sting]
	RevealJackpot = "", -- mythic/divine or NEW GUN [jackpot fanfare]
	TeleportGo    = "", -- party countdown ends [teleport whoosh]
}
local SOUND_VOL = { -- base volume per slot (before the sliders)
	Music = 0.45, Click = 0.4, ReelTick = 0.35, RevealJackpot = 0.8,
}

local volMaster, volMusic, volSfx = 1, 0.6, 1
local volTouched = false -- true once the player moves a slider (server echoes stop overriding)

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
	s.Volume = (SOUND_VOL[name] or 0.5) * volMaster * volSfx
	if pitch then s.PlaybackSpeed = pitch end
	s.Parent = SoundService
	s.Ended:Once(function() s:Destroy() end)
	task.delay(15, function() if s.Parent then s:Destroy() end end)
	s:Play()
end

local lobbyMusic = nil
local function applySoundVol()
	if lobbyMusic then
		lobbyMusic.Volume = (SOUND_VOL.Music or 0.45) * volMaster * volMusic
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
local volSaveAt = 0
local function queueVolSave()
	volSaveAt = os.clock() + 0.6
	task.delay(0.65, function()
		if os.clock() >= volSaveAt then
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
lattach(gui)

-- Coins: V2-A — a dark rounded pill floating MID-LEFT, coin icon + gold number, sitting just above
-- the LEVEL card (which is also mid-left now). Auto-sizes to the number.
local COIN_ICON_ID = "rbxassetid://84729396970772"
local coinsRow = Instance.new("Frame")
coinsRow.AnchorPoint = Vector2.new(0, 0.5); coinsRow.Position = UDim2.new(0, 16, 0.5, -45)
coinsRow.Size = UDim2.fromOffset(0, 54); coinsRow.AutomaticSize = Enum.AutomaticSize.X
coinsRow.BackgroundColor3 = Color3.fromRGB(10, 8, 16); coinsRow.BackgroundTransparency = 0.28
coinsRow.BorderSizePixel = 0; coinsRow.Parent = gui
corner(coinsRow, 27); ledge(coinsRow, Color3.new(1, 1, 1), 1.5, 0.86)
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
panel.Size = UDim2.fromOffset(600, 490); panel.BackgroundColor3 = PANEL -- taller: square map photo buttons
panel.BackgroundTransparency = 0.12; panel.BorderSizePixel = 0; panel.Visible = false; panel.Parent = gui
corner(panel, 8)
lstuds(panel); ldepth(panel); ledge(panel, TBLACK, 3); ledge(panel, HEADER_COLORS.play, 2.5, 0.05)

local title = Instance.new("TextLabel")
title.Position = UDim2.new(0, 0, 0, 0); title.Size = UDim2.new(1, 0, 0, 48); title.BackgroundTransparency = 1
title.FontFace = TITLE_FACE; title.TextSize = 28; title.TextColor3 = TEXTCOL
headerBar(panel, 48, HEADER_COLORS.play)
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
local diffLbl = sectionLabel("DIFFICULTY", 210)
local diffRow = row(234, 52)
local sizeLbl = sectionLabel("PARTY SIZE", 298)
local sizeRow = row(322, 48)


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

local mapBtns, diffBtns, sizeBtns = {}, {}, {}

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
	status.Text = ("%s  ·  %s  ·  PARTY OF %d"):format(
		cap(sel.map or "?"):upper(), cap(sel.difficulty or "?"):upper(), tonumber(sel.size) or 1)
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
	-- difficulty buttons
	for _, b in diffBtns do b:Destroy() end
	diffBtns = {}
	local worldInfo = unlocks.worlds[sel.map]
	for _, d in unlocks.order do
		local unlocked = worldInfo and worldInfo.diffs[d]
		local b = button(diffRow, 100, 48, unlocked and cap(d) or (cap(d) .. " 🔒")) -- 94px: five fit (incl. Endless)
		b.LayoutOrder = #diffBtns + 1
		if not unlocked then
			b.AutoButtonColor = false; b.BackgroundColor3 = DIM; b.TextColor3 = Color3.fromRGB(150, 150, 160)
		else
			b.BackgroundColor3 = (sel.difficulty == d) and SELBG or CARD
			b.TextColor3 = TEXTCOL -- selection shows in the fill, text stays normal
		end
		b.Activated:Connect(function()
			if unlocked then sel.difficulty = d; refresh() end
		end)
		table.insert(diffBtns, b)
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

-- default difficulty = first unlocked for the selected map
local function pickDefaultDifficulty()
	local info = unlocks and unlocks.worlds[sel.map]
	if info then
		for _, d in unlocks.order do
			if info.diffs[d] then sel.difficulty = d; return end
		end
	end
end

-- Show/hide the three pad-UI modes inside the one panel.
local function setPanelMode(mode)
	zoneMode = mode
	local config = (mode == "config")
	mapLbl.Visible = config; mapRow.Visible = config
	diffLbl.Visible = config; diffRow.Visible = config
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
	if not volTouched and typeof(s.settings) == "table" and typeof(s.settings.vol) == "table" then
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
			pickDefaultDifficulty()
		end
		sel.size = 1
		setPanelMode("config")
		refresh()
	elseif p.mode == "party" then
		setPanelMode("party")
		leaveStatus.Text = ("%s  ·  %s  —  waiting for players..."):format(cap(p.map or "?"), cap(p.difficulty or "?"))
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
		FinalizeParty:FireServer({ map = sel.map, difficulty = sel.difficulty, size = sel.size })
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

local BLACK = darker(PANEL, 0.5)

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
	local function renderRow(snap)
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
					end
					sl.vpId = id
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
local GUN_ICON = "rbxassetid://107465960874017"
local CASES_ICON = "rbxassetid://83465359983310"
local dockBtns = {} -- every dock button + badge, one table (200-local ceiling)
do
	local DOCK_ICONS = { -- paste your photo ids here ("rbxassetid://..." or the number). "" = emoji.
		inventory = "119161862051444",
		weapons = "102091580612843",
		daily = "85053185478907",
		shop = "71412141929869",
		pass = "",
		settings = "94140673883223",
		codes = "106591567271932",
	}
	local DOCK_EMOJI = { inventory = "🎒", weapons = "🔫", daily = "🎡", shop = "🧺", pass = "🏅", settings = "⚙️", codes = "🔑" }
	local ORDER = { "inventory", "weapons", "daily", "shop", "pass", "settings", "codes" }
	local LABELS = { inventory = "Inventory", weapons = "Weapons", daily = "Daily", shop = "Shop", pass = "Pass", settings = "Settings", codes = "Codes" }

	-- The faded black bar behind everything (pure gradient, no border — melts into the floor).
	local fade = Instance.new("Frame")
	fade.Name = "DockFade"
	fade.AnchorPoint = Vector2.new(0, 1)
	fade.Position = UDim2.new(0, 0, 1, 0)
	fade.Size = UDim2.new(1, 0, 0, 170)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BorderSizePixel = 0
	fade.ZIndex = 1
	fade.Parent = invGui
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
		holder.Position = UDim2.new(0.5, -282 + (i - 1) * 83, 1, -6)
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
local gunsBtn = dockBtns.weapons -- keep the old names: everything downstream wires to these
local casesBtn = dockBtns.inventory

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
	root, invPanel, invTitle, invClose, invRecolor = chromePanel(invGui, PANEL_W, PANEL_H, HEADER_COLORS.guns, "WEAPONS")
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
	ledge(f, (isSel or opts.nextUp) and GOLD or TBLACK, (isSel or opts.nextUp) and 3.5 or 3)

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

	if opts.chip then -- sticker chip hanging top-left (EQUIPPED toxic / NEXT UP gold / PRIM etc.)
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

-- Themed action button for the detail pane. GHOSTA/GHOSTB sit a step lighter than the pane itself so
-- neutral buttons still read as buttons (they used to use PANEL2-on-PANEL2 and vanished).
local GHOSTA = Color3.fromRGB(54, 60, 42)
local GHOSTB = Color3.fromRGB(42, 47, 33)
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
	ileft.BackgroundColor3 = tint:Lerp(BLACK, 0.72); ileft.BorderSizePixel = 0; ileft.Parent = invDetail
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

	local back = bigButton(ileft, "← BACK", GHOSTA, GHOSTB, TEXTCOL)
	back.Position = UDim2.fromOffset(10, 10); back.Size = UDim2.fromOffset(96, 34); back.TextSize = 14
	back.Activated:Connect(function()
		lplay("Close")
		selectedInv = nil
		renderActive()
	end)

	-- ◀ ▶ flip through the SAME list the grid shows (renderActive stashes it on the snapshot).
	local entries = (invData and invData._entries) or {}
	local function arrow(sym, xOff, dir)
		local a = bigButton(ileft, sym, GHOSTA, GHOSTB, TEXTCOL)
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
			local note = bigButton(invDetail, ("REACH LV %d TO UNLOCK"):format(reqLevel), GHOSTA, GHOSTB, DIMTEXT)
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
				local openAll = paneButton(("OPEN ALL (%d)"):format(count), GHOSTA, GHOSTB, TEXTCOL)
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
			local open = paneButton("NONE LEFT", GHOSTA, GHOSTB, DIMTEXT)
			open.AutoButtonColor = false
			open.Position = UDim2.fromOffset(RIGHT_X, H - 60); open.Size = UDim2.fromOffset(RIGHT_W, 54)
		end
	end
end

-- ===== GRID RENDERS ===== each returns the ordered id list so the pane can default to the first item.
local function renderWeaponsGrid()
	-- EVERY gun shows (locked ones carry their Coin price) — guns are bought, crates only pay skins.
	local ids = {}
	for id in invData.catalog.weapons do
		table.insert(ids, id)
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
			chip = isEq and "EQUIPPED" or ((id == nextUnlockId) and "NEXT UP") or nil,
			subText = owned and ((invData.catalog.rarities[w.rarity] or {}).name or ""):upper() or "",
			locked = not owned,
		})
	end
	return out
end

local function renderCasesGrid()
	-- The INVENTORY screen: the crates you HAVE (only owned ones — no empty placeholders), then your
	-- guns. Skins are NOT separate items — they live on their gun's info sheet as swatches.
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
	local gunIds = {}
	for id in invData.catalog.weapons do
		if ownsGun(id) then
			table.insert(gunIds, id)
		end
	end
	table.sort(gunIds, function(a, b)
		local wa, wb = weaponInfo(a), weaponInfo(b)
		if (wa.unlock or 0) ~= (wb.unlock or 0) then
			return (wa.unlock or 0) < (wb.unlock or 0)
		end
		return a < b
	end)
	for _, id in gunIds do
		local w = weaponInfo(id)
		table.insert(out, { kind = "weapon", id = id })
		local isEq = invData.loadout[1] == id or invData.loadout[2] == id
		invCard({
			kind = "weapon", id = id, name = w.name, color = rarityColor(w.rarity), order = #out,
			image = w.image, chip = isEq and "EQUIPPED" or nil,
			subText = ((invData.catalog.rarities[w.rarity] or {}).name or ""):upper(),
		})
	end
	if #out == 0 then
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.fromOffset(320, 60); msg.BackgroundTransparency = 1; msg.FontFace = BODYB_FACE
		msg.TextSize = 14; msg.TextWrapped = true; msg.TextColor3 = DIMTEXT
		msg.Text = "No crates right now — kill BOSSES in runs (or hit the SHOP stall) to get more!"; msg.Parent = invGrid
	end
	return out
end

-- ===== SCREEN SWITCHING + MASTER RENDER ===== ("weapons" = the GUNS screen, "cases" = the CASES screen)
local function showTab(id)
	activeTab = id
	selectedInv = nil -- switching screens resets the featured pane
	invTitle.Text = (id == "weapons") and "WEAPONS" or "INVENTORY"
	invDetail.Visible = false; invGrid.Visible = true; invHint.Visible = true -- back to GRID mode
	local hc = (id == "weapons") and HEADER_COLORS.guns or Color3.fromRGB(18, 69, 90) -- mockup: blue INVENTORY header
	invRecolor(hc)
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

-- ===== CASE-OPENING REEL (CS:GO-style horizontal scroll) =====
local TILE_W, GAP = 100, 8
local STEP = TILE_W + GAP
local N_TILES = 50
local WIN_INDEX = 44
local REEL_W = 540
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
reel.BorderSizePixel = 0; reel.Visible = false; reel.ZIndex = 5; reel.Parent = reelGui; corner(reel, 8)
lstuds(reel); ledge(reel, TBLACK, 3); ledge(reel, ACCENT, 1, 0.45)
local reelTitle = Instance.new("TextLabel")
reelTitle.Position = UDim2.new(0, 0, 0, 40); reelTitle.Size = UDim2.new(1, 0, 0, 30); reelTitle.BackgroundTransparency = 1
reelTitle.FontFace = TITLE_FACE; reelTitle.TextSize = 18; reelTitle.TextColor3 = DIMTEXT
reelTitle.Text = "OPENING..."; reelTitle.ZIndex = 6; reelTitle.Parent = reel
local window = Instance.new("Frame")
window.AnchorPoint = Vector2.new(0.5, 0.5); window.Position = UDim2.fromScale(0.5, 0.5); window.Size = UDim2.fromOffset(REEL_W, REEL_H)
window.BackgroundColor3 = darker(PANEL, 0.35); window.BorderSizePixel = 0; window.ClipsDescendants = true; window.ZIndex = 6; window.Parent = reel
corner(window, 10)
local strip = Instance.new("Frame")
strip.Position = UDim2.fromOffset(0, 0); strip.Size = UDim2.fromOffset(N_TILES * STEP, REEL_H); strip.BackgroundTransparency = 1; strip.ZIndex = 6; strip.Parent = window
local pointer = Instance.new("Frame")
pointer.AnchorPoint = Vector2.new(0.5, 0.5); pointer.Position = UDim2.fromScale(0.5, 0.5); pointer.Size = UDim2.fromOffset(3, REEL_H)
pointer.BackgroundColor3 = ACCENT; pointer.BorderSizePixel = 0; pointer.ZIndex = 8; pointer.Parent = window
local resultLabel = Instance.new("TextLabel")
resultLabel.AnchorPoint = Vector2.new(0.5, 0); resultLabel.Position = UDim2.new(0.5, 0, 0.5, REEL_H / 2 + 16); resultLabel.Size = UDim2.fromOffset(560, 30)
resultLabel.BackgroundTransparency = 1; resultLabel.FontFace = TITLE_FACE; resultLabel.TextSize = 26; resultLabel.Text = ""
resultLabel.TextColor3 = TEXTCOL; resultLabel.ZIndex = 7; resultLabel.Parent = reel
local reelBtn = Instance.new("TextButton") -- doubles as Skip (while rolling) and Continue (after)
reelBtn.AnchorPoint = Vector2.new(0.5, 1); reelBtn.Position = UDim2.new(0.5, 0, 1, -34); reelBtn.Size = UDim2.fromOffset(200, 44)
reelBtn.BackgroundColor3 = CARD; reelBtn.FontFace = BODYB_FACE; reelBtn.TextSize = 18; reelBtn.TextColor3 = TEXTCOL
reelBtn.Text = "SKIP"; reelBtn.ZIndex = 7; reelBtn.Parent = reel; corner(reelBtn, 8); ledge(reelBtn, TBLACK, 2.5); lbevel(reelBtn)

local activeTween = nil
local finishReel = nil

playReel = function(caseId, wonId, res)
	local disp = invData.catalog.cases[caseId]
	local poolIds = disp and disp.poolIds or { wonId }
	for _, c in strip:GetChildren() do c:Destroy() end
	for i = 1, N_TILES do
		local id = (i == WIN_INDEX) and wonId or poolIds[math.random(1, #poolIds)]
		local info = skinInfo(id) or weaponInfo(id)
		local col = info and rarityColor(info.rarity) or Color3.fromRGB(150, 150, 160)
		local tile = Instance.new("Frame")
		tile.Position = UDim2.fromOffset((i - 1) * STEP, 8); tile.Size = UDim2.fromOffset(TILE_W, REEL_H - 16)
		tile.BackgroundColor3 = col:Lerp(BLACK, 0.5); tile.BorderSizePixel = 0; tile.ZIndex = 6; tile.Parent = strip
		corner(tile, 8)
		local ts = Instance.new("UIStroke"); ts.Color = col; ts.Thickness = 1.5; ts.Parent = tile
		local sInfo = skinInfo(id)
		-- Skin art order: the skin's IMAGE if the owner supplied one, else its model, else the base gun
		-- (tinted when the skin has a tint color).
		local tvp
		if sInfo and sInfo.image then
			tvp = Instance.new("ImageLabel")
			tvp.BackgroundTransparency = 1
			tvp.Image = sInfo.image
			tvp.ScaleType = Enum.ScaleType.Fit
		else
			tvp = makeGunViewport(id, false) or (sInfo and makeGunViewport(sInfo.gun, false, nil, sInfo.tint))
		end
		if tvp then
			tvp.Position = UDim2.new(0, 0, 0, 0); tvp.Size = UDim2.new(1, 0, 1, 0); tvp.ZIndex = 6; tvp.Parent = tile
		end
		local tbar = Instance.new("Frame"); tbar.Position = UDim2.fromOffset(0, 0); tbar.Size = UDim2.new(1, 0, 0, 4)
		tbar.BackgroundColor3 = col; tbar.BorderSizePixel = 0; tbar.ZIndex = 7; tbar.Parent = tile
		local nm = Instance.new("TextLabel")
		nm.Position = UDim2.fromOffset(4, 34); nm.Size = UDim2.new(1, -8, 0, 26); nm.BackgroundTransparency = 1
		nm.FontFace = BODYB_FACE; nm.TextSize = 13; nm.TextColor3 = TEXTCOL
		nm.Text = info and info.name or id; nm.TextScaled = true; nm.ZIndex = 7; nm.Parent = tile
		local rr = Instance.new("TextLabel")
		rr.Position = UDim2.fromOffset(4, 64); rr.Size = UDim2.new(1, -8, 0, 16); rr.BackgroundTransparency = 1
		rr.FontFace = BODY_FACE; rr.TextSize = 11; rr.TextColor3 = col
		rr.Text = info and invData.catalog.rarities[info.rarity].name or ""; rr.TextScaled = true; rr.ZIndex = 7; rr.Parent = tile
	end

	reelTitle.Text = "OPENING " .. (disp and disp.name or "CASE"):upper()
	resultLabel.Text = ""
	reelBtn.Text = "SKIP"; reelBtn.BackgroundColor3 = CARD; reelBtn.TextColor3 = TEXTCOL
	reel.Visible = true

	local jitter = math.random(-10, 10) + (TILE_W * 0.5) * (math.random() - 0.5)
	local target = math.floor(REEL_W / 2 - ((WIN_INDEX - 1) * STEP + TILE_W / 2) + jitter)
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
		if res.unlocked then
			resultLabel.TextColor3 = col
			resultLabel.Text = ("Unlocked %s!"):format(wonName)
		else
			resultLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
			resultLabel.Text = ("Duplicate %s → 🪙 %d"):format(wonName, tonumber(res.coins) or 0)
		end
		reelBtn.Text = "CONTINUE"; reelBtn.BackgroundColor3 = SELBG; reelBtn.TextColor3 = TEXTCOL
		local r = info and info.rarity or "common"
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

	-- Tick as tiles sweep past the pointer (self-disconnects at reveal).
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

reelBtn.Activated:Connect(function()
	if not finishReel then return end
	if reelBtn.Text == "CONTINUE" then
		-- OPEN ALL: chain straight into the next crate while any are queued (and still in stock).
		local q = invPanel:GetAttribute("OpenQueue") or 0
		local qc = invPanel:GetAttribute("QueueCase")
		if q > 0 and typeof(qc) == "string" and invData and (invData.cases[qc] or 0) > 0 then
			invPanel:SetAttribute("OpenQueue", q - 1)
			reel.Visible = false
			armRollTimeout()
			OpenCase:FireServer({ caseId = qc }) -- `rolling` stays true until the chain ends
			return
		end
		reel.Visible = false
		rolling = false
		renderActive()
	else
		finishReel() -- SKIP: snap to the result
	end
end)

-- Watchdog: `rolling` is set the moment an open is requested; if no CaseResult ever arrives (server
-- rejected silently, remote lost), unlock the UI instead of soft-locking the panels until rejoin.
armRollTimeout = function()
	rollToken += 1
	local myToken = rollToken
	task.delay(6, function()
		if rolling and myToken == rollToken and not reel.Visible then
			rolling = false
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
casesBtn.Activated:Connect(function()
	openScreen("cases")
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
	dockBtns.inventoryBadge.Visible = crates > 0
	dockBtns.inventoryBadge.N.Text = crates > 99 and "99+" or tostring(crates)
	if invPanel.Visible then
		renderActive()
	end
end)

CaseResult.OnClientEvent:Connect(function(res)
	rollToken += 1 -- a reply arrived; disarm the watchdog
	if typeof(res) ~= "table" or res.failed or not res.caseId then
		lplay("Error")
		invPanel:SetAttribute("OpenQueue", 0)
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
	-- NEW: server-initiated multi-opens (the Robux pack) ride in with a `chain` count — queue the rest
	-- so CONTINUE opens them back-to-back exactly like OPEN ALL.
	if tonumber(res.chain) and res.chain > 0 then
		invPanel:SetAttribute("QueueCase", res.caseId)
		invPanel:SetAttribute("OpenQueue", res.chain)
	end
	rolling = true -- a reel is on screen (Robux opens arrive without a client-side request)
	playReel(res.caseId, res.wonId, res)
end)

-- =====================================================================================================
-- ===== EXCLUSIVE SHOP ===== the approved TAB MARKET build (per the final mock):
--   · four INDIVIDUAL square tab buttons floating LEFT of the panel — white border, translucent black
--     fill, owner photos (emoji stand-ins until the ids arrive), dimmed when inactive, red ! on DAILY
--     when the free spin is unclaimed
--   · FEATURED — pull ticker, the pack (band/pool/gold footer with BIG open pills + gifts), pity bar
--   · DAILY — the wheel: 8 reward chips in a ring, light-chaser spin, one FREE spin/day + Robux
--     re-spins, streak line (the streak fattens the jackpot slice server-side)
--   · PASSES & COINS — the 3 gamepasses, 4 coin bundles, one-time STARTER PACK
--   · CODES — the redeem bar
-- The header retitles per tab. Everything scoped in this do-block (the 200-local ceiling).
-- =====================================================================================================
do
	local ShopSync   = remotes:WaitForChild("ShopSync")
	local ShopClose  = remotes:WaitForChild("ShopClose")
	local ShopRedeem = remotes:WaitForChild("ShopRedeem")
	local ShopGift   = remotes:WaitForChild("ShopGift")
	local WheelSpin  = remotes:WaitForChild("WheelSpin")
	local ShopTicker = remotes:WaitForChild("ShopTicker")
	local MarketplaceService = game:GetService("MarketplaceService")

	-- ===== TUNABLES =====
	-- (the shop button moved into the DOCK — its image lives in DOCK_ICONS.shop up top)
	local SHOP_GOLD = Color3.fromRGB(240, 165, 10)
	-- The tab buttons' photos: paste one image id per tab ("rbxassetid://..." or the number).
	-- Blank = the emoji stand-in shows until you send the image.
	local TABS = {
		order = { "featured", "daily", "passes", "codes" },
		icons = { featured = "", daily = "", passes = "", codes = "" },
		emoji = { featured = "⭐", daily = "🎡", passes = "🎫", codes = "🔑" },
		titles = { featured = "EXCLUSIVE SHOP", daily = "DAILY WHEEL", passes = "PASSES & COINS", codes = "CODES" },
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

	-- ===== THE TAB BUTTONS ===== individual squares floating LEFT of the panel: white border,
	-- translucent black fill, your photo (emoji until then). Active = bright + thick border.
	S.tabBtns = {}
	for i, id in TABS.order do
		local b = Instance.new("ImageButton")
		b.Name = "Tab_" .. id
		b.Position = UDim2.fromOffset(-88, 56 + (i - 1) * 94)
		b.Size = UDim2.fromOffset(70, 70)
		b.BackgroundColor3 = Color3.fromRGB(10, 11, 8)
		b.BackgroundTransparency = 0.28
		b.BorderSizePixel = 0
		b.ScaleType = Enum.ScaleType.Fit
		b.Parent = S.root
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 12)
		bc.Parent = b
		local ring = Instance.new("UIStroke")
		ring.Color = Color3.new(1, 1, 1)
		ring.Thickness = 3.5
		ring.Parent = b
		local icon = TABS.icons[id]
		if icon ~= "" then
			b.Image = icon:match("^%d+$") and ("rbxassetid://" .. icon) or icon
		else
			local e = sticker(b, TABS.emoji[id], 30)
			e.Size = UDim2.fromScale(1, 1)
			e.ZIndex = 2
		end
		local dim = Instance.new("Frame") -- inactive shade
		dim.Size = UDim2.fromScale(1, 1)
		dim.BackgroundColor3 = Color3.new(0, 0, 0)
		dim.BackgroundTransparency = 0.5
		dim.BorderSizePixel = 0
		dim.ZIndex = 5
		dim.Visible = (id ~= "featured")
		dim.Parent = b
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(0, 12)
		dc.Parent = dim
		S.tabBtns[id] = { btn = b, ring = ring, dim = dim }
		b.Activated:Connect(function()
			lplay("Click")
			S.setTab(id)
		end)
	end
	do -- the red ! on DAILY while the free spin is unclaimed
		local badge = Instance.new("Frame")
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, 9, 0, -9)
		badge.Size = UDim2.fromOffset(22, 22)
		badge.BackgroundColor3 = Color3.fromRGB(224, 34, 34)
		badge.BorderSizePixel = 0
		badge.ZIndex = 6
		badge.Parent = S.tabBtns.daily.btn
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = badge
		ledge(badge, TBLACK, 2.5)
		local ex = sticker(badge, "!", 14)
		ex.Size = UDim2.fromScale(1, 1)
		ex.ZIndex = 7
		S.dailyBadge = badge
	end

	S.setTab = function(id)
		S.tab = id
		for k, pg in S.page do
			pg.Visible = (k == id)
		end
		S.title.Text = TABS.titles[id]
		for k, t in S.tabBtns do
			t.dim.Visible = (k ~= id)
			t.ring.Thickness = (k == id) and 4.5 or 3.5
		end
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
	S.ticker.Parent = S.page.featured
	corner(S.ticker, 4)
	ledge(S.ticker, TBLACK, 2.5)
	S.layoutFeatured = function() -- pack + pity ride up when there's no ticker row
		local y = S.ticker.Visible and 32 or 4
		S.pack.Position = UDim2.fromOffset(2, y)
		S.pityBar.Position = UDim2.fromOffset(2, y + 314)
	end

	S.pack = Instance.new("Frame")
	S.pack.Position = UDim2.fromOffset(2, 32)
	S.pack.Size = UDim2.fromOffset(628, 304)
	S.pack.BorderSizePixel = 0
	S.pack.ClipsDescendants = true
	S.pack.ZIndex = 2
	S.pack.Parent = S.page.featured
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
		S.packTitle.Size = UDim2.fromOffset(340, 32)
		S.packTitle.TextXAlignment = Enum.TextXAlignment.Left
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
		S.footCap.Position = UDim2.fromOffset(12, 0)
		S.footCap.Size = UDim2.fromOffset(120, 72)
		S.footCap.BackgroundTransparency = 1
		S.footCap.FontFace = BODYB_FACE
		S.footCap.TextSize = 11
		S.footCap.TextColor3 = Color3.fromRGB(255, 237, 189)
		S.footCap.TextWrapped = true
		S.footCap.TextXAlignment = Enum.TextXAlignment.Left
		S.footCap.ZIndex = 4
		S.footCap.Text = "GUN SKINS — THEY FIT EVERY GUN YOU OWN"
		S.footCap.Parent = S.foot
		local capS = Instance.new("UIStroke")
		capS.Color = TBLACK
		capS.Thickness = 1.5
		capS.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		capS.Parent = S.footCap
	end

	local function productFor(count)
		local d = S.data
		return d and d.pack and tonumber(d.pack["product" .. count]) or 0
	end

	-- One "Open xN" stack: label over [BIG green Robux pill][BIG pink gift square].
	local function mkOpen(count, x)
		local stack = Instance.new("Frame")
		stack.Position = UDim2.fromOffset(x, 0)
		stack.Size = UDim2.fromOffset(160, 72)
		stack.BackgroundTransparency = 1
		stack.ZIndex = 4
		stack.Parent = S.foot
		local lbl = sticker(stack, "Open x" .. count, 14)
		lbl.Position = UDim2.fromOffset(0, 3)
		lbl.Size = UDim2.fromOffset(112, 16)
		local pill = Instance.new("TextButton")
		pill.Position = UDim2.fromOffset(0, 22)
		pill.Size = UDim2.fromOffset(112, 44)
		pill.BorderSizePixel = 0
		pill.AutoButtonColor = true
		pill.Text = ""
		pill.ZIndex = 5
		pill.Parent = stack
		corner(pill, 6)
		absGrad(pill, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
		ledge(pill, TBLACK, 3)
		local wrap = Instance.new("Frame")
		wrap.Size = UDim2.fromScale(1, 1)
		wrap.BackgroundTransparency = 1
		wrap.ZIndex = 6
		wrap.Parent = pill
		local ll = Instance.new("UIListLayout")
		ll.FillDirection = Enum.FillDirection.Horizontal
		ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
		ll.VerticalAlignment = Enum.VerticalAlignment.Center
		ll.Padding = UDim.new(0, 6)
		ll.Parent = wrap
		local gem = robuxGem(wrap, 16)
		local price = sticker(wrap, "SOON", 21)
		price.AutomaticSize = Enum.AutomaticSize.X
		price.Size = UDim2.fromOffset(0, 30)
		price.ZIndex = 6
		local overlay = Instance.new("Frame") -- grey "not set up yet" cover (never show dead dashes)
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.BackgroundColor3 = Color3.fromRGB(44, 49, 36)
		overlay.BorderSizePixel = 0
		overlay.ZIndex = 5
		overlay.Parent = pill
		local oc = Instance.new("UICorner")
		oc.CornerRadius = UDim.new(0, math.floor(6 * 1.8 + 2))
		oc.Parent = overlay
		local gift = Instance.new("TextButton")
		gift.Position = UDim2.fromOffset(116, 22)
		gift.Size = UDim2.fromOffset(44, 44)
		gift.BorderSizePixel = 0
		gift.FontFace = TITLE_FACE
		gift.TextSize = 22
		gift.TextColor3 = Color3.new(1, 1, 1)
		gift.Text = "🎁"
		gift.ZIndex = 5
		gift.Parent = stack
		corner(gift, 6)
		absGrad(gift, Color3.fromRGB(212, 71, 158), Color3.fromRGB(110, 22, 84)) -- deeper magenta, less neon
		ledge(gift, TBLACK, 3)
		gift.Activated:Connect(function()
			if rolling then
				return
			end
			if productFor(count) < 1 then
				lplay("Error")
				S.say("ROBUX PRODUCT NOT SET UP YET — COMING SOON", DIMTEXT)
				return
			end
			S.openGiftPicker(count)
		end)
		pill.Activated:Connect(function()
			if rolling then
				return
			end
			local pid = productFor(count)
			if pid < 1 then
				lplay("Error")
				S.say("ROBUX PRODUCT NOT SET UP YET — COMING SOON", DIMTEXT)
				return
			end
			ShopGift:FireServer(nil) -- no stale gift: this buy is for ME
			lplay("Buy")
			MarketplaceService:PromptProductPurchase(localPlayer, pid)
		end)
		return { price = price, gem = gem, overlay = overlay }
	end
	S.p1 = mkOpen(1, 142)
	S.p3 = mkOpen(3, 304)
	S.p10 = mkOpen(10, 466)
	-- One pill's live state: a real Robux price, or the quiet grey SOON (no dead dashes, ever).
	S.setPill = function(e, robux)
		if robux then
			e.price.Text = fmt(robux)
			e.price.TextSize = 21
			e.gem.Visible = true
			e.overlay.Visible = false
		else
			e.price.Text = "SOON"
			e.price.TextSize = 15
			e.gem.Visible = false
			e.overlay.Visible = true
		end
	end

	-- PITY: ONE fat labeled meter under the pack — text inside the bar, star cap at the goal end.
	S.pityBar = Instance.new("Frame")
	S.pityBar.Position = UDim2.fromOffset(2, 346)
	S.pityBar.Size = UDim2.fromOffset(628, 26)
	S.pityBar.BackgroundColor3 = Color3.fromRGB(13, 15, 10)
	S.pityBar.BorderSizePixel = 0
	S.pityBar.ClipsDescendants = true
	S.pityBar.Parent = S.page.featured
	do
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(1, 0)
		tc.Parent = S.pityBar
		ledge(S.pityBar, TBLACK, 3)
		S.pityFill = Instance.new("Frame")
		S.pityFill.Size = UDim2.new(0, 0, 1, 0)
		S.pityFill.BorderSizePixel = 0
		S.pityFill.Parent = S.pityBar
		absGrad(S.pityFill, Color3.fromRGB(138, 92, 8), Color3.fromRGB(240, 165, 10))
		S.pityFill:FindFirstChildOfClass("UIGradient").Rotation = 0 -- fill shades left→right, not top→down
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(1, 0)
		fc.Parent = S.pityFill
		S.pityLbl = sticker(S.pityBar, "LEGENDARY+ GUARANTEED IN 10 OPENS", 12)
		S.pityLbl.Size = UDim2.fromScale(1, 1)
		S.pityLbl.ZIndex = 6
		local cap = Instance.new("Frame") -- the goal star at the end of the track
		cap.AnchorPoint = Vector2.new(1, 0.5)
		cap.Position = UDim2.new(1, -4, 0.5, 0)
		cap.Size = UDim2.fromOffset(20, 20)
		cap.BorderSizePixel = 0
		cap.ZIndex = 6
		cap.Parent = S.pityBar
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(1, 0)
		cc.Parent = cap
		absGrad(cap, Color3.fromRGB(255, 217, 122), Color3.fromRGB(224, 144, 0))
		ledge(cap, TBLACK, 2)
		local star = sticker(cap, "★", 11)
		star.Size = UDim2.fromScale(1, 1)
		star.ZIndex = 7
	end
	S.layoutFeatured() -- ticker starts hidden → pack + pity ride up

	-- =====================================================================================================
	-- ===== TAB 2: DAILY WHEEL ===== 8 reward chips in a ring + light-chaser spin.
	-- =====================================================================================================
	do
		local wheel = Instance.new("Frame")
		wheel.Position = UDim2.fromOffset(20, 14)
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
		S.wheelResult.Position = UDim2.fromOffset(0, 262)
		S.wheelResult.Size = UDim2.fromOffset(280, 40)
		S.wheelResult.TextWrapped = true

		-- Right column: the pitch + buttons.
		local t = sticker(S.page.daily, "ONE FREE SPIN EVERY DAY", 17)
		t.Position = UDim2.fromOffset(292, 20)
		t.Size = UDim2.fromOffset(338, 24)
		t.TextXAlignment = Enum.TextXAlignment.Left
		local d = Instance.new("TextLabel")
		d.Position = UDim2.fromOffset(292, 50)
		d.Size = UDim2.fromOffset(338, 52)
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
		S.spinBtn.Position = UDim2.fromOffset(292, 112)
		S.spinBtn.Size = UDim2.fromOffset(250, 54)
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

		local rb = Instance.new("TextButton")
		rb.Position = UDim2.fromOffset(292, 180)
		rb.Size = UDim2.fromOffset(200, 42)
		rb.BorderSizePixel = 0
		rb.AutoButtonColor = true
		rb.Text = ""
		rb.Parent = S.page.daily
		corner(rb, 6)
		absGrad(rb, Color3.fromRGB(198, 247, 122), Color3.fromRGB(47, 138, 16), Color3.fromRGB(89, 193, 34))
		ledge(rb, TBLACK, 3)
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
		S.respinNote.Position = UDim2.fromOffset(500, 180)
		S.respinNote.Size = UDim2.fromOffset(130, 42)
		S.respinNote.BackgroundTransparency = 1
		S.respinNote.FontFace = BODYB_FACE
		S.respinNote.TextSize = 10
		S.respinNote.TextColor3 = DIMTEXT
		S.respinNote.TextWrapped = true
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

		S.streakLbl = sticker(S.page.daily, "", 13, Color3.fromRGB(255, 210, 62))
		S.streakLbl.Position = UDim2.fromOffset(292, 240)
		S.streakLbl.Size = UDim2.fromOffset(338, 20)
		S.streakLbl.TextXAlignment = Enum.TextXAlignment.Left
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
			card.Size = UDim2.fromOffset(200, 118)
			card.BorderSizePixel = 0
			card.AutoButtonColor = true
			card.Text = ""
			card.Parent = S.page.passes
			corner(card, 6)
			absGrad(card, gp.color, gp.color2)
			ledge(card, TBLACK, 3)
			drawEmblem(card, gp.emblem)
			local nm = sticker(card, gp.name, 17)
			nm.Position = UDim2.fromOffset(0, 42)
			nm.Size = UDim2.new(1, 0, 0, 22)
			nm.ZIndex = 5
			local sub = Instance.new("TextLabel")
			sub.Position = UDim2.fromOffset(0, 64)
			sub.Size = UDim2.new(1, -8, 0, 13)
			sub.BackgroundTransparency = 1
			sub.FontFace = BODYB_FACE
			sub.TextSize = 9
			sub.TextColor3 = Color3.new(1, 1, 1)
			sub.TextTransparency = 0.25
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

		local bt = sticker(S.page.passes, "COIN BUNDLES", 16)
		bt.Position = UDim2.fromOffset(0, 132)
		bt.Size = UDim2.new(1, 0, 0, 20)

		S.bundleBtns = {}
		for i = 1, 4 do
			local card = Instance.new("TextButton")
			card.Position = UDim2.fromOffset((i - 1) * 161, 160)
			card.Size = UDim2.fromOffset(150, 92)
			card.BorderSizePixel = 0
			card.AutoButtonColor = true
			card.Text = ""
			card.Parent = S.page.passes
			corner(card, 6)
			absGrad(card, Color3.fromRGB(37, 74, 99), Color3.fromRGB(19, 42, 58))
			ledge(card, TBLACK, 3)
			local amt = sticker(card, "--", 16, Color3.fromRGB(255, 210, 62))
			amt.Position = UDim2.fromOffset(0, 12)
			amt.Size = UDim2.new(1, 0, 0, 22)
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
		S.starterBar.Position = UDim2.fromOffset(0, 266)
		S.starterBar.Size = UDim2.new(1, -2, 0, 48)
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
			nm.Size = UDim2.fromOffset(160, 48)
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.ZIndex = 5
			local ct = Instance.new("TextLabel")
			ct.Position = UDim2.fromOffset(184, 0)
			ct.Size = UDim2.fromOffset(260, 48)
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

	-- ===== GIFTING ===== pick a player → the server arms the gift → the SAME purchase delivers to them.
	S.picker = Instance.new("Frame")
	S.picker.AnchorPoint = Vector2.new(0.5, 0.5)
	S.picker.Position = UDim2.fromScale(0.5, 0.5)
	S.picker.Size = UDim2.fromOffset(300, 340)
	S.picker.BackgroundColor3 = Color3.fromRGB(19, 21, 15)
	S.picker.BorderSizePixel = 0
	S.picker.Visible = false
	S.picker.ZIndex = 30
	S.picker.Parent = S.gui
	corner(S.picker, 8)
	ledge(S.picker, TBLACK, 3.5)
	ledge(S.picker, Color3.fromRGB(255, 122, 226), 1.5, 0.3)
	do
		local t = sticker(S.picker, "GIFT TO...", 22)
		t.Position = UDim2.fromOffset(0, 10)
		t.Size = UDim2.new(1, 0, 0, 26)
		t.ZIndex = 31
		S.pickList = Instance.new("ScrollingFrame")
		S.pickList.Position = UDim2.fromOffset(14, 46)
		S.pickList.Size = UDim2.new(1, -28, 1, -108)
		S.pickList.BackgroundTransparency = 1
		S.pickList.BorderSizePixel = 0
		S.pickList.ScrollBarThickness = 5
		S.pickList.CanvasSize = UDim2.new()
		S.pickList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		S.pickList.ZIndex = 31
		S.pickList.Parent = S.picker
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 6)
		ll.Parent = S.pickList
		local cancel = Instance.new("TextButton")
		cancel.AnchorPoint = Vector2.new(0.5, 1)
		cancel.Position = UDim2.new(0.5, 0, 1, -12)
		cancel.Size = UDim2.fromOffset(150, 40)
		cancel.BackgroundColor3 = TRACK
		cancel.BorderSizePixel = 0
		cancel.FontFace = TITLE_FACE
		cancel.TextSize = 16
		cancel.TextColor3 = TEXTCOL
		cancel.Text = "CANCEL"
		cancel.ZIndex = 31
		cancel.Parent = S.picker
		corner(cancel, 6)
		ledge(cancel, TBLACK, 2.5)
		cancel.Activated:Connect(function()
			S.picker.Visible = false
		end)
	end
	S.openGiftPicker = function(count)
		clearChildren(S.pickList)
		local others = 0
		for _, plr in Players:GetPlayers() do
			if plr ~= localPlayer then
				others += 1
				local row = Instance.new("TextButton")
				row.Size = UDim2.new(1, -6, 0, 42)
				row.BackgroundColor3 = darker(PANEL2, 0.2)
				row.BorderSizePixel = 0
				row.FontFace = TITLE_FACE
				row.TextSize = 16
				row.TextColor3 = Color3.new(1, 1, 1)
				row.Text = plr.DisplayName or plr.Name
				row.ZIndex = 31
				row.Parent = S.pickList
				corner(row, 6)
				ledge(row, TBLACK, 2.5)
				row.Activated:Connect(function()
					S.picker.Visible = false
					local pid = productFor(count)
					if pid < 1 then
						return
					end
					ShopGift:FireServer(plr.UserId) -- arm the gift, THEN prompt the same product
					lplay("Buy")
					MarketplaceService:PromptProductPurchase(localPlayer, pid)
				end)
			end
		end
		if others == 0 then
			lplay("Error")
			S.say("NO ONE ELSE HERE TO GIFT — INVITE A FRIEND!", DIMTEXT)
			return
		end
		S.picker.Visible = true
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
		-- FEATURED: the four tier CARDS — your equipped gun rendered wearing each tier's skin.
		local pk = d.pack
		if pk then
			S.packTitle.Text = (pk.name or "PACK"):upper():gsub("%s*SKIN%s*CRATE", ""):gsub("%s*CASE", "") .. " SKIN PACK"
			S.setPill(S.p1, pk.robux1)
			S.setPill(S.p3, pk.robux3)
			S.setPill(S.p10, pk.robux10)
			clearChildren(S.items)
			local disp = invData and invData.catalog.cases[pk.caseId]
			if not disp or not disp.loot then
				local l = sticker(S.items, "LOADING THE POOL...", 18, DIMTEXT)
				l.AnchorPoint = Vector2.new(0.5, 0.5)
				l.Position = UDim2.fromScale(0.5, 0.5)
				l.Size = UDim2.fromOffset(300, 24)
			else
				local entries = {}
				for _, e in disp.loot do
					if e.kind == "skins" then
						table.insert(entries, e)
					end
				end
				table.sort(entries, function(a, b)
					return (a.pct or 100) < (b.pct or 100)
				end)
				local myGun = (invData.loadout and (invData.loadout[1] or invData.loadout[2])) or "pistol"
				local gunInfo = invData.catalog.weapons[myGun]
				S.footCap.Text = ("GUN SKINS — SHOWN ON YOUR %s"):format(((gunInfo and gunInfo.name) or myGun):upper())
				local PREF = { common = "worn", rare = "toxic", legendary = "gold", divine = "void" }
				for i = 1, math.min(4, #entries) do
					local e = entries[i]
					local tierCol = rarityColor(e.rarity)
					-- the tier's face skin for MY gun (canonical name first, else first of the rarity)
					local sk = PREF[e.rarity] and invData.catalog.skins[myGun .. "_" .. PREF[e.rarity]]
					if not sk or sk.rarity ~= e.rarity then
						local best
						for id, s2 in invData.catalog.skins do
							if s2.gun == myGun and s2.rarity == e.rarity and (not best or id < best) then
								best = id
							end
						end
						sk = best and invData.catalog.skins[best] or sk
					end
					local card = Instance.new("Frame")
					card.Position = UDim2.fromOffset(10 + (i - 1) * 154, 10)
					card.Size = UDim2.fromOffset(146, 178)
					card.BorderSizePixel = 0
					card.ClipsDescendants = true
					card.Parent = S.items
					corner(card, 5)
					-- a REAL tier-colored glow fading down the card (was so subtle it read as flat black)
					absGrad(card, tierCol:Lerp(Color3.fromRGB(20, 16, 10), 0.4), Color3.fromRGB(13, 11, 7), tierCol:Lerp(Color3.fromRGB(16, 13, 8), 0.72))
					ledge(card, tierCol, 3)
					if i == 1 then -- the rarest blazes: an extra soft halo ring
						ledge(card, tierCol, 7, 0.78)
					end
					local vp = sk and (makeGunViewport(sk.id, false) or makeGunViewport(myGun, false, nil, sk.tint))
						or makeGunViewport(myGun, false)
					if vp then
						vp.Position = UDim2.fromOffset(0, 8)
						vp.Size = UDim2.new(1, 0, 0, 100)
						vp.ZIndex = 3
						vp.Parent = card
					else
						local ph = sticker(card, ((sk and sk.name) or e.rarity):upper(), 13, tierCol)
						ph.Position = UDim2.fromOffset(6, 24)
						ph.Size = UDim2.new(1, -12, 0, 72)
						ph.TextWrapped = true
						ph.ZIndex = 3
					end
					local gl = Instance.new("Frame") -- tier-colored shelf line under the render
					gl.AnchorPoint = Vector2.new(0.5, 0)
					gl.Position = UDim2.new(0.5, 0, 0, 112)
					gl.Size = UDim2.fromOffset(110, 2)
					gl.BackgroundColor3 = tierCol
					gl.BackgroundTransparency = 0.45
					gl.BorderSizePixel = 0
					gl.ZIndex = 3
					gl.Parent = card
					do
						local c = Instance.new("UICorner")
						c.CornerRadius = UDim.new(1, 0)
						c.Parent = gl
					end
					local nm = sticker(card, (sk and sk.skin or e.rarity):upper() .. " SKIN", 15)
					nm.Position = UDim2.fromOffset(0, 118)
					nm.Size = UDim2.new(1, 0, 0, 18)
					nm.ZIndex = 4
					local tl = Instance.new("TextLabel")
					tl.Position = UDim2.fromOffset(0, 137)
					tl.Size = UDim2.new(1, 0, 0, 12)
					tl.BackgroundTransparency = 1
					tl.FontFace = BODYB_FACE
					tl.TextSize = 10
					tl.TextColor3 = tierCol
					tl.ZIndex = 4
					tl.Text = ((invData.catalog.rarities[e.rarity] or {}).name or e.rarity):upper()
					tl.Parent = card
					local chip = Instance.new("Frame") -- the odds, as a neat chip
					chip.AnchorPoint = Vector2.new(0.5, 1)
					chip.Position = UDim2.new(0.5, 0, 1, -6)
					chip.Size = UDim2.fromOffset(66, 20)
					chip.BackgroundColor3 = Color3.fromRGB(10, 11, 8)
					chip.BackgroundTransparency = 0.12
					chip.BorderSizePixel = 0
					chip.ZIndex = 4
					chip.Parent = card
					do
						local c = Instance.new("UICorner")
						c.CornerRadius = UDim.new(1, 0)
						c.Parent = chip
						ledge(chip, tierCol, 2)
					end
					local pc = Instance.new("TextLabel")
					pc.Size = UDim2.fromScale(1, 1)
					pc.BackgroundTransparency = 1
					pc.FontFace = TITLE_FACE
					pc.TextSize = 12
					pc.TextColor3 = tierCol
					pc.ZIndex = 5
					pc.Text = ("%.1f%%"):format(e.pct or 0)
					pc.Parent = chip
					if i == 1 then -- straight LIMITED badge on the rarest (rotated ribbons escape clipping)
						local rib = Instance.new("Frame")
						rib.Position = UDim2.fromOffset(6, 6)
						rib.Size = UDim2.fromOffset(66, 18)
						rib.BorderSizePixel = 0
						rib.ZIndex = 6
						rib.Parent = card
						local rc = Instance.new("UICorner")
						rc.CornerRadius = UDim.new(0, 6)
						rc.Parent = rib
						absGrad(rib, Color3.fromRGB(255, 90, 60), Color3.fromRGB(150, 18, 18))
						ledge(rib, TBLACK, 2)
						local rl = sticker(rib, "LIMITED", 10)
						rl.Size = UDim2.fromScale(1, 1)
						rl.ZIndex = 7
					end
				end
			end
		end
		local pityLeft = tonumber(d.pityLeft) or 10
		S.pityLbl.Text = ("LEGENDARY+ GUARANTEED IN %d OPEN%s"):format(pityLeft, pityLeft == 1 and "" or "S")
		S.pityFill.Size = UDim2.new(math.clamp((10 - pityLeft) / 10, 0.04, 1), 0, 1, 0) -- never dead-empty

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
			S.dailyBadge.Visible = not w.freeUsed
			dockBtns.dailyBadge.Visible = not w.freeUsed -- the dock button calls it out too
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
			-- keep the DAILY badges honest even while closed (the dock button pulses interest)
			if p.wheel then
				S.dailyBadge.Visible = not p.wheel.freeUsed
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
	dockBtns.pass.Activated:Connect(function()
		openShopTab("passes")
	end)
	dockBtns.codes.Activated:Connect(function()
		openShopTab("codes")
	end)
	-- Opening WEAPONS/INVENTORY (buttons or the B key) puts the shop away — one panel at a time.
	gunsBtn.Activated:Connect(closeShop)
	casesBtn.Activated:Connect(closeShop)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.B then
			closeShop()
		end
	end)
end

-- =====================================================================================================
-- ===== RUN SUMMARY CARD ("Run over — Wave 14 · 87 kills · +215 Coins") ===============================
-- =====================================================================================================
-- The game place sends { summary = { wave, kills, money, win? } } in TeleportData when it returns you
-- to the lobby (death or victory). Show it once as a small card at the top of the screen.
do
	local TeleportService = game:GetService("TeleportService")
	local ok, td = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	local summary = ok and typeof(td) == "table" and typeof(td.summary) == "table" and td.summary or nil
	if summary then
		local SHOW_SECONDS = 8
		local isWin = summary.win == true

		local card = Instance.new("Frame")
		card.Name = "RunSummary"
		card.AnchorPoint = Vector2.new(0.5, 0)
		card.Position = UDim2.new(0.5, 0, 0, -110) -- starts off-screen, slides down
		card.Size = UDim2.fromOffset(360, 92)
		card.BackgroundColor3 = PANEL
		card.BackgroundTransparency = 0
		card.BorderSizePixel = 0
		card.Parent = gui
		corner(card, 6)
		lstuds(card); ldepth(card); ledge(card)
		local cStroke = Instance.new("UIStroke")
		cStroke.Color = isWin and ACCENT or ORANGE
		cStroke.Transparency = 0.35
		cStroke.Thickness = 1.5
		cStroke.Parent = card

		local cTitle = Instance.new("TextLabel")
		cTitle.Position = UDim2.fromOffset(0, 14)
		cTitle.Size = UDim2.new(1, 0, 0, 24)
		cTitle.BackgroundTransparency = 1
		cTitle.FontFace = TITLE_FACE
		cTitle.TextSize = 20
		cTitle.TextColor3 = isWin and ACCENT or ORANGE
		cTitle.Text = isWin and "VICTORY!" or "RUN OVER"
		cTitle.Parent = card

		local cLine = Instance.new("TextLabel")
		cLine.Position = UDim2.fromOffset(0, 44)
		cLine.Size = UDim2.new(1, 0, 0, 20)
		cLine.BackgroundTransparency = 1
		cLine.FontFace = BODYB_FACE
		cLine.TextSize = 15
		cLine.TextColor3 = TEXTCOL
		cLine.Text = ("Wave %d   ·   %d kills   ·   +%s Coins"):format(
			tonumber(summary.wave) or 0,
			tonumber(summary.kills) or 0,
			fmt(tonumber(summary.money) or 0)
		)
		cLine.Parent = card

		local cHint = Instance.new("TextLabel")
		cHint.Position = UDim2.fromOffset(0, 66)
		cHint.Size = UDim2.new(1, 0, 0, 14)
		cHint.BackgroundTransparency = 1
		cHint.FontFace = BODY_FACE
		cHint.TextSize = 11
		cHint.TextColor3 = DIMTEXT
		cHint.Text = "Coins banked to your account"
		cHint.Parent = card

		local cClose = Instance.new("TextButton")
		cClose.AnchorPoint = Vector2.new(1, 0)
		cClose.Position = UDim2.new(1, -6, 0, 6)
		cClose.Size = UDim2.fromOffset(44, 44)
		cClose.BackgroundTransparency = 1
		cClose.FontFace = BODYB_FACE
		cClose.TextSize = 14
		cClose.TextColor3 = DIMTEXT
		cClose.Text = "✕"
		cClose.Parent = card

		local dismissed = false
		local function dismiss()
			if dismissed then return end
			dismissed = true
			local out = TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.new(0.5, 0, 0, -110),
			})
			out.Completed:Once(function()
				card:Destroy()
			end)
			out:Play()
		end
		cClose.Activated:Connect(dismiss)

		TweenService:Create(card, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0, 18),
		}):Play()
		task.delay(SHOW_SECONDS, dismiss)
	end
end

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
	local sRoot, sPanel, _, sClose = chromePanel(setGui, 460, 316, HEADER_COLORS.settings, "SETTINGS")
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
			volTouched = true
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
	lattach(xpGui)

	-- CHANGED: mid-LEFT now (V2-A), tucked right under the coins pill.
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0, 0.5); bar.Position = UDim2.new(0, 16, 0.5, 30); bar.Size = UDim2.fromOffset(400, 72)
	bar.BackgroundColor3 = PANEL; bar.BackgroundTransparency = 0.15; bar.BorderSizePixel = 0; bar.Parent = xpGui
	corner(bar, 8); lstuds(bar); ldepth(bar); ledge(bar, TBLACK, 3); ledge(bar, ACCENT, 2, 0.35)

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

	local function refresh()
		local level, into, need = levelInfo(localPlayer:GetAttribute("AccountXP") or 0)
		localPlayer:SetAttribute("AccountLevel", level) -- the shop pane reads this to gate level-locked guns
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

-- EVERYTHING is wired — now PULL a fresh snapshot. The server's join-time pushes often fire while
-- this (big) script is still loading, so the hotbar/coins/XP missed them and sat empty until some
-- other action triggered a resend. This request closes that race for good.
InvRequest:FireServer()

print("[LobbyClient] started")
