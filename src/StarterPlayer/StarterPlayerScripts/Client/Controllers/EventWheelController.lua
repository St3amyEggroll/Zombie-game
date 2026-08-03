--!nonstrict
-- EventWheelController.lua — THE EVENT ROLLER, REEL v2 (owner-approved mock). Every wave break the
-- server broadcasts EventSpin in TWO stages: {wave, seconds, odds} starts the roll WITHOUT the
-- outcome (anti-datamine), then {wave, lock = outcome} lands at half-spin. This runs the show:
--   1. THE DIM — gameplay fades back ~50%; the roll owns the screen (sits above hotbar/boss/chrome).
--   2. THE REEL — a clipped window in the band; event names scroll VERTICALLY through it like a slot
--      machine, each row stamped with its live % chance, visibly losing momentum until the locked
--      outcome glides into the center rails and settles.
--   3. THE LOCK FLOOD — neighbors snuff out, the centered name blooms in its event color (punch
--      scaled by rarity), burst rays fire, the band + screen edges glow the color for the hold.
-- Pure theater: the server already decided the outcome. Sounds: WheelSpin loops the scroll,
-- WheelLock lands with the flood.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)
local LobbyLook = require(Shared.Modules.LobbyLook)

local SoundController = require(script.Parent.SoundController) -- WheelSpin during the roll, WheelLock on the land
local HUDController = require(script.Parent.HUDController)     -- the event badge the reveal flies into

local EventWheelController = {}

-- ===== TUNABLES =====
local BAND_W = 560         -- CHANGED (owner): band width (px, hud-scaled) — a CENTERED STRIP, not
                           -- edge-to-edge ("it stretches from the left of the screen to the right").
                           -- 560 gives the 40pt names room ("LIGHTNING STORM" is the longest).
local ROW_H = 68           -- one reel row (px, hud-scaled) — CHANGED (owner): bigger letters again
local WINDOW_ROWS = 3      -- rows visible in the clipped window (center + one each side)
local BAND_Y = 0.11        -- band top, fraction of the screen (owner: tucked right under the wave strip)
local DIM = 0.52           -- how dark the dimmer gets (0 = none, 1 = black)
local EASE_POW = 3.6       -- scroll deceleration curve (higher = harder slam at the end)
local STEPS_PER_SEC = 7    -- how many rows scroll past per second of spin (before deceleration shaping)
-- Spectacle scales with the ODDS — the rarer the landing, the harder it hits. `edge` = the screen-edge
-- glow's transparency (1 = none at all): everyday rolls DON'T wash the screen; only rare ones do.
local function dramaFor(pct: number)
	if pct <= 1.5 then
		return { punch = 1.32, hold = 3.4, rays = 14, edge = 0.6 } -- the 1%ers: full fireworks
	elseif pct <= 4 then
		return { punch = 1.22, hold = 2.9, rays = 12, edge = 0.72 }
	elseif pct <= 8 then
		return { punch = 1.15, hold = 2.5, rays = 10, edge = 0.82 }
	end
	return { punch = 1.1, hold = 2.2, rays = 8, edge = 1 } -- common rolls: no screen wash at all
end

-- What each outcome reads as (server sends only the id + odds). CHANGED: the names/colours moved to
-- Shared/Config/EventLook so the reel and the HUD's live event chip can never drift apart.
local LOOK = require(Shared.Config.EventLook)
local IDS = {}
for id in LOOK do
	table.insert(IDS, id)
end
table.sort(IDS)

local BAND_DARK = Color3.fromRGB(5, 7, 4)
local HAIR_IDLE = Color3.fromRGB(90, 97, 72)
local ROW_DIM = Color3.fromRGB(168, 174, 156)   -- neighbor rows — CHANGED: brighter (they read blacked-out)
local PCT_DIM = Color3.fromRGB(132, 139, 120)   -- neighbor % lines

local WINDOW_H = ROW_H * WINDOW_ROWS
local BAND_H = WINDOW_H + 34 -- title strip above the window

local localPlayer = Players.LocalPlayer

