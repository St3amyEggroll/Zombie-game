--!nonstrict
-- EventWheelController.lua — THE EVENT ROLLER, cinematic pass (owner-approved mock). Every wave break
-- the server broadcasts EventSpin {wave, outcome, seconds, odds}; this runs the show:
--   1. THE DIM — gameplay fades back ~50% under a vignette; the roll owns the screen.
--   2. THE BAND — a cinematic strip snaps open across the upper third (dark center, edges fading to
--      nothing, hairline rules top + bottom). The words flash inside it — blink out, blink in,
--      slowing like a thrown die — each stamped with its live % chance (one decimal, no rarity).
--   3. THE LOCK FLOOD — the real outcome slams in: band + hairlines flood the event's color, the word
--      punches (bigger for rarer odds), burst rays fire behind it, the SCREEN EDGES glow the color
--      for the whole hold. Then everything tucks away and the wave starts.
-- Pure theater: the server already decided the outcome. Sounds: WheelSpin loops the flash, WheelLock
-- lands with the flood.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)
local LobbyLook = require(Shared.Modules.LobbyLook)

local SoundController = require(script.Parent.SoundController) -- WheelSpin during the roll, WheelLock on the land

local EventWheelController = {}

-- ===== TUNABLES =====
local FIRST_STEP = 0.10    -- seconds the FIRST flash lasts...
local STEP_GROWTH = 1.32   -- ...each flash lasting this much longer (the die losing steam)
local GAP_FRAC = 0.35      -- slice of each step spent BLANK (the blink-out between words)
local BAND_Y = 0.16        -- band top, fraction of the screen (owner: moved up, just under the wave strip)
local BAND_H = 132         -- band height (px, hud-scaled)
local DIM = 0.52           -- how dark the dimmer gets (0 = none, 1 = black)
local EDGE_GLOW = 0.55     -- edge glow transparency at full flood (lower = louder)
-- Spectacle scales with the ODDS — the rarer the landing, the harder it hits.
local function dramaFor(pct: number)
	if pct <= 1.5 then
		return { punch = 1.38, hold = 3.4, rays = 14 } -- the 1%ers: full fireworks
	elseif pct <= 4 then
		return { punch = 1.26, hold = 2.9, rays = 12 }
	elseif pct <= 8 then
		return { punch = 1.18, hold = 2.5, rays = 10 }
	end
	return { punch = 1.12, hold = 2.2, rays = 8 }
end

-- What each outcome reads as (server sends only the id + odds). Add a wheel outcome = add a row.
local LOOK = {
	calm       = { name = "CALM WAVE",       color = Color3.fromRGB(124, 219, 35) },
	fog        = { name = "FOG",             color = Color3.fromRGB(180, 186, 168) },
	rain       = { name = "RAIN",            color = Color3.fromRGB(165, 195, 225) },
	meteors    = { name = "METEOR SHOWER",   color = Color3.fromRGB(255, 140, 40) },
	bombsquad  = { name = "BOMB SQUAD",      color = Color3.fromRGB(255, 96, 34) },
	earthquake = { name = "EARTHQUAKE",      color = Color3.fromRGB(190, 160, 120) },
	bloodmoon  = { name = "BLOOD MOON",      color = Color3.fromRGB(255, 70, 50) },
	lightning  = { name = "LIGHTNING STORM", color = Color3.fromRGB(120, 200, 255) },
	acidrain   = { name = "ACID RAIN",       color = Color3.fromRGB(120, 230, 60) },
	hounds     = { name = "BLOODHOUNDS",     color = Color3.fromRGB(200, 120, 60) },
	purge      = { name = "THE PURGE",       color = Color3.fromRGB(220, 60, 60) },
	bodyguards = { name = "BODYGUARDS",      color = Color3.fromRGB(240, 196, 82) },
	goldrush   = { name = "GOLD RUSH",       color = Color3.fromRGB(255, 215, 70) },
	apocalypse = { name = "APOCALYPSE",      color = Color3.fromRGB(255, 60, 90) },
	godmode    = { name = "GOD MODE",        color = Color3.fromRGB(120, 255, 235) },
}
local IDS = {}
for id in LOOK do
	table.insert(IDS, id)
end
table.sort(IDS)

local BAND_DARK = Color3.fromRGB(5, 7, 4)
local HAIR_IDLE = Color3.fromRGB(90, 97, 72)

local localPlayer = Players.LocalPlayer

local gui, dimmer, band, hairTop, hairBot, titleLabel, wordLabel, oddsLabel, wordScale, raysHolder
local edges = {} -- the 4 screen-edge glow frames
local rays = {}  -- pre-built burst spokes behind the word
local spinToken = 0

