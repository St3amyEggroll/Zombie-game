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
		o.MouseButton1Down:Connect(function()
			face.Position = UDim2.fromOffset(0, 4) -- press = face slides down onto the slab
		end)
		local function up()
			face.Position = UDim2.new()
		end
		o.MouseButton1Up:Connect(up)
		o.MouseLeave:Connect(up)
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
	for _, rot in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5); bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.new(0.5, 0, 0, 3); bar.Rotation = rot
		bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255); bar.BorderSizePixel = 0; bar.ZIndex = 3; bar.Parent = x
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = bar
	end
	return x
end

-- Per-screen header COLORS (mirror the game's UITheme.HeaderColors).
local HEADER_COLORS = {
	guns     = Color3.fromRGB(64, 28, 102),   -- dark purple
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
local function makeGunViewport(weaponId, spin, folderName)
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
	model.Parent = vp
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vp
	vp.CurrentCamera = cam
	local cf, size = model:GetBoundingBox()
	model.WorldPivot = cf
	local dist = (size.Magnitude / 2) / math.tan(math.rad(15)) * 1.12 + 0.1
	cam.CFrame = CFrame.new(cf.Position + Vector3.new(0, dist * 0.22, dist), cf.Position)
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

-- Coins: a bare gold number pinned middle-right of the screen (no panel behind it).
-- COIN_ICON_ID: paste the currency image asset id here later (e.g. "rbxassetid://123456") — the icon
-- shows up automatically to the left of the number once set.
local COIN_ICON_ID = ""
local coinsRow = Instance.new("Frame")
coinsRow.AnchorPoint = Vector2.new(0, 1); coinsRow.Position = UDim2.new(0, 16, 1, -(12 + 56 + 6)) -- above the LEVEL bar
coinsRow.Size = UDim2.fromOffset(320, 44); coinsRow.BackgroundTransparency = 1; coinsRow.Parent = gui
local moneyLabel = Instance.new("TextLabel")
moneyLabel.Size = UDim2.new(1, 0, 1, 0); moneyLabel.BackgroundTransparency = 1
moneyLabel.FontFace = TITLE_FACE; moneyLabel.TextSize = 40; moneyLabel.TextXAlignment = Enum.TextXAlignment.Left
moneyLabel.TextColor3 = GOLD; moneyLabel.Text = ""; moneyLabel.Parent = coinsRow
local moneyStroke = Instance.new("UIStroke")
moneyStroke.Color = TBLACK; moneyStroke.Thickness = 3.5; moneyStroke.Parent = moneyLabel
local coinIcon = Instance.new("ImageLabel")
coinIcon.AnchorPoint = Vector2.new(1, 0.5); coinIcon.Position = UDim2.new(1, -8, 0.5, 0)
coinIcon.Size = UDim2.fromOffset(36, 36); coinIcon.BackgroundTransparency = 1
coinIcon.ScaleType = Enum.ScaleType.Fit; coinIcon.Visible = false; coinIcon.Parent = coinsRow
if COIN_ICON_ID ~= "" then
	coinIcon.Image = COIN_ICON_ID
	coinIcon.Visible = true
end
local bestLabel = Instance.new("TextLabel")
bestLabel.AnchorPoint = Vector2.new(0, 0); bestLabel.Position = UDim2.new(0, 0, 1, 2)
bestLabel.Size = UDim2.fromOffset(320, 20); bestLabel.BackgroundTransparency = 1
bestLabel.FontFace = BODYB_FACE; bestLabel.TextSize = 14; bestLabel.TextXAlignment = Enum.TextXAlignment.Left
bestLabel.TextColor3 = DIMTEXT; bestLabel.Text = ""; bestLabel.Visible = false; bestLabel.Parent = coinsRow -- best-wave text removed
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
	l.FontFace = BODYB_FACE; l.TextSize = 18; l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = DIMTEXT; l.Text = text; l.Parent = panel
	return l
end
local function row(y, h)
	local f = Instance.new("Frame")
	f.Position = UDim2.new(0, 24, 0, y); f.Size = UDim2.new(1, -48, 0, h); f.BackgroundTransparency = 1; f.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal; list.Padding = UDim.new(0, 10); list.Parent = f
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
leaveBtn.AnchorPoint = Vector2.new(0.5, 1); leaveBtn.Position = UDim2.new(0.5, 0, 1, -28)
leaveBtn.Size = UDim2.fromOffset(240, 44); leaveBtn.BackgroundColor3 = ORANGE; leaveBtn.BorderSizePixel = 0
leaveBtn.FontFace = TITLE_FACE; leaveBtn.TextSize = 16; leaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
leaveBtn.Text = "LEAVE PARTY"; leaveBtn.Visible = false; leaveBtn.Parent = gui
corner(leaveBtn, 8); ldepth(leaveBtn); ledge(leaveBtn, TBLACK, 3); lbevel(leaveBtn)

local leaveStatus = Instance.new("TextLabel")
leaveStatus.AnchorPoint = Vector2.new(0.5, 1); leaveStatus.Position = UDim2.new(0.5, 0, 1, -104)
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
status.AnchorPoint = Vector2.new(0.5, 1); status.Position = UDim2.new(0.5, 0, 1, -12); status.Size = UDim2.new(1, -40, 0, 24)
status.BackgroundTransparency = 1; status.FontFace = BODYB_FACE; status.TextSize = 15
status.TextColor3 = DIMTEXT; status.Text = ""; status.Parent = panel

-- ===== RENDER =====
local function refresh()
	if not unlocks then return end
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
	-- keep the (future) coin icon hugging the number's left edge
	coinIcon.Position = UDim2.new(1, -moneyLabel.TextBounds.X - 10, 0.5, 0)
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

-- LEFT-CENTER buttons: GUNS [B] over CASES — square icon buttons, these ARE the inventory now.
-- Owner-supplied images; the caption underneath doubles as the fallback if an image id fails to load.
local GUN_ICON = "rbxassetid://107465960874017"
local CASES_ICON = "rbxassetid://83465359983310"
local function cornerButton(imageId, caption, xOff, accent, badge)
	-- TOP-CENTER NAV (sticker style): fat colored text buttons in a row, like the reference's
	-- Weapons | Play | Classes. xOff = horizontal offset from screen center.
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(0.5, 0)
	b.Position = UDim2.new(0.5, xOff, 0, 10); b.Size = UDim2.fromOffset(180, 56)
	b.BackgroundColor3 = accent; b.BorderSizePixel = 0
	b.Text = ""; b.Parent = invGui
	local navCorner = Instance.new("UICorner") -- RAW 10px radius (the shared curve made these bulbous)
	navCorner.CornerRadius = UDim.new(0, 10); navCorner.Parent = b
	ledge(b, TBLACK, 3); lbevel(b) -- full black ring like the mockup

	-- TEXT-ONLY pill (the reference buttons carry no icon art — the raw images read as stickers)
	local cap = Instance.new("TextLabel")
	cap.AnchorPoint = Vector2.new(0.5, 0.5); cap.Position = UDim2.new(0.5, 0, 0.5, -2)
	cap.Size = UDim2.new(1, -20, 0, 36); cap.BackgroundTransparency = 1
	cap.FontFace = TITLE_FACE; cap.TextSize = 26; cap.TextColor3 = Color3.new(1, 1, 1)
	cap.TextScaled = true; cap.Parent = b
	local capC = Instance.new("UITextSizeConstraint"); capC.MaxTextSize = 26; capC.Parent = cap
	local capS = Instance.new("UIStroke")
	capS.Color = TBLACK; capS.Thickness = 2.5; capS.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; capS.Parent = cap
	cap.TextXAlignment = Enum.TextXAlignment.Center; cap.Text = caption
	local capS2 = cap:FindFirstChildOfClass("UIStroke")
	if capS2 then capS2.Thickness = 3 end

	if badge then
		local bd = Instance.new("TextLabel")
		bd.Position = UDim2.fromOffset(6, 4); bd.Size = UDim2.fromOffset(16, 14)
		bd.BackgroundTransparency = 1; bd.FontFace = TITLE_FACE; bd.TextSize = 12
		bd.TextColor3 = GOLD; bd.TextXAlignment = Enum.TextXAlignment.Left
		bd.Text = "B"; bd.Parent = b
	end
	return b
end
local gunsBtn = cornerButton(GUN_ICON, "WEAPONS", -240, Color3.fromRGB(214, 48, 48), true) -- red, left of center
local casesBtn = cornerButton(CASES_ICON, "CRATES", 240, Color3.fromRGB(230, 140, 30), false) -- orange, right
-- PLAY button — the BIG center pill (replaces SHOP; the shop is still the stall you walk up to).
-- Pressing it steps you onto the nearest free party pad, so the normal set-up-your-run flow takes over.
local playBtn = cornerButton("", "PLAY", 0, Color3.fromRGB(52, 168, 52), false) -- green, center, bigger
playBtn.Size = UDim2.fromOffset(260, 74)
do -- scale the caption up to match the bigger pill
	local capL = playBtn:FindFirstChildOfClass("TextLabel")
	if capL then
		capL.Size = UDim2.new(1, -24, 0, 48)
		capL.TextSize = 38
		local con = capL:FindFirstChildOfClass("UITextSizeConstraint")
		if con then
			con.MaxTextSize = 38
		end
	end
end
playBtn.Activated:Connect(function()
	lplay("Open")
	remotes:WaitForChild("GoPlay"):FireServer()
end)

local PANEL_W, PANEL_H = 940, 560
local DETAIL_W = 280

local invPanel = Instance.new("Frame")
invPanel.AnchorPoint = Vector2.new(0.5, 0.5); invPanel.Position = UDim2.fromScale(0.5, 0.5)
invPanel.Size = UDim2.fromOffset(PANEL_W, PANEL_H); invPanel.BackgroundColor3 = PANEL
invPanel.BackgroundTransparency = 0.12; invPanel.BorderSizePixel = 0; invPanel.Visible = false; invPanel.Parent = invGui
corner(invPanel, 8)
lstuds(invPanel); ldepth(invPanel); ledge(invPanel, TBLACK, 3)
local invEdge = ledge(invPanel, HEADER_COLORS.guns, 2.5, 0.05)

local invHeaderBar, invHeaderSq = headerBar(invPanel, 48, HEADER_COLORS.guns)
local invTitle = Instance.new("TextLabel")
invTitle.Position = UDim2.fromOffset(18, 0); invTitle.Size = UDim2.fromOffset(340, 52); invTitle.BackgroundTransparency = 1
invTitle.FontFace = TITLE_FACE; invTitle.TextSize = 28; invTitle.TextXAlignment = Enum.TextXAlignment.Left
invTitle.TextColor3 = TEXTCOL; invTitle.Text = "INVENTORY"; invTitle.Parent = invPanel

local invCoins = Instance.new("TextLabel")
invCoins.AnchorPoint = Vector2.new(1, 0); invCoins.Position = UDim2.new(1, -64, 0, 14); invCoins.Size = UDim2.fromOffset(200, 28)
invCoins.BackgroundTransparency = 1; invCoins.FontFace = BODYB_FACE; invCoins.TextSize = 18
invCoins.TextXAlignment = Enum.TextXAlignment.Right; invCoins.TextColor3 = GOLD; invCoins.Text = "0"; invCoins.Parent = invPanel

local invClose = redX(invPanel, 44, 26)
invClose.Position = UDim2.new(1, -10, 0, 8)

-- (No tab strip: GUNS and CASES are separate screens sharing this panel; the header shows which.)

-- Same 3-region skeleton as the SHOP: card grid (left) | featured pane, always visible (middle) |
-- action-button stack (right).
local CONTENT_Y = 64 -- 48 header + 16 gap
local invGrid = Instance.new("ScrollingFrame")
invGrid.Position = UDim2.fromOffset(16, CONTENT_Y); invGrid.Size = UDim2.fromOffset(346, PANEL_H - CONTENT_Y - 16)
invGrid.BackgroundTransparency = 1; invGrid.BorderSizePixel = 0; invGrid.ScrollBarThickness = 6
invGrid.CanvasSize = UDim2.new(); invGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y; invGrid.Parent = invPanel
local invGridLayout = Instance.new("UIGridLayout")
invGridLayout.CellSize = UDim2.fromOffset(160, 148); invGridLayout.CellPadding = UDim2.fromOffset(12, 12); invGridLayout.Parent = invGrid

local invDetail = Instance.new("Frame")
invDetail.Position = UDim2.fromOffset(378, CONTENT_Y)
invDetail.Size = UDim2.fromOffset(DETAIL_W, PANEL_H - CONTENT_Y - 16)
invDetail.BackgroundColor3 = PANEL2; invDetail.BorderSizePixel = 0; invDetail.Parent = invPanel
corner(invDetail, 6); lstuds(invDetail, 42, 0.75); ledge(invDetail, TBLACK, 2); ledge(invDetail, LINE, 1, 0.5)

local invActs = Instance.new("Frame")
invActs.AnchorPoint = Vector2.new(1, 0); invActs.Position = UDim2.new(1, -16, 0, CONTENT_Y)
invActs.Size = UDim2.fromOffset(250, PANEL_H - CONTENT_Y - 16); invActs.BackgroundTransparency = 1; invActs.Parent = invPanel

local selectedInv = nil -- { kind = "weapon"|"case"|"potion", id } — drives the featured pane

local renderActive -- forward decl (grid + detail render)
local playReel -- forward decl (the reel section below assigns it)

local function invSelect(kind, id)
	selectedInv = { kind = kind, id = id } -- pane is permanent; clicking just features the item
	renderActive()
end

local function clearChildren(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

-- Compact square card in the grid.
local function invCard(opts)
	local col = opts.color
	local isSel = selectedInv and selectedInv.kind == opts.kind and selectedInv.id == opts.id
	local f = Instance.new("TextButton")
	f.BackgroundColor3 = col:Lerp(BLACK, opts.locked and 0.82 or 0.62); f.AutoButtonColor = true; f.Text = ""
	cardShade(f)
	f.BorderSizePixel = 0; f.LayoutOrder = opts.order or 0; f.Parent = invGrid
	corner(f, 6); ledge(f, isSel and ACCENT or (opts.nextUp and GOLD) or TBLACK, (isSel or opts.nextUp) and 3 or 2)
	-- STATIC art fills the card (only the featured pane spins); name sits on a strip at the bottom.
	local showedModel = false
	if opts.kind == "weapon" or opts.kind == "case" or opts.kind == "skin" then
		local vp
		if opts.kind == "skin" then
			local s = skinInfo(opts.id)
			vp = makeGunViewport(opts.id, false) or (s and makeGunViewport(s.gun, false)) -- skin model, else base gun
		else
			vp = makeGunViewport(opts.id, false, opts.kind == "case" and "CrateDisplay" or nil)
		end
		if vp then
			vp.Size = UDim2.new(1, 0, 1, -26)
			if opts.locked then
				vp.ImageColor3 = Color3.new(0, 0, 0) -- locked = black SILHOUETTE (the darkness IS the ladder)
				vp.ImageTransparency = 0.15
			end
			vp.Parent = f
			showedModel = true
		end
	end
	if not showedModel and typeof(opts.image) == "string" and opts.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.new(1, 0, 1, -26); img.BackgroundTransparency = 1
		img.Image = opts.image; img.ScaleType = Enum.ScaleType.Fit; img.Parent = f
	end
	local nmPlate = Instance.new("Frame") -- dark strip: the name reads on ANY rarity color
	nmPlate.AnchorPoint = Vector2.new(0, 1); nmPlate.Position = UDim2.new(0, 0, 1, 0)
	nmPlate.Size = UDim2.new(1, 0, 0, 26); nmPlate.BackgroundColor3 = TBLACK
	nmPlate.BackgroundTransparency = 0.35; nmPlate.BorderSizePixel = 0; nmPlate.ZIndex = 2; nmPlate.Parent = f
	local nm = Instance.new("TextLabel")
	nm.AnchorPoint = Vector2.new(0, 1); nm.Position = UDim2.new(0, 0, 1, -4); nm.Size = UDim2.new(1, 0, 0, 22)
	nm.BackgroundTransparency = 1; nm.FontFace = BODYB_FACE; nm.TextSize = 14; nm.ZIndex = 3
	nm.TextTruncate = Enum.TextTruncate.AtEnd
	nm.TextColor3 = TEXTCOL; nm.Text = opts.name; nm.Parent = f
	local nmStroke = Instance.new("UIStroke") -- keeps the name readable over the art
	nmStroke.Color = TBLACK; nmStroke.Thickness = 1.4
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; nmStroke.Parent = nm
	if opts.chip then
		local chip = Instance.new("TextLabel")
		chip.Position = UDim2.fromOffset(6, 6); chip.Size = UDim2.fromOffset(48, 18)
		chip.BackgroundColor3 = darker(col, 0.7); chip.BorderSizePixel = 0; chip.ZIndex = 3
		chip.FontFace = BODYB_FACE; chip.TextSize = 12; chip.TextColor3 = col; chip.Text = opts.chip; chip.Parent = f
		corner(chip, 4)
	end
	if opts.tag then -- short badge (e.g. "S1"), top-right like the shop's deal badge
		local tag = Instance.new("TextLabel")
		tag.AnchorPoint = Vector2.new(1, 0); tag.Position = UDim2.new(1, -6, 0, 6); tag.Size = UDim2.fromOffset(36, 18)
		tag.BackgroundColor3 = ACCENT; tag.BorderSizePixel = 0; tag.ZIndex = 3
		tag.FontFace = TITLE_FACE; tag.TextSize = 12; tag.TextColor3 = Color3.fromRGB(14, 22, 6)
		tag.Text = opts.tag; tag.Parent = f
		corner(tag, 4)
	end
	if opts.lockLevel then -- big centered LV plate on locked ladder cards
		local plate = Instance.new("TextLabel")
		plate.AnchorPoint = Vector2.new(0.5, 0.5); plate.Position = UDim2.new(0.5, 0, 0.5, -12)
		plate.Size = UDim2.fromOffset(110, 24); plate.BackgroundTransparency = 1; plate.ZIndex = 4
		plate.FontFace = TITLE_FACE; plate.TextSize = 18
		plate.TextColor3 = opts.nextUp and GOLD or TEXTCOL
		plate.Text = "LV " .. tostring(opts.lockLevel); plate.Parent = f
		local pStroke = Instance.new("UIStroke")
		pStroke.Color = TBLACK; pStroke.Thickness = 2
		pStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; pStroke.Parent = plate
	end
	f.Activated:Connect(function()
		invSelect(opts.kind, opts.id)
	end)
	return f
end

local function invEmptyNote(textStr)
	-- Lives inside the grid layout, so it gets a cell-sized box: wrap the text to fit.
	local msg = Instance.new("TextLabel")
	msg.Size = UDim2.fromOffset(320, 60); msg.BackgroundTransparency = 1; msg.FontFace = BODYB_FACE
	msg.TextSize = 14; msg.TextWrapped = true; msg.TextColor3 = DIMTEXT; msg.Text = textStr; msg.Parent = invGrid
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
	return bigButton(invActs, textStr, fillA, fillB, textCol)
end

-- ===== FEATURED PANE (middle) + ACTION STACK (right) =====
local function renderInvDetail()
	clearChildren(invDetail)
	clearChildren(invActs)
	if not invData then
		return
	end
	if not selectedInv then
		local hint = Instance.new("TextLabel")
		hint.Size = UDim2.fromScale(1, 1); hint.BackgroundTransparency = 1
		hint.FontFace = TITLE_FACE; hint.TextSize = 18; hint.TextColor3 = DIMTEXT
		hint.Text = "NOTHING HERE YET"; hint.Parent = invDetail
		return
	end
	local kind, id = selectedInv.kind, selectedInv.id

	-- Big render well (spins here — the grid cards stay static).
	local well = Instance.new("Frame")
	well.Position = UDim2.fromOffset(14, 14); well.Size = UDim2.new(1, -28, 0, 190)
	well.BackgroundColor3 = darker(PANEL2, 0.25); well.BorderSizePixel = 0; well.Parent = invDetail
	corner(well, 6); ledge(well, TBLACK, 2)

	local entry, wellCol
	if kind == "weapon" then entry = weaponInfo(id); wellCol = entry and rarityColor(entry.rarity)
	elseif kind == "case" then entry = invData.catalog.cases[id]; wellCol = rarityColor(id)
	elseif kind == "skin" then entry = skinInfo(id); wellCol = entry and rarityColor(entry.rarity) end
	if not entry then
		return
	end
	well.BackgroundColor3 = wellCol:Lerp(BLACK, 0.7)

	local wellVp
	if kind == "skin" then
		wellVp = makeGunViewport(id, true) or makeGunViewport(entry.gun, true) -- skin model, else base gun
	elseif kind ~= "potion" then
		wellVp = makeGunViewport(id, true, kind == "case" and "CrateDisplay" or nil)
	end
	if wellVp then
		wellVp.Size = UDim2.fromScale(1, 1); wellVp.Parent = well
	elseif typeof(entry.image) == "string" and entry.image ~= "" then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1; img.Size = UDim2.fromScale(1, 1)
		img.Image = entry.image; img.ScaleType = Enum.ScaleType.Fit; img.Parent = well
	else
		local plate = Instance.new("TextLabel")
		plate.Size = UDim2.fromScale(1, 1); plate.BackgroundTransparency = 1
		plate.FontFace = TITLE_FACE; plate.TextSize = 24; plate.TextColor3 = wellCol
		plate.Text = (kind == "potion") and "POTION" or "?"; plate.Parent = well
	end

	-- Centered info column under the well (same rhythm as the shop's featured pane).
	local function centered(y, h, face, size, colr)
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromOffset(14, y); l.Size = UDim2.new(1, -28, 0, h); l.BackgroundTransparency = 1
		l.FontFace = face; l.TextSize = size; l.TextWrapped = true; l.TextColor3 = colr; l.Parent = invDetail
		return l
	end

	local nm = centered(214, 30, TITLE_FACE, 21, wellCol)
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = TBLACK; nmStroke.Thickness = 1.5; nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; nmStroke.Parent = nm

	if kind == "weapon" then
		local w = entry
		nm.Text = w.name
		local rar = centered(246, 20, BODYB_FACE, 15, wellCol)
		rar.Text = (invData.catalog.rarities[w.rarity] or {}).name or ""
		-- STAT BARS (normalized against the best gun) — compare at a glance instead of reading.
		do
			local maxD, maxR, maxRng, maxDps = 1, 1, 1, 1
			for _, ww in invData.catalog.weapons do
				local d = (ww.damage or 0) * (ww.pellets or 1)
				maxD = math.max(maxD, d)
				maxR = math.max(maxR, ww.fireRate or 0)
				maxRng = math.max(maxRng, ww.range or 0)
				maxDps = math.max(maxDps, d * (ww.fireRate or 0))
			end
			local dmgV = (w.damage or 0) * (w.pellets or 1)
			local rows = {
				{ "DMG", dmgV, maxD }, { "RATE", w.fireRate or 0, maxR },
				{ "RNG", w.range or 0, maxRng }, { "DPS", dmgV * (w.fireRate or 0), maxDps },
			}
			for ri, r in rows do
				local y = 272 + (ri - 1) * 14
				local lab = Instance.new("TextLabel")
				lab.Position = UDim2.fromOffset(14, y); lab.Size = UDim2.fromOffset(42, 12)
				lab.BackgroundTransparency = 1; lab.FontFace = BODYB_FACE; lab.TextSize = 12
				lab.TextXAlignment = Enum.TextXAlignment.Left; lab.TextColor3 = DIMTEXT
				lab.Text = r[1]; lab.Parent = invDetail
				local trk = Instance.new("Frame")
				trk.Position = UDim2.fromOffset(60, y + 2); trk.Size = UDim2.new(1, -134, 0, 8)
				trk.BackgroundColor3 = darker(TRACK, 0.25); trk.BorderSizePixel = 0; trk.Parent = invDetail
				corner(trk, 2)
				local fil = Instance.new("Frame")
				fil.Size = UDim2.fromScale(math.clamp(r[2] / r[3], 0.02, 1), 1)
				fil.BackgroundColor3 = wellCol; fil.BorderSizePixel = 0; fil.Parent = trk
				corner(fil, 2)
				local num = Instance.new("TextLabel")
				num.AnchorPoint = Vector2.new(1, 0); num.Position = UDim2.new(1, -14, 0, y)
				num.Size = UDim2.fromOffset(56, 12); num.BackgroundTransparency = 1
				num.FontFace = BODYB_FACE; num.TextSize = 12; num.TextXAlignment = Enum.TextXAlignment.Right
				num.TextColor3 = TEXTCOL; num.Text = tostring(math.floor(r[2] + 0.5)); num.Parent = invDetail
			end
		end
		local dps = (w.damage or 0) * (w.fireRate or 0) * (w.pellets or 1)
		local stats = centered(274, 66, BODY_FACE, 14, TEXTCOL)
		stats.Visible = false -- replaced by the stat bars above (kept so nothing downstream breaks)
		stats.Text = ("DMG %.0f%s\n%s shots/s   ·   RNG %s\nDPS ~%d"):format(
			w.damage or 0, w.pellets and (" ×" .. w.pellets) or "", tostring(w.fireRate or "?"),
			tostring(w.range or "?"), math.floor(dps + 0.5))
		-- EQUIP / UNEQUIP — big button right under the damage info. Each gun has a fixed slot (primary/secondary).
		if ownsGun(id) then
			local sl = (w.slot == "secondary") and 2 or 1
			local equipped = (invData.loadout[sl] == id)
			local eqBtn = bigButton(invDetail,
				equipped and "UNEQUIP" or "EQUIP",
				equipped and ORANGE or ACCENT,
				equipped and darker(ORANGE, 0.4) or darker(ACCENT, 0.5),
				Color3.new(1, 1, 1)) -- white + black outline on every colored CTA, like the game
			eqBtn.Position = UDim2.fromOffset(14, 330); eqBtn.Size = UDim2.new(1, -28, 0, 56)
			eqBtn.Activated:Connect(function()
				lplay("Equip")
				EquipSlot:FireServer({ slot = sl, weaponId = equipped and false or id })
			end)
		end

		if w.ability then
			local ab = centered(388, 40, BODYB_FACE, 13, ACCENT)
			ab.Text = w.ability
			ab.TextYAlignment = Enum.TextYAlignment.Top
		end

		-- SKIN STRIP: this gun's skins as four swatches — click an OWNED one to equip (again to remove).
		if ownsGun(id) and invData.catalog.skins then
			local strip = Instance.new("Frame")
			strip.Position = UDim2.fromOffset(14, 430); strip.Size = UDim2.new(1, -28, 0, 54)
			strip.BackgroundTransparency = 1; strip.Parent = invDetail
			local sl = Instance.new("UIListLayout")
			sl.FillDirection = Enum.FillDirection.Horizontal; sl.Padding = UDim.new(0, 8); sl.Parent = strip
			local skinIds = {}
			for sid, s in invData.catalog.skins do
				if s.gun == id then
					table.insert(skinIds, sid)
				end
			end
			table.sort(skinIds)
			for _, sid in skinIds do
				local s = invData.catalog.skins[sid]
				local sOwned = ownsSkin(sid)
				local isOn = sOwned and invData.skins.equipped and invData.skins.equipped[id] == s.skin
				local sw = Instance.new("TextButton")
				sw.Size = UDim2.fromOffset(56, 54)
				sw.BackgroundColor3 = rarityColor(s.rarity):Lerp(BLACK, sOwned and 0.35 or 0.78)
				sw.BorderSizePixel = 0; sw.AutoButtonColor = sOwned
				sw.FontFace = BODYB_FACE; sw.TextSize = 11; sw.TextWrapped = true
				sw.TextColor3 = sOwned and TEXTCOL or DIMTEXT
				sw.Text = s.skin:upper() .. (isOn and " ✓" or "") .. (sOwned and "" or "\n🔒")
				sw.Parent = strip
				corner(sw, 5); ledge(sw, isOn and ACCENT or TBLACK, isOn and 2.5 or 1.5)
				if sOwned then
					sw.Activated:Connect(function()
						lplay("Equip")
						EquipSkin:FireServer({ weaponId = id, skinId = (not isOn) and s.skin or false })
					end)
				end
			end
		end

		if not ownsGun(id) then
			local reqLevel = tonumber(w.unlock) or 0
			local myLevel = localPlayer:GetAttribute("AccountLevel") or 1
			-- XP-ONLY unlocks: no buying. Reaching the level grants the gun automatically.
			local lockLbl = centered(330, 22, BODYB_FACE, 18, DIMTEXT)
			lockLbl.Text = "🔒 UNLOCKS AT LEVEL " .. reqLevel
			local note = bigButton(invDetail, ("REACH LV %d TO UNLOCK"):format(reqLevel), GHOSTA, GHOSTB, DIMTEXT)
			note.AutoButtonColor = false
			note.Position = UDim2.fromOffset(14, 356); note.Size = UDim2.new(1, -28, 0, 56)
		end

		-- RIGHT STACK: two big SLOT BOXES showing the current PRIMARY + SECONDARY guns (click to feature).
		local function slotBox(label, slotNum, yPos)
			local gid = invData.loadout[slotNum]
			local box = Instance.new("TextButton")
			box.Position = UDim2.new(0, 0, 0, yPos); box.Size = UDim2.new(1, 0, 0, 226)
			box.BackgroundColor3 = gid and rarityColor((weaponInfo(gid) or {}).rarity or "common"):Lerp(BLACK, 0.6) or darker(PANEL2, 0.15)
			box.AutoButtonColor = gid ~= nil; box.Text = ""; box.BorderSizePixel = 0; box.Parent = invActs
			corner(box, 7); ledge(box, (gid and selectedInv and selectedInv.id == gid) and ACCENT or TBLACK, 2.5); cardShade(box)
			local tag = Instance.new("TextLabel")
			tag.Position = UDim2.fromOffset(8, 6); tag.Size = UDim2.new(1, -16, 0, 18); tag.BackgroundTransparency = 1
			tag.FontFace = TITLE_FACE; tag.TextSize = 13; tag.TextXAlignment = Enum.TextXAlignment.Left
			tag.TextColor3 = ACCENT; tag.Text = label; tag.ZIndex = 3; tag.Parent = box
			if gid then
				local gvp = makeGunViewport(gid, false)
				if gvp then gvp.Position = UDim2.fromOffset(0, 20); gvp.Size = UDim2.new(1, 0, 1, -46); gvp.Parent = box end
				local gnm = Instance.new("TextLabel")
				gnm.AnchorPoint = Vector2.new(0, 1); gnm.Position = UDim2.new(0, 0, 1, -4); gnm.Size = UDim2.new(1, 0, 0, 22)
				gnm.BackgroundTransparency = 1; gnm.FontFace = BODYB_FACE; gnm.TextSize = 14
				gnm.TextColor3 = TEXTCOL; gnm.Text = (weaponInfo(gid) or {}).name or gid; gnm.ZIndex = 3; gnm.Parent = box
				local gs = Instance.new("UIStroke"); gs.Color = TBLACK; gs.Thickness = 1.3
				gs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; gs.Parent = gnm
				box.Activated:Connect(function()
					selectedInv = { kind = "weapon", id = gid }
					renderActive()
				end)
			else
				local empty = Instance.new("TextLabel")
				empty.Position = UDim2.fromOffset(0, 20); empty.Size = UDim2.new(1, 0, 1, -20); empty.BackgroundTransparency = 1
				empty.FontFace = TITLE_FACE; empty.TextSize = 16; empty.TextColor3 = DIMTEXT
				empty.Text = "EMPTY"; empty.Parent = box
			end
		end
		slotBox("PRIMARY", 1, 0)
		slotBox("SECONDARY", 2, 240)
	elseif kind == "skin" then
		local s = entry
		nm.Text = s.name
		local rar = centered(246, 20, BODYB_FACE, 15, wellCol)
		rar.Text = ((invData.catalog.rarities[s.rarity] or {}).name or "") .. " SKIN"
		local forGun = centered(274, 20, BODY_FACE, 14, TEXTCOL)
		local gw = weaponInfo(s.gun)
		forGun.Text = "For: " .. (gw and gw.name or s.gun)
		local owned = ownsSkin(id)
		local status = centered(300, 20, BODYB_FACE, 13, owned and ACCENT or DIMTEXT)
		local isOn = owned and invData.skins.equipped and invData.skins.equipped[s.gun] == s.skin
		status.Text = isOn and "EQUIPPED" or (owned and "OWNED" or "LOCKED — pull it from a skin crate")

		if owned and ownsGun(s.gun) then
			local btn
			if isOn then
				btn = paneButton("REMOVE SKIN", GHOSTA, GHOSTB, TEXTCOL)
				btn.Activated:Connect(function()
					lplay("Equip")
					EquipSkin:FireServer({ weaponId = s.gun, skinId = false })
				end)
			else
				btn = paneButton("EQUIP SKIN", ACCENT, darker(ACCENT, 0.5), Color3.new(1, 1, 1))
				btn.Activated:Connect(function()
					lplay("Equip")
					EquipSkin:FireServer({ weaponId = s.gun, skinId = s.skin })
				end)
			end
			btn.Position = UDim2.new(0, 0, 0, 0); btn.Size = UDim2.new(1, 0, 0, 56)
		elseif owned then
			local note = paneButton("BUY THE GUN FIRST", GHOSTA, GHOSTB, DIMTEXT)
			note.AutoButtonColor = false
			note.Position = UDim2.new(0, 0, 0, 0); note.Size = UDim2.new(1, 0, 0, 56)
		else
			local note = paneButton("FIND IT IN SKIN CRATES", GHOSTA, GHOSTB, DIMTEXT)
			note.AutoButtonColor = false
			note.Position = UDim2.new(0, 0, 0, 0); note.Size = UDim2.new(1, 0, 0, 56)
		end
	elseif kind == "case" then
		nm.Text = entry.name
		local count = invData.cases[id] or 0
		local have = centered(246, 20, BODYB_FACE, 15, TEXTCOL)
		have.Text = ("You have: x%d"):format(count)
		local oddsHead = centered(276, 20, TITLE_FACE, 15, TEXTCOL)
		oddsHead.Text = "RARITIES"
		local y = 300
		for _, o in (entry.odds or {}) do
			local l = centered(y, 17, BODYB_FACE, 13, rarityColor(o.rarity))
			l.Text = ("%s - %.1f%%"):format((invData.catalog.rarities[o.rarity] or {}).name or o.rarity, o.pct)
			y += 19
		end

		local open
		if count > 0 then
			open = paneButton("OPEN CRATE", ACCENT, darker(ACCENT, 0.5), Color3.new(1, 1, 1))
			open.Activated:Connect(function()
				if rolling then return end
				rolling = true
				armRollTimeout()
				OpenCase:FireServer({ caseId = id })
			end)
		else
			open = paneButton("NONE LEFT", GHOSTA, GHOSTB, DIMTEXT)
			open.AutoButtonColor = false
		end
		open.Position = UDim2.new(0, 0, 0, 0); open.Size = UDim2.new(1, 0, 0, 56)
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
	for i, id in ids do
		local w = weaponInfo(id)
		local owned = ownsGun(id)
		local slotTag = (invData.loadout[1] == id and "PRIM") or (invData.loadout[2] == id and "SEC") or nil
		invCard({
			kind = "weapon", id = id, name = w.name, color = rarityColor(w.rarity),
			tag = slotTag, order = i, image = w.image,
			nextUp = (id == nextUnlockId) or nil,
			lockLevel = (not owned) and (w.unlock or 0) or nil,
			chip = (id == nextUnlockId) and "NEXT UP" or nil,
			locked = not owned,
		})
	end
	return ids
end

local function renderCasesGrid()
	local ids = {}
	for _, caseId in invData.catalog.rarityOrder do
		local disp = invData.catalog.cases[caseId]
		local count = invData.cases[caseId] or 0
		if disp and count > 0 then
			table.insert(ids, caseId)
			invCard({ kind = "case", id = caseId, name = disp.name, color = rarityColor(caseId), chip = "x" .. count, order = #ids, image = disp.image })
		end
	end
	if #ids == 0 then
		invEmptyNote("No skin crates right now — kill BOSSES in runs (or hit the SHOP) to get more!")
	end
	return ids
end

-- ===== SCREEN SWITCHING + MASTER RENDER ===== ("weapons" = the GUNS screen, "cases" = the CASES screen)
local function showTab(id)
	activeTab = id
	selectedInv = nil -- switching screens resets the featured pane
	invTitle.Text = (id == "weapons") and "GUNS" or "SKIN CRATES"
	local hc = (id == "weapons") and HEADER_COLORS.guns or HEADER_COLORS.cases
	invHeaderBar.BackgroundColor3 = hc
	invHeaderSq.BackgroundColor3 = hc
	invEdge.Color = hc
end

renderActive = function()
	invCoins.Text = "🪙 " .. fmt(invData and invData.coins or 0)
	if not invData then return end
	local tabKind = (activeTab == "weapons") and "weapon" or "case"
	-- The pane is permanent (like the shop's featured slot): default to the screen's first item whenever
	-- nothing valid is selected. Two passes because selection paints the card outline.
	local function paintGrid()
		clearChildren(invGrid)
		if activeTab == "weapons" then return renderWeaponsGrid()
		else return renderCasesGrid() end
	end
	local ids = paintGrid()
	local valid = selectedInv and selectedInv.kind == tabKind and table.find(ids, selectedInv.id) ~= nil
	if not valid then
		selectedInv = ids[1] and { kind = tabKind, id = ids[1] } or nil
		paintGrid()
	end
	renderInvDetail()
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
		local tvp = makeGunViewport(id, false) or (sInfo and makeGunViewport(sInfo.gun, false)) -- skin model, else base gun
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
	if invPanel.Visible then
		renderActive()
	end
end)

CaseResult.OnClientEvent:Connect(function(res)
	rollToken += 1 -- a reply arrived; disarm the watchdog
	if typeof(res) ~= "table" or res.failed or not res.caseId then
		lplay("Error")
		rolling = false
		if invPanel.Visible then
			renderActive() -- restore any "..." button state
		end
		return
	end
	if invPanel.Visible then
		showTab("cases") -- make sure we're on the cases view behind the reel
	end
	playReel(res.caseId, res.wonId, res)
end)

-- =====================================================================================================
-- ===== SHOP ===== single-column stock list (left) + a FEATURED detail pane (right) that defaults to
-- the Deal of the Rotation. Click any row to feature it; BUY / BUY & OPEN live on the pane.
-- =====================================================================================================
local ShopSync  = remotes:WaitForChild("ShopSync")
local ShopClose = remotes:WaitForChild("ShopClose")
local ShopBuy   = remotes:WaitForChild("ShopBuy")

local shopData = nil     -- latest ShopSync payload
local shopDeadline = 0   -- os.clock() when the current rotation restocks
local shopSelected = nil -- featured slot index (defaults to the deal)

local shopGui = Instance.new("ScreenGui")
shopGui.Name = "LobbyShop"; shopGui.ResetOnSpawn = false; shopGui.IgnoreGuiInset = true; shopGui.DisplayOrder = 10
shopGui.Parent = playerGui
lattach(shopGui)

local shopPanel = Instance.new("Frame")
shopPanel.AnchorPoint = Vector2.new(0.5, 0.5); shopPanel.Position = UDim2.fromScale(0.5, 0.5)
shopPanel.Size = UDim2.fromOffset(940, 560); shopPanel.BackgroundColor3 = PANEL
shopPanel.BackgroundTransparency = 0.12; shopPanel.BorderSizePixel = 0; shopPanel.Visible = false; shopPanel.Parent = shopGui
corner(shopPanel, 8)
lstuds(shopPanel); ldepth(shopPanel); ledge(shopPanel, TBLACK, 3); ledge(shopPanel, HEADER_COLORS.shop, 2.5, 0.05)

headerBar(shopPanel, 48, HEADER_COLORS.shop)
local shopTitle = Instance.new("TextLabel")
shopTitle.Position = UDim2.fromOffset(18, 0); shopTitle.Size = UDim2.fromOffset(200, 46); shopTitle.BackgroundTransparency = 1
shopTitle.FontFace = TITLE_FACE; shopTitle.TextSize = 28; shopTitle.TextXAlignment = Enum.TextXAlignment.Left
shopTitle.TextColor3 = TEXTCOL; shopTitle.Text = "SHOP"; shopTitle.Parent = shopPanel

local shopRestock = Instance.new("TextLabel")
shopRestock.Position = UDim2.fromOffset(240, 0); shopRestock.Size = UDim2.fromOffset(240, 48); shopRestock.BackgroundTransparency = 1
shopRestock.FontFace = BODYB_FACE; shopRestock.TextSize = 13; shopRestock.TextXAlignment = Enum.TextXAlignment.Left
shopRestock.TextColor3 = DIMTEXT; shopRestock.Text = ""; shopRestock.Parent = shopPanel

local shopCoins = Instance.new("TextLabel")
shopCoins.AnchorPoint = Vector2.new(1, 0); shopCoins.Position = UDim2.new(1, -64, 0, 14); shopCoins.Size = UDim2.fromOffset(170, 24)
shopCoins.BackgroundTransparency = 1; shopCoins.FontFace = BODYB_FACE; shopCoins.TextSize = 16
shopCoins.TextXAlignment = Enum.TextXAlignment.Right; shopCoins.TextColor3 = GOLD; shopCoins.Text = ""; shopCoins.Parent = shopPanel

local shopX = redX(shopPanel, 44, 26)
shopX.Position = UDim2.new(1, -8, 0, 2)

-- Reference-image structure: crate GRID (left) | FEATURED case (middle) | BUY buttons (right).
local shopGrid = Instance.new("ScrollingFrame")
shopGrid.Position = UDim2.fromOffset(16, 64); shopGrid.Size = UDim2.fromOffset(346, 480)
shopGrid.BackgroundTransparency = 1; shopGrid.BorderSizePixel = 0
shopGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y; shopGrid.CanvasSize = UDim2.new()
shopGrid.ScrollBarThickness = 6; shopGrid.ScrollBarImageColor3 = DIMTEXT; shopGrid.Parent = shopPanel
local shopGridLayout = Instance.new("UIGridLayout")
shopGridLayout.CellSize = UDim2.fromOffset(166, 152); shopGridLayout.CellPadding = UDim2.fromOffset(12, 12)
shopGridLayout.SortOrder = Enum.SortOrder.LayoutOrder; shopGridLayout.Parent = shopGrid

local shopDetail = Instance.new("Frame")
shopDetail.Position = UDim2.fromOffset(378, 64); shopDetail.Size = UDim2.fromOffset(280, 480)
shopDetail.BackgroundColor3 = PANEL2; shopDetail.BorderSizePixel = 0; shopDetail.Parent = shopPanel
corner(shopDetail, 6); lstuds(shopDetail, 42, 0.75); ledge(shopDetail, TBLACK, 2); ledge(shopDetail, GOLD, 1, 0.55)

local shopBuys = Instance.new("Frame")
shopBuys.AnchorPoint = Vector2.new(1, 0); shopBuys.Position = UDim2.new(1, -16, 0, 64)
shopBuys.Size = UDim2.fromOffset(250, 480); shopBuys.BackgroundTransparency = 1; shopBuys.Parent = shopPanel

-- Restock flash overlay (the "new stock just landed" blink).
local shopFlash = Instance.new("Frame")
shopFlash.Size = UDim2.fromScale(1, 1); shopFlash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
shopFlash.BackgroundTransparency = 1; shopFlash.BorderSizePixel = 0; shopFlash.ZIndex = 20; shopFlash.Parent = shopPanel
corner(shopFlash, 8)
local function flashShop()
	shopFlash.BackgroundTransparency = 0.8
	TweenService:Create(shopFlash, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
end

local function shopClear(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

local renderShop -- forward decl

-- One crate CELL in the grid (like the reference): the crate render fills the card, price under it.
local function shopCell(i, slot)
	local col = rarityColor(slot.caseId)
	local soldOut = (slot.left or 0) < 1
	local isSel = (shopSelected == i)
	local cell = Instance.new("TextButton")
	cell.BackgroundColor3 = soldOut and darker(PANEL2, 0.25) or col:Lerp(BLACK, 0.62)
	cardShade(cell)
	cell.AutoButtonColor = true; cell.Text = ""; cell.BorderSizePixel = 0; cell.LayoutOrder = i; cell.Parent = shopGrid
	corner(cell, 7); ledge(cell, isSel and GOLD or TBLACK, isSel and 3 or 2.5)
	local vp = makeGunViewport(slot.caseId, false, "CrateDisplay") -- static: only the featured pane spins
	if vp then
		vp.Size = UDim2.new(1, 0, 1, -26)
		vp.ImageTransparency = soldOut and 0.6 or 0
		vp.Parent = cell
	else
		local plate = Instance.new("TextLabel")
		plate.Size = UDim2.new(1, -12, 1, -30); plate.Position = UDim2.fromOffset(6, 4); plate.BackgroundTransparency = 1
		plate.FontFace = TITLE_FACE; plate.TextSize = 15; plate.TextWrapped = true
		plate.TextColor3 = soldOut and DIMTEXT or col; plate.Text = slot.name or "Case"; plate.Parent = cell
	end
	local price = Instance.new("TextLabel")
	price.AnchorPoint = Vector2.new(0, 1); price.Position = UDim2.new(0, 0, 1, -4); price.Size = UDim2.new(1, 0, 0, 22)
	price.BackgroundTransparency = 1; price.FontFace = BODYB_FACE; price.TextSize = 15
	price.TextColor3 = soldOut and DIMTEXT or GOLD
	if slot.basePrice and slot.basePrice ~= slot.price then
		price.RichText = true
		price.Text = ('<font color="#8a8f7c"><s>%s</s></font>  🪙 %s'):format(fmt(slot.basePrice), fmt(slot.price or 0))
	else
		price.Text = "🪙 " .. fmt(slot.price or 0)
	end
	price.Parent = cell
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = TBLACK; pStroke.Thickness = 1.3; pStroke.Transparency = 0.3
	pStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; pStroke.Parent = price
	local chip = Instance.new("TextLabel")
	chip.Position = UDim2.fromOffset(6, 6); chip.Size = UDim2.fromOffset(52, 18)
	chip.BackgroundColor3 = soldOut and TRACK or darker(col, 0.7); chip.BorderSizePixel = 0; chip.ZIndex = 3
	chip.FontFace = BODYB_FACE; chip.TextSize = 10
	chip.TextColor3 = soldOut and DIMTEXT or col
	chip.Text = soldOut and "OUT" or (slot.left .. " LEFT"); chip.Parent = cell
	corner(chip, 4)
	if slot.dealPct then
		local badge = Instance.new("TextLabel")
		badge.AnchorPoint = Vector2.new(1, 0); badge.Position = UDim2.new(1, -6, 0, 6); badge.Size = UDim2.fromOffset(48, 18)
		badge.BackgroundColor3 = GOLD; badge.BorderSizePixel = 0; badge.ZIndex = 3
		badge.FontFace = TITLE_FACE; badge.TextSize = 11; badge.TextColor3 = Color3.fromRGB(34, 24, 6)
		badge.Text = ("-%d%%"):format(slot.dealPct); badge.Parent = cell
		corner(badge, 4)
	end
	if soldOut then
		local stamp = Instance.new("TextLabel")
		stamp.AnchorPoint = Vector2.new(0.5, 0.5); stamp.Position = UDim2.fromScale(0.5, 0.45)
		stamp.Size = UDim2.new(1, 0, 0, 26); stamp.BackgroundTransparency = 1; stamp.Rotation = -10; stamp.ZIndex = 4
		stamp.FontFace = TITLE_FACE; stamp.TextSize = 19; stamp.TextColor3 = ORANGE; stamp.Text = "SOLD OUT"; stamp.Parent = cell
		local sStroke = Instance.new("UIStroke")
		sStroke.Color = TBLACK; sStroke.Thickness = 1.6; sStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; sStroke.Parent = stamp
	end
	cell.Activated:Connect(function()
		shopSelected = i
		renderShop()
	end)
end

-- The featured column (middle): big crate render, centered name/price/odds. The buy stack renders
-- into shopBuys (right column), like the reference image.
local function renderShopDetail()
	shopClear(shopDetail)
	shopClear(shopBuys)
	if not shopData or not shopSelected then
		return
	end
	local slot = shopData.slots[shopSelected]
	if not slot then
		return
	end
	local col = rarityColor(slot.caseId)
	local soldOut = (slot.left or 0) < 1
	local afford = (shopData.coins or 0) >= (slot.price or 0)

	-- Big render well.
	local well = Instance.new("Frame")
	well.Position = UDim2.fromOffset(14, 14); well.Size = UDim2.new(1, -28, 0, 190)
	well.BackgroundColor3 = col:Lerp(BLACK, 0.7); well.BorderSizePixel = 0; well.Parent = shopDetail
	corner(well, 6); ledge(well, TBLACK, 2)
	local caseInfo = invData and invData.catalog.cases[slot.caseId]
	local imageId = caseInfo and caseInfo.image
	local wellVp = makeGunViewport(slot.caseId, true, "CrateDisplay")
	if wellVp then
		wellVp.Size = UDim2.fromScale(1, 1); wellVp.Parent = well
	elseif typeof(imageId) == "string" and imageId ~= "" then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1; img.Size = UDim2.fromScale(1, 1)
		img.Image = imageId; img.ScaleType = Enum.ScaleType.Fit; img.Parent = well
	else
		local plate = Instance.new("TextLabel")
		plate.Size = UDim2.fromScale(1, 1); plate.BackgroundTransparency = 1
		plate.FontFace = TITLE_FACE; plate.TextSize = 26; plate.TextColor3 = col
		plate.Text = "CASE"; plate.Parent = well
	end
	if slot.dealPct then
		local badge = Instance.new("TextLabel")
		badge.AnchorPoint = Vector2.new(1, 0); badge.Position = UDim2.new(1, -8, 0, 8); badge.Size = UDim2.fromOffset(72, 24)
		badge.BackgroundColor3 = GOLD; badge.BorderSizePixel = 0; badge.ZIndex = 3
		badge.FontFace = TITLE_FACE; badge.TextSize = 14; badge.TextColor3 = Color3.fromRGB(34, 24, 6)
		badge.Text = ("-%d%%"):format(slot.dealPct); badge.Parent = well
		corner(badge, 4)
	end

	local function centered(y, h, face, size, colr)
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromOffset(14, y); l.Size = UDim2.new(1, -28, 0, h); l.BackgroundTransparency = 1
		l.FontFace = face; l.TextSize = size; l.TextColor3 = colr; l.Parent = shopDetail
		return l
	end

	local nm = centered(216, 28, TITLE_FACE, 22, col)
	nm.Text = slot.name or "Case"
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = TBLACK; nmStroke.Thickness = 1.5; nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; nmStroke.Parent = nm

	local price = centered(248, 26, BODYB_FACE, 20, GOLD)
	if slot.basePrice and slot.basePrice ~= slot.price then
		price.RichText = true
		price.Text = ('<font color="#8a8f7c"><s>%s</s></font>  🪙 %s'):format(fmt(slot.basePrice), fmt(slot.price or 0))
	else
		price.Text = "🪙 " .. fmt(slot.price or 0)
	end

	local stockLbl = centered(278, 16, BODY_FACE, 12, DIMTEXT)
	stockLbl.Text = soldOut and "SOLD OUT — restocks next rotation" or ("%d of %d left for you"):format(slot.left or 0, slot.stock or 0)

	local rarHead = centered(306, 22, TITLE_FACE, 17, TEXTCOL)
	rarHead.Text = "RARITIES"

	local disp = invData and invData.catalog.cases[slot.caseId]
	local y = 332
	if disp and disp.odds then
		for _, o in disp.odds do
			local l = centered(y, 17, BODYB_FACE, 13, rarityColor(o.rarity))
			l.Text = ("%s - %.1f%%"):format((invData.catalog.rarities[o.rarity] or {}).name or o.rarity, o.pct)
			y += 19
		end
	end

	-- RIGHT column: BUY 1 + BUY & OPEN for the featured crate, and a GOLD "BUY ALL CRATES" that sweeps
	-- every slot's remaining stock (cheapest first, server-clamped to your coins).
	local function buyBtn(textStr, style, enabled)
		local b = Instance.new("TextButton")
		b.BorderSizePixel = 0; b.AutoButtonColor = enabled
		b.FontFace = TITLE_FACE; b.TextSize = 18; b.Parent = shopBuys
		corner(b, 6); ledge(b, TBLACK, 2.5)
		if not enabled then
			b.BackgroundColor3 = TRACK; b.TextColor3 = DIMTEXT
		elseif style == "gold" then
			b.BackgroundColor3 = GOLD; b.TextColor3 = Color3.new(1, 1, 1) -- white like the game's SKIP WAVE
			lbevel(b)
		elseif style == "primary" then
			b.BackgroundColor3 = SELBG; b.TextColor3 = TEXTCOL
			lbevel(b)
		else
			b.BackgroundColor3 = PANEL2; b.TextColor3 = TEXTCOL
			ledge(b, ACCENT, 1, 0.5); lbevel(b)
		end
		local ts = Instance.new("UIStroke")
		ts.Color = TBLACK; ts.Thickness = 1.3; ts.Transparency = 0.3
		ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; ts.Parent = b
		b.Text = textStr
		return b
	end

	-- ONE big BUY button (banks 1 crate — open it from SKIN CRATES). BUY & OPEN / BUY ALL are gone.
	local canBuySel = not soldOut and afford
	local buy1 = buyBtn(soldOut and "SOLD OUT" or (afford and "BUY" or "NEED MORE COINS"), "primary", canBuySel)
	buy1.Position = UDim2.new(0, 0, 0, 0); buy1.Size = UDim2.new(1, 0, 0, 72)
	buy1.TextSize = 20
	if canBuySel then
		buy1.Activated:Connect(function()
			lplay("Buy")
			ShopBuy:FireServer({ slot = shopSelected, open = false, qty = 1 })
		end)
	end
end

renderShop = function()
	if not shopData then return end
	shopCoins.Text = "🪙 " .. fmt(shopData.coins or 0)
	shopClear(shopGrid)
	for i, slot in ipairs(shopData.slots) do
		shopCell(i, slot)
	end
	renderShopDetail()
end

-- Default feature = the Deal of the Rotation (else the first slot still in stock, else slot 1).
local function defaultShopSelection()
	for i, slot in ipairs(shopData.slots) do
		if slot.dealPct then return i end
	end
	for i, slot in ipairs(shopData.slots) do
		if (slot.left or 0) > 0 then return i end
	end
	return 1
end

-- Live countdown + the "RESTOCKING..." beat while we wait for the server's new-window push.
task.spawn(function()
	while true do
		task.wait(0.5)
		if shopPanel.Visible then
			local left = shopDeadline - os.clock()
			if left > 0 then
				shopRestock.Text = ("NEW STOCK IN %d:%02d"):format(math.floor(left / 60), math.floor(left) % 60)
			else
				shopRestock.Text = "RESTOCKING..."
			end
		end
	end
end)

ShopSync.OnClientEvent:Connect(function(p)
	if typeof(p) ~= "table" or typeof(p.slots) ~= "table" then return end
	local prevWindow = shopData and shopData.window
	local windowChanged = prevWindow and p.window and p.window ~= prevWindow
	shopData = p
	shopDeadline = os.clock() + (tonumber(p.endsIn) or 0)
	if windowChanged or not shopSelected or not shopData.slots[shopSelected] then
		shopSelected = defaultShopSelection()
	end
	if p.enter then
		if not shopPanel.Visible then lplay("Open"); uiFocusOpen() end
		shopPanel.Visible = true
	end
	if shopPanel.Visible then
		renderShop()
		if windowChanged then
			flashShop() -- instant swap: the rotation rolled over while browsing
		end
	end
end)

ShopClose.OnClientEvent:Connect(function()
	if shopPanel.Visible then uiFocusClose() end
	shopPanel.Visible = false
end)
shopX.Activated:Connect(function()
	lplay("Close")
	if shopPanel.Visible then uiFocusClose() end
	shopPanel.Visible = false -- walk off + back on to reopen
end)

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

	local gear = Instance.new("TextButton")
	gear.AnchorPoint = Vector2.new(1, 1); gear.Position = UDim2.new(1, -12, 1, -12); gear.Size = UDim2.fromOffset(48, 48)
	gear.BackgroundColor3 = PANEL; gear.BorderSizePixel = 0; gear.FontFace = BODYB_FACE
	gear.TextSize = 24; gear.TextColor3 = DIMTEXT; gear.Text = "⚙"; gear.Parent = setGui
	corner(gear, 8); lstuds(gear); ldepth(gear); ledge(gear)

	local sPanel = Instance.new("Frame")
	sPanel.AnchorPoint = Vector2.new(1, 1); sPanel.Position = UDim2.new(1, -12, 1, -68)
	sPanel.Size = UDim2.fromOffset(340, 312); sPanel.BackgroundColor3 = PANEL; sPanel.BackgroundTransparency = 0.12
	sPanel.BorderSizePixel = 0; sPanel.Visible = false; sPanel.Parent = setGui
	corner(sPanel, 8); lstuds(sPanel); ldepth(sPanel); ledge(sPanel, TBLACK, 3); ledge(sPanel, HEADER_COLORS.settings, 2.5, 0.05)

	headerBar(sPanel, 48, HEADER_COLORS.settings)
	local sTitle = Instance.new("TextLabel")
	sTitle.Position = UDim2.fromOffset(18, 0); sTitle.Size = UDim2.fromOffset(200, 44); sTitle.BackgroundTransparency = 1
	sTitle.FontFace = TITLE_FACE; sTitle.TextSize = 22; sTitle.TextXAlignment = Enum.TextXAlignment.Left
	sTitle.TextColor3 = TEXTCOL; sTitle.Text = "SETTINGS"; sTitle.Parent = sPanel

	local sClose = redX(sPanel, 44, 20)
	sClose.Position = UDim2.new(1, -6, 0, 6)

	local function sliderRow(y, labelText, get, set)
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromOffset(18, y); label.Size = UDim2.fromOffset(120, 18); label.BackgroundTransparency = 1
		label.FontFace = BODYB_FACE; label.TextSize = 15; label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = DIMTEXT; label.Text = labelText; label.Parent = sPanel

		local pct = Instance.new("TextLabel")
		pct.AnchorPoint = Vector2.new(1, 0); pct.Position = UDim2.new(1, -18, 0, y); pct.Size = UDim2.fromOffset(60, 18)
		pct.BackgroundTransparency = 1; pct.FontFace = BODYB_FACE; pct.TextSize = 15
		pct.TextXAlignment = Enum.TextXAlignment.Right; pct.TextColor3 = TEXTCOL; pct.Parent = sPanel

		local track = Instance.new("TextButton")
		track.Position = UDim2.fromOffset(18, y + 24); track.Size = UDim2.new(1, -36, 0, 14)
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
		label.Position = UDim2.fromOffset(18, y); label.Size = UDim2.fromOffset(180, 26); label.BackgroundTransparency = 1
		label.FontFace = BODYB_FACE; label.TextSize = 15; label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = DIMTEXT; label.Text = labelText; label.Parent = sPanel

		local sw = Instance.new("TextButton")
		sw.AnchorPoint = Vector2.new(1, 0.5); sw.Position = UDim2.new(1, -18, 0, y + 13); sw.Size = UDim2.fromOffset(64, 30)
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
	local renders = {
		sliderRow(58, "MASTER", function() return volMaster end, function(v) volMaster = v end),
		sliderRow(120, "MUSIC", function() return volMusic end, function(v) volMusic = v end),
		sliderRow(182, "SFX", function() return volSfx end, function(v) volSfx = v end),
		toggleRow(244, "CAMERA SHAKE", function()
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

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0, 1); bar.Position = UDim2.new(0, 16, 1, -12); bar.Size = UDim2.fromOffset(320, 56)
	bar.BackgroundColor3 = PANEL; bar.BackgroundTransparency = 0.15; bar.BorderSizePixel = 0; bar.Parent = xpGui
	corner(bar, 8); lstuds(bar); ldepth(bar); ledge(bar, TBLACK, 3); ledge(bar, ACCENT, 2, 0.35)

	local lvl = Instance.new("TextLabel")
	lvl.Position = UDim2.fromOffset(12, 0); lvl.Size = UDim2.fromOffset(74, 56); lvl.BackgroundTransparency = 1
	lvl.FontFace = TITLE_FACE; lvl.TextSize = 26; lvl.TextColor3 = Color3.fromRGB(66, 165, 245); lvl.Text = "LVL 1" -- XP/level is BLUE
	lvl.TextXAlignment = Enum.TextXAlignment.Left; lvl.Parent = bar
	local lvlSt = Instance.new("UIStroke"); lvlSt.Color = TBLACK; lvlSt.Thickness = 2; lvlSt.Parent = lvl

	local nextLbl = Instance.new("TextLabel")
	nextLbl.Position = UDim2.fromOffset(92, 8); nextLbl.Size = UDim2.new(1, -104, 0, 18); nextLbl.BackgroundTransparency = 1
	nextLbl.FontFace = BODYB_FACE; nextLbl.TextSize = 14; nextLbl.TextXAlignment = Enum.TextXAlignment.Left
	nextLbl.TextColor3 = TEXTCOL; nextLbl.Text = ""; nextLbl.TextTruncate = Enum.TextTruncate.AtEnd; nextLbl.Parent = bar
	local nextSt = Instance.new("UIStroke"); nextSt.Color = TBLACK; nextSt.Thickness = 1.5; nextSt.Parent = nextLbl

	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0, 1); track.Position = UDim2.new(0, 92, 1, -10); track.Size = UDim2.new(1, -104, 0, 16)
	track.BackgroundColor3 = TRACK; track.BorderSizePixel = 0; track.Parent = bar
	corner(track, 8); ledge(track, TBLACK, 1.5)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0); fill.BackgroundColor3 = Color3.fromRGB(66, 165, 245); fill.BorderSizePixel = 0; fill.Parent = track
	corner(fill, 8)
	local xpTxt = Instance.new("TextLabel")
	xpTxt.Size = UDim2.fromScale(1, 1); xpTxt.BackgroundTransparency = 1; xpTxt.ZIndex = 2
	xpTxt.FontFace = BODYB_FACE; xpTxt.TextSize = 12; xpTxt.TextColor3 = TEXTCOL; xpTxt.Text = ""; xpTxt.Parent = track
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

print("[LobbyClient] started")