local gui, dimmer, band, hairTop, titleLabel, windowFrame, raysHolder
local edges = {}  -- the 4 screen-edge glow frames
local rays = {}   -- pre-built burst spokes behind the centered word
local slots = {}  -- the recycled row frames (WINDOW_ROWS + 2 of them)
local spinToken = 0
local pendingLockId = nil -- the stage-2 locked outcome (arrives mid-roll; the reel waits on it)
local applyLock = nil     -- set by the active roll: retro-fixes the final strip row when the lock
                          -- lands AFTER that row was already dealt a placeholder name

-- Same predicate the HUD uses to push its top lane down on phones — the band must clear that lane.
local TOUCH = UserInputService.TouchEnabled

-- A full-width frame whose UIGradient fades both ends to nothing (the band treatment).
-- SHORT fade zones (owner call): solid across almost the whole width, dropping off in the last ~7%.
local function fadeEnds(frame: Frame, hard: number?)
	local g = Instance.new("UIGradient")
	local solid = hard or 0.06
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.07, solid),
		NumberSequenceKeypoint.new(0.5, solid),
		NumberSequenceKeypoint.new(0.93, solid),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = frame
end

local function fmtPct(pct: number?): string
	if not pct then
		return ""
	end
	if pct % 1 == 0 then
		return ("%d%% CHANCE"):format(pct)
	end
	return ("%.1f%% CHANCE"):format(pct)
end

-- One recycled reel row: the event name + its % line, popped by its own UIScale on the lock.
local function makeSlot(parent: Frame)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	-- Center-anchored so the lock pop's UIScale blooms in place (top-left anchoring shoves it
	-- down-right — the owner screenshotted exactly this on the old word label).
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Size = UDim2.new(1, 0, 0, ROW_H)
	row.ZIndex = 4
	row.Parent = parent

	local nm = Instance.new("TextLabel")
	nm.Name = "Nm"
	nm.BackgroundTransparency = 1
	nm.AnchorPoint = Vector2.new(0.5, 0)
	nm.Position = UDim2.new(0.5, 0, 0, 1)
	nm.Size = UDim2.new(1, 0, 0, 42)
	nm.FontFace = LobbyLook.TITLE_FACE
	nm.TextSize = 40 -- CHANGED (owner): bigger reel letters, second pass
	nm.TextColor3 = ROW_DIM
	nm.Text = ""
	nm.ZIndex = 4
	nm.Parent = row
	-- THE BLACKED-TEXT BUG (owner report): a UIStroke's transparency is INDEPENDENT of TextTransparency.
	-- Fading a row used to leave the fill translucent while this black outline stayed solid — the word
	-- turned into a black silhouette (worst during the post-lock fade-out, when the fill goes to 0%).
	-- Every place that fades text now fades this stroke WITH it (see fadeText below).
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(0, 0, 0)
	st.Transparency = 0.25
	st.Thickness = 2.6
	st.Parent = nm

	local pc = Instance.new("TextLabel")
	pc.Name = "Pc"
	pc.BackgroundTransparency = 1
	pc.AnchorPoint = Vector2.new(0.5, 0)
	pc.Position = UDim2.new(0.5, 0, 0, 44)
	pc.Size = UDim2.new(1, 0, 0, 18)
	pc.FontFace = LobbyLook.BODYB_FACE
	pc.TextSize = 15
	pc.TextColor3 = PCT_DIM
	pc.Text = ""
	pc.ZIndex = 4
	pc.Parent = row

	local sc = Instance.new("UIScale")
	sc.Parent = row

	return { frame = row, nm = nm, pc = pc, stroke = st, scale = sc, strip = nil, color = nil }
end

-- Fade a reel row's name + its outline TOGETHER (t = 0 solid, 1 invisible). The stroke never gets
-- more opaque than the glyph it outlines, so a fading word never turns into a black silhouette.
local function setRowFade(slot, t: number)
	slot.nm.TextTransparency = t
	slot.stroke.Transparency = math.max(t, 0.25 + t * 0.75)
end