-- A full-width frame whose UIGradient fades both ends to nothing (the band + hairline treatment).
local function fadeEnds(frame: Frame, hard: number?)
	local g = Instance.new("UIGradient")
	local solid = hard or 0.06
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.16, solid),
		NumberSequenceKeypoint.new(0.5, solid),
		NumberSequenceKeypoint.new(0.84, solid),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = frame
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "EventRoller"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = (UITheme.Layer and UITheme.Layer.HUD or 4) + 1
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
	edge("EdgeTop",    Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), UDim2.fromScale(1, 0.16), 90)
	edge("EdgeBottom", Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), UDim2.fromScale(1, 0.16), -90)
	edge("EdgeLeft",   Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), UDim2.fromScale(0.1, 1), 0)
	edge("EdgeRight",  Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), UDim2.fromScale(0.1, 1), 180)

	-- 2) THE BAND: snaps open across the upper third; everything lives inside it.
	band = Instance.new("Frame")
	band.Name = "Band"
	band.AnchorPoint = Vector2.new(0.5, 0.5)
	band.Position = UDim2.new(0.5, 0, BAND_Y, BAND_H / 2)
	band.Size = UDim2.new(1, 0, 0, BAND_H)
	band.BackgroundColor3 = BAND_DARK
	band.BackgroundTransparency = 0.06
	band.BorderSizePixel = 0
	band.ZIndex = 3
	band.Parent = gui
	fadeEnds(band)
	local bandScale = Instance.new("UIScale")
	bandScale.Name = "OpenScale"
	bandScale.Parent = band

	local function hair(name, yScale)
		local h = Instance.new("Frame")
		h.Name = name
		h.AnchorPoint = Vector2.new(0.5, 0.5)
		h.Position = UDim2.new(0.5, 0, yScale, 0)
		h.Size = UDim2.new(0.86, 0, 0, 2)
		h.BackgroundColor3 = HAIR_IDLE
		h.BorderSizePixel = 0
		h.ZIndex = 4
		h.Parent = band
		fadeEnds(h, 0.25)
		return h
	end
	hairTop = hair("HairTop", 0)
	hairBot = hair("HairBot", 1)

	titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.new(0, 0, 0, 12)
	titleLabel.Size = UDim2.new(1, 0, 0, 16)
	titleLabel.FontFace = LobbyLook.BODYB_FACE
	titleLabel.TextSize = 13
	titleLabel.TextColor3 = LobbyLook.DIMTEXT
	titleLabel.Text = "—  NEXT WAVE  —"
	titleLabel.ZIndex = 5
	titleLabel.Parent = band

	wordLabel = Instance.new("TextLabel") -- THE slot: one event name at a time
	wordLabel.BackgroundTransparency = 1
	-- Center-anchored so the lock pop's UIScale blooms in place (top-left anchoring shoved it sideways).
	wordLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	wordLabel.Position = UDim2.new(0.5, 0, 0.5, 4)
	wordLabel.Size = UDim2.new(1, 0, 0, 46)
	wordLabel.FontFace = LobbyLook.TITLE_FACE
	wordLabel.TextSize = 40
	wordLabel.TextColor3 = LobbyLook.TEXTCOL
	wordLabel.Text = ""
	wordLabel.ZIndex = 6
	wordLabel.Parent = band
	local wStroke = Instance.new("UIStroke")
	wStroke.Color = Color3.fromRGB(0, 0, 0)
	wStroke.Transparency = 0.2
	wStroke.Thickness = 2.6
	wStroke.Parent = wordLabel
	wordScale = Instance.new("UIScale")
	wordScale.Parent = wordLabel

	-- Burst rays: thin spokes through the word's center, pre-built, fired on the lock.
	raysHolder = Instance.new("Frame")
	raysHolder.Name = "Rays"
	raysHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	raysHolder.Position = UDim2.new(0.5, 0, 0.5, 4)
	raysHolder.Size = UDim2.fromOffset(0, 0)
	raysHolder.BackgroundTransparency = 1
	raysHolder.ZIndex = 5
	raysHolder.Parent = band
	for i = 1, 14 do
		local r = Instance.new("Frame")
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.Size = UDim2.fromOffset(3, 0)
		r.Rotation = (i - 1) * (180 / 14) -- spokes THROUGH the center: 14 covers the full circle
		r.BackgroundTransparency = 1
		r.BorderSizePixel = 0
		r.ZIndex = 5
		r.Parent = raysHolder
		table.insert(rays, r)
	end

	oddsLabel = Instance.new("TextLabel") -- the live % line riding under every flashed word
	oddsLabel.AnchorPoint = Vector2.new(0.5, 1)
	oddsLabel.Position = UDim2.new(0.5, 0, 1, -12)
	oddsLabel.Size = UDim2.new(1, 0, 0, 18)
	oddsLabel.FontFace = LobbyLook.BODYB_FACE
	oddsLabel.TextSize = 15
	oddsLabel.TextColor3 = LobbyLook.DIMTEXT
	oddsLabel.Text = ""
	oddsLabel.ZIndex = 6
	oddsLabel.Parent = band
	local oStroke = Instance.new("UIStroke")
	oStroke.Color = Color3.fromRGB(0, 0, 0)
	oStroke.Transparency = 0.35
	oStroke.Thickness = 1.5
	oStroke.Parent = oddsLabel
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