-- Same idea as a tween pair (used by the lock + the tuck-away).
local function tweenRowFade(slot, t: number, info: TweenInfo)
	TweenService:Create(slot.nm, info, { TextTransparency = t }):Play()
	TweenService:Create(slot.stroke, info, { Transparency = math.max(t, 0.25 + t * 0.75) }):Play()
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "EventRoller"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- The roller sits ABOVE the hotbar/boss/chrome layers — the cinematic dim covers everything.
	gui.DisplayOrder = ((UITheme.Layer and (UITheme.Layer.Chrome or UITheme.Layer.HUD) or 8)) + 1
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui, nil, nil, "hud")

	-- 1) THE DIM: gameplay fades back; scale-positioned so it always covers the whole screen.
	dimmer = Instance.new("Frame")
	dimmer.Name = "Dimmer"
	dimmer.Size = UDim2.fromScale(1, 1)
	dimmer.BackgroundColor3 = Color3.fromRGB(4, 6, 3)
	dimmer.BackgroundTransparency = 1
	dimmer.BorderSizePixel = 0
	dimmer.ZIndex = 1
	dimmer.Parent = gui

	-- 3) THE EDGE GLOW: four gradient frames hugging the screen edges, tinted the event color on lock.
	local function edge(name, anchor, pos, size, rot)
		local e = Instance.new("Frame")
		e.Name = name
		e.AnchorPoint = anchor
		e.Position = pos
		e.Size = size
		e.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		e.BackgroundTransparency = 1
		e.BorderSizePixel = 0
		e.ZIndex = 2
		e.Parent = gui
		local g = Instance.new("UIGradient")
		g.Rotation = rot -- fade INTO the screen
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = e
		table.insert(edges, e)
	end
	-- Slim extents (owner screenshot: the first pass washed the WHOLE screen green) — these hug the frame.
	edge("EdgeTop",    Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), UDim2.fromScale(1, 0.08), 90)
	edge("EdgeBottom", Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), UDim2.fromScale(1, 0.08), -90)
	edge("EdgeLeft",   Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), UDim2.fromScale(0.05, 1), 0)
	edge("EdgeRight",  Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), UDim2.fromScale(0.05, 1), 180)

	-- 2) THE BAND: title strip + the clipped reel window.
	band = Instance.new("Frame")
	band.Name = "Band"
	band.AnchorPoint = Vector2.new(0.5, 0)
	-- On touch the band drops below the HUD's 110px top lane (wave strip + LEAVE/SKIP buttons).
	band.Position = TOUCH and UDim2.new(0.5, 0, 0, 164) or UDim2.new(0.5, 0, BAND_Y, 0)
	band.Size = UDim2.new(0, BAND_W, 0, BAND_H) -- CHANGED: fixed-width centered strip (was full-screen)
	band.BackgroundColor3 = BAND_DARK
	band.BackgroundTransparency = 1 -- fades in
	band.BorderSizePixel = 0
	band.Visible = false
	band.ZIndex = 3
	band.Parent = gui
	fadeEnds(band)

	-- ONE hairline, riding the band's top.
	hairTop = Instance.new("Frame")
	hairTop.Name = "HairTop"
	hairTop.AnchorPoint = Vector2.new(0.5, 0.5)
	hairTop.Position = UDim2.new(0.5, 0, 0, 0)
	hairTop.Size = UDim2.new(0.86, 0, 0, 2)
	hairTop.BackgroundColor3 = HAIR_IDLE
	hairTop.BackgroundTransparency = 1
	hairTop.BorderSizePixel = 0
	hairTop.ZIndex = 4
	hairTop.Parent = band
	fadeEnds(hairTop, 0.25)

	titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.new(0, 0, 0, 10)
	titleLabel.Size = UDim2.new(1, 0, 0, 16)
	titleLabel.FontFace = LobbyLook.BODYB_FACE
	titleLabel.TextSize = 13
	titleLabel.TextColor3 = LobbyLook.DIMTEXT
	titleLabel.Text = "—  NEXT WAVE FATE  —"
	titleLabel.ZIndex = 5
	titleLabel.Parent = band

	-- THE WINDOW: rows scroll inside, clipped top and bottom.
	windowFrame = Instance.new("Frame")
	windowFrame.Name = "Window"
	windowFrame.BackgroundTransparency = 1
	windowFrame.ClipsDescendants = true
	windowFrame.Position = UDim2.new(0, 0, 0, 34)
	windowFrame.Size = UDim2.new(1, 0, 0, WINDOW_H)
	windowFrame.ZIndex = 3
	windowFrame.Parent = band

	for _ = 1, WINDOW_ROWS + 2 do
		table.insert(slots, makeSlot(windowFrame))
	end

	-- CENTER RAILS: the "this row counts" cue — two dashes flanking the settle line.
	for side = 0, 1 do
		local rail = Instance.new("Frame")
		rail.Name = side == 0 and "RailL" or "RailR"
		rail.AnchorPoint = Vector2.new(side, 0.5)
		rail.Position = UDim2.new(side, side == 0 and 26 or -26, 0.5, 0)
		rail.Size = UDim2.fromOffset(26, 2)
		rail.BackgroundColor3 = LobbyLook.TEXTCOL
		rail.BackgroundTransparency = 1 -- fades in with the band
		rail.BorderSizePixel = 0
		rail.ZIndex = 6
		rail.Parent = windowFrame
	end

	-- Vertical fades so rows melt in/out at the window's clip edges instead of hard-cutting.
	for topSide = 0, 1 do
		local f = Instance.new("Frame")
		f.Name = topSide == 0 and "FadeTop" or "FadeBot"
		f.AnchorPoint = Vector2.new(0, topSide)
		f.Position = UDim2.new(0, 0, topSide, 0)
		f.Size = UDim2.new(1, 0, 0, math.floor(ROW_H * 0.7))
		f.BackgroundColor3 = BAND_DARK
		f.BackgroundTransparency = 1 -- driven with the band's fade-in (to 0-ish via gradient)
		f.BorderSizePixel = 0
		f.ZIndex = 5
		f.Parent = windowFrame
		local g = Instance.new("UIGradient")
		g.Rotation = topSide == 0 and 90 or -90
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
		fadeEnds(f)
	end

	-- Burst rays: thin spokes through the window's center, pre-built, fired on the lock.
	raysHolder = Instance.new("Frame")
	raysHolder.Name = "Rays"
	raysHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	raysHolder.Position = UDim2.new(0.5, 0, 0.5, 0)
	raysHolder.Size = UDim2.fromOffset(0, 0)
	raysHolder.BackgroundTransparency = 1
	raysHolder.ZIndex = 3
	raysHolder.Parent = windowFrame
	for i = 1, 14 do
		local r = Instance.new("Frame")
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.Size = UDim2.fromOffset(3, 0)
		r.Rotation = (i - 1) * (180 / 14) -- spokes THROUGH the center: 14 covers the full circle
		r.BackgroundTransparency = 1
		r.BorderSizePixel = 0
		r.ZIndex = 3
		r.Parent = raysHolder
		table.insert(rays, r)
	end
end

local TW = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function setStage(on: boolean)
	TweenService:Create(dimmer, TW, { BackgroundTransparency = on and DIM or 1 }):Play()
	local railT = on and 0.45 or 1
	for _, name in { "RailL", "RailR" } do
		local rail = windowFrame:FindFirstChild(name)
		if rail then
			TweenService:Create(rail, TW, { BackgroundTransparency = railT }):Play()
		end
	end
	for _, name in { "FadeTop", "FadeBot" } do
		local f = windowFrame:FindFirstChild(name)
		if f then
			TweenService:Create(f, TW, { BackgroundTransparency = on and 0.1 or 1 }):Play()
		end
	end
	if on then
		band.Visible = true
		band.BackgroundColor3 = BAND_DARK
		hairTop.BackgroundColor3 = HAIR_IDLE
		TweenService:Create(band, TW, { BackgroundTransparency = 0.06 }):Play()
		TweenService:Create(hairTop, TW, { BackgroundTransparency = 0.35 }):Play()
		titleLabel.TextTransparency = 0
	else
		TweenService:Create(band, TW, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(hairTop, TW, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(titleLabel, TW, { TextTransparency = 1 }):Play()
		-- THE BLACKED-TEXT FIX: fade each row's OUTLINE with its fill. Fading only the fill left the
		-- black stroke behind — the locked word turned into black letters floating over the world for
		-- the whole tuck-away (owner: "once the events are done the blacked text occurs").
		for _, s in slots do
			tweenRowFade(s, 1, TW)
			TweenService:Create(s.pc, TW, { TextTransparency = 1 }):Play()
		end
		for _, e in edges do -- edges only glow during the lock; always clear them on the way out
			TweenService:Create(e, TW, { BackgroundTransparency = 1 }):Play()
		end
		task.delay(0.32, function()
			band.Visible = false
			titleLabel.TextTransparency = 0
			for _, s in slots do
				s.nm.Text = ""
				s.pc.Text = ""
				setRowFade(s, 0) -- fill + outline both reset for the next roll
				s.pc.TextTransparency = 0
				s.scale.Scale = 1
				s.strip = nil
			end
		end)
	end
end

-- THE HAND-OFF: the winning word FLIES from the reel to the HUD's event badge and shrinks into it.
-- Purely a move — the text, face and colour are already identical at both ends (the reel row was
-- drawn in the event's colour, and the badge is the same type), so nothing morphs mid-flight. This is
-- what teaches players where to look for "what am I in?" for the rest of the wave.
--
-- The flier lives in its OWN ScreenGui with NO UIScale: the roller and HUD are both scaled, so working
-- in raw AbsolutePosition pixels is the only way the start and end points line up on every screen.
local FLY_TIME = 0.55
local function flyToBadge(centerSlot, outcome: string, odds)
	local badgeLabel, badgeSize = HUDController.GetEventChip()
	local look = LOOK[outcome]
	if not badgeLabel or not look or not centerSlot then
		HUDController.SetEventChip(outcome, typeof(odds) == "table" and tonumber(odds[outcome]) or nil)
		return -- no badge to fly to (or a calm wave): just set it
	end
	local nm = centerSlot.nm
	local fromPos = nm.AbsolutePosition
	local fromH = nm.AbsoluteSize.Y
	-- The reel's on-screen text size (its 40pt design size times whatever UIScale the HUD is running).
	local fromText = 40 * (fromH > 0 and (fromH / 42) or 1)
	local toPos = badgeLabel.AbsolutePosition
	local toH = badgeLabel.AbsoluteSize.Y
	local toText = badgeSize * (toH > 0 and (toH / 28) or 1)

	local gui = Instance.new("ScreenGui")
	gui.Name = "EventHandoff"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60 -- over everything for the half-second it exists
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	local flier = Instance.new("TextLabel")
	flier.BackgroundTransparency = 1
	flier.Position = UDim2.fromOffset(fromPos.X, fromPos.Y)
	flier.Size = UDim2.fromOffset(nm.AbsoluteSize.X, fromH)
	flier.FontFace = LobbyLook.TITLE_FACE
	flier.TextSize = fromText
	flier.TextColor3 = look.color
	flier.Text = look.name
	flier.Parent = gui
	local fs = Instance.new("UIStroke")
	fs.Color = Color3.fromRGB(0, 0, 0)
	fs.Transparency = 0.15
	fs.Thickness = 2.6
	fs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	fs.Parent = flier

	-- Hide the reel's copy the instant the flier exists, so there's never two of the same word.
	nm.TextTransparency = 1
	centerSlot.stroke.Transparency = 1
	centerSlot.pc.TextTransparency = 1

	local info = TweenInfo.new(FLY_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)
	TweenService:Create(flier, info, {
		Position = UDim2.fromOffset(toPos.X, toPos.Y),
		Size = UDim2.fromOffset(badgeLabel.AbsoluteSize.X, toH),
		TextSize = toText,
	}):Play()

	task.delay(FLY_TIME, function()
		-- Land: the real badge takes over on the same pixel the flier stopped on.
		HUDController.SetEventChip(outcome, typeof(odds) == "table" and tonumber(odds[outcome]) or nil)
		gui:Destroy()
	end)
end

-- THE LOCK FLOOD: color everything, punch the centered row, fire the rays.
local function lockIn(centerSlot, outcome: string, odds)
	local look = LOOK[outcome] or LOOK.calm
	local pct = typeof(odds) == "table" and tonumber(odds[outcome]) or 100
	local drama = dramaFor(pct)

	centerSlot.nm.Text = look.name
	centerSlot.nm.TextColor3 = look.color
	setRowFade(centerSlot, 0) -- fill AND outline fully solid on the winner
	centerSlot.pc.Text = fmtPct(pct)
	centerSlot.pc.TextColor3 = look.color
	centerSlot.pc.TextTransparency = 0

	-- Neighbors snuff out so the winner owns the window (outline fades with them — see setRowFade).
	for _, s in slots do
		if s ~= centerSlot then
			tweenRowFade(s, 1, TW)
			TweenService:Create(s.pc, TW, { TextTransparency = 1 }):Play()
		end
	end
	-- Band + hairline flood the event color (kept dark enough for the word to pop).
	TweenService:Create(band, TW, { BackgroundColor3 = BAND_DARK:Lerp(look.color, 0.22) }):Play()
	TweenService:Create(hairTop, TW, { BackgroundColor3 = look.color }):Play()
	-- Screen edges glow the color for the hold — but ONLY as loud as the odds deserve.
	if drama.edge < 1 then
		for _, e in edges do
			e.BackgroundColor3 = look.color
			TweenService:Create(e, TW, { BackgroundTransparency = drama.edge }):Play()
		end
	end
	-- The punch (scaled by how rare the landing is) — blooms about the row's center.
	centerSlot.scale.Scale = 0.78
	TweenService:Create(centerSlot.scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = drama.punch }):Play()
	-- Burst rays: expanding, fading spokes behind the word.
	for i, r in rays do
		local active = i <= drama.rays
		r.BackgroundColor3 = look.color
		r.BackgroundTransparency = active and 0.15 or 1
		r.Size = UDim2.fromOffset(3, 12)
		if active then
			TweenService:Create(r, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(3, 300),
				BackgroundTransparency = 1,
			}):Play()
		end
	end
	return drama
end

local function runRoll(info)
	if typeof(info) ~= "table" then
		return
	end
	-- STAGE 2: the locked outcome lands mid-roll — hand it to the running reel and bail.
	if info.lock ~= nil then
		pendingLockId = tostring(info.lock)
		if applyLock then
			applyLock(pendingLockId)
		end
		return
	end

	local secs = math.max(1, tonumber(info.seconds) or 3)
	local odds = typeof(info.odds) == "table" and info.odds or nil
	-- Legacy single-message shape (outcome at spin start) still locks correctly.
	pendingLockId = typeof(info.outcome) == "string" and info.outcome or nil

	-- Only events actually IN this wave's odds table ride the reel — no impossible teases.
	local pool = {}
	if odds then
		for id in odds do
			if LOOK[id] then
				table.insert(pool, id)
			end
		end
	end
	if #pool == 0 then
		pool = IDS
	end
	table.sort(pool)

	spinToken += 1
	local myTok = spinToken
	gui.Enabled = true
	setStage(true)
	-- The HUD's "NEXT WAVE IN n" countdown yields while the roller is up (they'd overlap).
	localPlayer:SetAttribute("EventRollerUp", true)

	-- The spin SOUND: the clip is ~1.5s, the roll is ~3s — re-play it back-to-back across the window.
	task.spawn(function()
		local SPIN_CLIP = 1.5
		local t = 0
		while myTok == spinToken and t < secs - 0.4 do
			SoundController.Play("WheelSpin")
			task.wait(SPIN_CLIP)
			t += SPIN_CLIP
		end
	end)

	task.spawn(function()
		-- ===== THE REEL ===== a virtual strip of names scrolls through the window, decelerating to
		-- land its FINAL index dead center. Names are lazily assigned per strip index; the final
		-- index takes the locked outcome the moment stage 2 delivers it.
		local steps = math.max(10, math.floor(secs * STEPS_PER_SEC + 0.5)) -- total rows scrolled past
		local names = {} -- stripIndex -> event id
		-- The final row can enter the window a beat BEFORE the stage-2 lock lands (it gets dealt a
		-- placeholder while still at the clipped, fast-moving bottom edge). This retro-fix swaps in
		-- the real outcome the instant the lock arrives, well before the row settles center.
		applyLock = function(id: string)
			if not LOOK[id] then
				return
			end
			names[steps] = id
			for _, s in slots do
				if s.strip == steps then
					s.strip = nil -- forces the next paint to re-deal this slot's text
				end
			end
		end
		local function nameAt(k: number): string
			if not names[k] then
				if k == steps and pendingLockId and LOOK[pendingLockId] then
					names[k] = pendingLockId
				else
					local id = pool[math.random(1, #pool)]
					if id == names[k - 1] and #pool > 1 then
						id = pool[(table.find(pool, id) % #pool) + 1]
					end
					names[k] = id
				end
			end
			return names[k]
		end

		local centerY = WINDOW_H / 2
		local function paint(centerFloat: number)
			-- Frames pin to strip indices near the view; recycling = same frame, new index, new text.
			local base = math.floor(centerFloat + 0.5)
			for d = -2, 2 do
				local k = base + d
				local slot = slots[(k % #slots) + 1]
				if slot.strip ~= k then
					slot.strip = k
					local id = nameAt(k)
					local look = LOOK[id] or LOOK.calm
					slot.nm.Text = look.name
					slot.color = look.color -- CHANGED: every row wears its OWN event colour
					slot.pc.Text = fmtPct(odds and tonumber(odds[id]) or nil)
				end
				local dist = math.abs(k - centerFloat)
				local centered = dist < 0.5
				-- EVERY ROW IS ITS EVENT'S COLOUR (owner call): BLOOD MOON scrolls past red, ACID RAIN
				-- green, GOD MODE cyan. The centred row burns at full colour and the neighbours are the
				-- SAME hue pushed toward the band's dark, so they read as "the same list, further away"
				-- instead of grey mystery text. It also means the lock changes nothing about the colour —
				-- the winner was already red, so the hand-off to the HUD badge is red-to-red.
				local col = slot.color or LobbyLook.TEXTCOL
				slot.nm.TextColor3 = centered and col or col:Lerp(BAND_DARK, 0.42)
				setRowFade(slot, centered and 0.05 or math.min(0.5, 0.18 + dist * 0.14))
				slot.pc.TextColor3 = centered and LobbyLook.DIMTEXT or PCT_DIM
				slot.pc.TextTransparency = centered and 0.1 or math.min(0.6, 0.28 + dist * 0.14)
				slot.frame.Position = UDim2.new(0.5, 0, 0, math.floor(centerY + (k - centerFloat) * ROW_H + 0.5))
			end
		end

		paint(0)
		local t0 = os.clock()
		local done = false
		local conn
		conn = RunService.RenderStepped:Connect(function()
			if myTok ~= spinToken then
				conn:Disconnect()
				return
			end
			local a = math.clamp((os.clock() - t0) / secs, 0, 1)
			local eased = 1 - (1 - a) ^ EASE_POW -- slot-machine deceleration
			-- STALL GUARD: if the lock is late, hover one row short at the terminal crawl instead of
			-- settling on a random word (the last row only commits once the outcome is known).
			local target = steps * eased
			if not pendingLockId and target > steps - 1 then
				target = steps - 1 + (target - (steps - 1)) * 0.15
			end
			paint(target)
			if a >= 1 and pendingLockId then
				done = true
				conn:Disconnect()
			end
		end)

		-- Wait for the scroll to finish (plus a lock-timeout safety if the remote never lands).
		local deadline = os.clock() + secs + 3
		while myTok == spinToken and not done and os.clock() < deadline do
			task.wait(0.05)
		end
		if myTok ~= spinToken then
			return
		end
		if conn.Connected then
			conn:Disconnect()
		end
		local outcome = pendingLockId
		if not outcome or not LOOK[outcome] then
			-- The lock never arrived (dropped remote / run ended): tuck away without a false reveal.
			setStage(false)
			task.delay(0.3, function()
				if myTok == spinToken then
					gui.Enabled = false
				end
			end)
			localPlayer:SetAttribute("EventRollerUp", false)
			return
		end
		names[steps] = outcome
		paint(steps) -- settle EXACTLY centered, final row = the outcome
		local centerSlot = slots[(steps % #slots) + 1]
		SoundController.Play("WheelLock")
		local drama = lockIn(centerSlot, outcome, odds)
		task.delay(drama.hold, function()
			if myTok == spinToken then
				flyToBadge(centerSlot, outcome, odds) -- the word travels to the HUD badge
				setStage(false)
				task.delay(0.3, function()
					if myTok == spinToken then
						gui.Enabled = false
					end
				end)
				localPlayer:SetAttribute("EventRollerUp", false)
			end
		end)
	end)
end

function EventWheelController.Start()
	build()
	Remotes.Get("EventSpin").OnClientEvent:Connect(runRoll)
	print("[EventWheelController] started (REEL v2 armed)")
end

return EventWheelController