-- One flashed word (+ its live %). Mid-roll words sit dimmed white; the LOCK pass floods everything.
local function showWord(id: string, odds)
	local look = LOOK[id] or LOOK.calm
	wordLabel.Text = look.name
	wordLabel.TextColor3 = LobbyLook.TEXTCOL
	wordLabel.TextTransparency = 0.1
	oddsLabel.Text = fmtPct(typeof(odds) == "table" and tonumber(odds[id]) or nil)
	oddsLabel.TextColor3 = LobbyLook.DIMTEXT
end

local TW = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function setStage(on: boolean)
	-- The dim + the band's shutter-open. Off = everything tucks away together.
	TweenService:Create(dimmer, TW, { BackgroundTransparency = on and DIM or 1 }):Play()
	local sc = band:FindFirstChild("OpenScale")
	if on then
		band.Visible = true
		if sc then
			sc.Scale = 0.6
			TweenService:Create(sc, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }):Play()
		end
	else
		if sc then
			TweenService:Create(sc, TW, { Scale = 0.6 }):Play()
		end
		task.delay(0.28, function()
			band.Visible = false
		end)
	end
	if not on then -- edges only glow during the lock; always clear them on the way out
		for _, e in edges do
			TweenService:Create(e, TW, { BackgroundTransparency = 1 }):Play()
		end
		TweenService:Create(band, TW, { BackgroundColor3 = BAND_DARK }):Play()
		hairTop.BackgroundColor3 = HAIR_IDLE
		hairBot.BackgroundColor3 = HAIR_IDLE
	end
end

-- THE LOCK FLOOD: color everything, punch the word, fire the rays.
local function lockIn(outcome: string, odds)
	local look = LOOK[outcome] or LOOK.calm
	local pct = typeof(odds) == "table" and tonumber(odds[outcome]) or 100
	local drama = dramaFor(pct)

	wordLabel.Text = look.name
	wordLabel.TextColor3 = look.color
	wordLabel.TextTransparency = 0
	oddsLabel.Text = fmtPct(pct)
	oddsLabel.TextColor3 = look.color

	-- Band + hairlines flood the event color (kept dark enough for the white-less word to pop).
	TweenService:Create(band, TW, { BackgroundColor3 = BAND_DARK:Lerp(look.color, 0.22) }):Play()
	for _, h in { hairTop, hairBot } do
		TweenService:Create(h, TW, { BackgroundColor3 = look.color }):Play()
	end
	-- Screen edges glow the color for the whole hold.
	for _, e in edges do
		e.BackgroundColor3 = look.color
		TweenService:Create(e, TW, { BackgroundTransparency = EDGE_GLOW }):Play()
	end
	-- The punch (scaled by how rare the landing is).
	wordScale.Scale = 0.72
	TweenService:Create(wordScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = drama.punch }):Play()
	-- Burst rays: expanding, fading spokes through the word.
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
	local outcome = typeof(info) == "table" and tostring(info.outcome) or "calm"
	if not LOOK[outcome] then
		outcome = "calm"
	end
	local secs = math.max(1, tonumber(info.seconds) or 3)
	local odds = typeof(info) == "table" and info.odds or nil

	spinToken += 1
	local myTok = spinToken
	wordScale.Scale = 1
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
		-- The step ladder: flashes speed-decay until they've spent the spin window; the LAST step is
		-- the real outcome. No word ever repeats back-to-back (a roll never stutters).
		local steps = {}
		local t, dur = 0, FIRST_STEP
		while t + dur < secs - 0.35 do
			table.insert(steps, dur)
			t += dur
			dur *= STEP_GROWTH
		end
		local prev = nil
		for _, stepDur in steps do
			if myTok ~= spinToken then
				return
			end
			local id = IDS[math.random(1, #IDS)]
			if id == prev then
				id = IDS[(table.find(IDS, id) % #IDS) + 1]
			end
			prev = id
			showWord(id, odds)
			task.wait(stepDur * (1 - GAP_FRAC))
			if myTok ~= spinToken then
				return
			end
			wordLabel.Text = "" -- the blink-out (the word goes away and comes back)
			oddsLabel.Text = ""
			task.wait(stepDur * GAP_FRAC)
		end
		if myTok ~= spinToken then
			return
		end
		SoundController.Play("WheelLock")
		local drama = lockIn(outcome, odds)
		task.delay(drama.hold, function()
			if myTok == spinToken then
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
	print("[EventWheelController] started (cinematic roller armed)")
end

return EventWheelController
