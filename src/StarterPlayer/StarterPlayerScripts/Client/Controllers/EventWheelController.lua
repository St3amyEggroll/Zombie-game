--!nonstrict
-- EventWheelController.lua — THE EVENT ROLLER (owner call: WORDS, not icons — no scrolling wheel).
-- Every wave break the server rolls next wave's modifier and broadcasts EventSpin {wave, outcome,
-- seconds, odds}. We run a text ROLL in one top-center slot: event names FLASH one after another —
-- blink out, blink in — fast at first, losing steam like a thrown die, until the real outcome LOCKS
-- big and colored. Every flash carries that event's live % chance, so a rare landing FEELS rare.
-- Pure theater: the server already decided the outcome.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)
local LobbyLook = require(Shared.Modules.LobbyLook)

local SoundController = require(script.Parent.SoundController) -- WheelSpin during the roll, WheelLock on the land

local EventWheelController = {}

-- ===== TUNABLES =====
local BANNER_W = 300
local FIRST_STEP = 0.10    -- seconds the FIRST flash lasts...
local STEP_GROWTH = 1.32   -- ...each flash lasting this much longer than the last (the die losing steam)
local GAP_FRAC = 0.35      -- slice of each step spent BLANK (the blink-out between words)
local HOLD_SECONDS = 2.6   -- how long the locked result stays up
local LOCK_PUNCH = 1.22    -- the locked word's pop scale

-- What each outcome reads as (server sends only the id). Events have RARITIES like crates — the
-- rarity name+color rides the odds line so a MYTHIC landing feels like a crate pull. Keep rarities
-- in sync with EventService.OUTCOMES BY HAND. Add a wheel outcome = add a row.
local RARITY = {
	common    = { name = "COMMON",    color = Color3.fromRGB(185, 185, 185) },
	uncommon  = { name = "UNCOMMON",  color = Color3.fromRGB(95, 205, 95) },
	rare      = { name = "RARE",      color = Color3.fromRGB(80, 145, 255) },
	epic      = { name = "EPIC",      color = Color3.fromRGB(175, 95, 235) },
	legendary = { name = "LEGENDARY", color = Color3.fromRGB(255, 170, 60) },
	mythic    = { name = "MYTHIC",    color = Color3.fromRGB(255, 80, 120) },
	divine    = { name = "DIVINE",    color = Color3.fromRGB(120, 255, 235) },
}
local LOOK = {
	calm       = { name = "CALM WAVE",       color = Color3.fromRGB(124, 219, 35),  rarity = "common" },
	fog        = { name = "FOG",             color = Color3.fromRGB(180, 186, 168), rarity = "common" },
	meteors    = { name = "METEOR SHOWER",   color = Color3.fromRGB(255, 140, 40),  rarity = "uncommon" },
	bombsquad  = { name = "BOMB SQUAD",      color = Color3.fromRGB(255, 96, 34),   rarity = "uncommon" },
	earthquake = { name = "EARTHQUAKE",      color = Color3.fromRGB(168, 140, 110), rarity = "uncommon" },
	bloodmoon  = { name = "BLOOD MOON",      color = Color3.fromRGB(255, 70, 50),   rarity = "rare" },
	lightning  = { name = "LIGHTNING STORM", color = Color3.fromRGB(120, 200, 255), rarity = "rare" },
	acidrain   = { name = "ACID RAIN",       color = Color3.fromRGB(120, 230, 60),  rarity = "rare" },
	hounds     = { name = "BLOODHOUNDS",     color = Color3.fromRGB(200, 120, 60),  rarity = "rare" },
	purge      = { name = "THE PURGE",       color = Color3.fromRGB(220, 60, 60),   rarity = "epic" },
	bodyguards = { name = "BODYGUARDS",      color = Color3.fromRGB(240, 196, 82),  rarity = "epic" },
	goldrush   = { name = "GOLD RUSH",       color = Color3.fromRGB(255, 215, 70),  rarity = "legendary" },
	apocalypse = { name = "APOCALYPSE",      color = Color3.fromRGB(255, 60, 90),   rarity = "mythic" },
	godmode    = { name = "GOD MODE",        color = Color3.fromRGB(120, 255, 235), rarity = "divine" },
}
local IDS = {}
for id in LOOK do
	table.insert(IDS, id)
end
table.sort(IDS)

local localPlayer = Players.LocalPlayer

local gui, banner, titleLabel, wordLabel, oddsLabel, wordScale
local spinToken = 0

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "EventRoller"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = (UITheme.Layer and UITheme.Layer.HUD or 4) + 1
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui, nil, nil, "hud")

	banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	-- Below the wave strip; on touch the whole top lane sits lower (see HUDController's lane note).
	banner.Position = UDim2.new(0.5, 0, 0, UserInputService.TouchEnabled and 168 or 64)
	banner.Size = UDim2.fromOffset(BANNER_W, 92)
	banner.BackgroundTransparency = 1
	banner.Parent = gui

	titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.fromOffset(0, 0)
	titleLabel.Size = UDim2.new(1, 0, 0, 18)
	titleLabel.FontFace = LobbyLook.BODYB_FACE
	titleLabel.TextSize = 13
	titleLabel.TextColor3 = LobbyLook.DIMTEXT
	titleLabel.Text = "NEXT WAVE"
	titleLabel.Parent = banner
	local tStroke = Instance.new("UIStroke")
	tStroke.Color = Color3.fromRGB(0, 0, 0)
	tStroke.Transparency = 0.4
	tStroke.Thickness = 1.2
	tStroke.Parent = titleLabel

	wordLabel = Instance.new("TextLabel") -- THE slot: one event name at a time
	wordLabel.BackgroundTransparency = 1
	wordLabel.Position = UDim2.fromOffset(0, 20)
	wordLabel.Size = UDim2.new(1, 0, 0, 40)
	wordLabel.FontFace = LobbyLook.TITLE_FACE
	wordLabel.TextSize = 34
	wordLabel.TextColor3 = LobbyLook.TEXTCOL
	wordLabel.Text = ""
	wordLabel.Parent = banner
	local wStroke = Instance.new("UIStroke")
	wStroke.Color = Color3.fromRGB(0, 0, 0)
	wStroke.Transparency = 0.2
	wStroke.Thickness = 2.4
	wStroke.Parent = wordLabel
	wordScale = Instance.new("UIScale")
	wordScale.Parent = wordLabel

	oddsLabel = Instance.new("TextLabel") -- the % line riding under every flashed word
	oddsLabel.BackgroundTransparency = 1
	oddsLabel.Position = UDim2.fromOffset(0, 62)
	oddsLabel.Size = UDim2.new(1, 0, 0, 20)
	oddsLabel.FontFace = LobbyLook.BODYB_FACE
	oddsLabel.TextSize = 15
	oddsLabel.TextColor3 = LobbyLook.DIMTEXT
	oddsLabel.Text = ""
	oddsLabel.Parent = banner
	local oStroke = Instance.new("UIStroke")
	oStroke.Color = Color3.fromRGB(0, 0, 0)
	oStroke.Transparency = 0.35
	oStroke.Thickness = 1.5
	oStroke.Parent = oddsLabel
end

-- Show one flashed word (+ its rarity and live %). The word arrives slightly dimmed mid-roll; the
-- LOCK pass paints it full-strength, tints the rarity line, and punches the scale.
local function showWord(id: string, odds, locked: boolean)
	local look = LOOK[id] or LOOK.calm
	local rar = RARITY[look.rarity] or RARITY.common
	wordLabel.Text = look.name
	wordLabel.TextColor3 = look.color
	wordLabel.TextTransparency = locked and 0 or 0.12
	local pct = typeof(odds) == "table" and tonumber(odds[id]) or nil
	oddsLabel.Text = pct and ("%s · %d%% CHANCE"):format(rar.name, pct) or rar.name
	oddsLabel.TextColor3 = locked and rar.color or LobbyLook.DIMTEXT
	if locked then
		wordScale.Scale = 1
		TweenService:Create(wordScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = LOCK_PUNCH }):Play()
	end
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
	-- The HUD's "NEXT WAVE IN n" countdown yields while the roller is up (they share the top-center
	-- lane — both showing at once printed the garbled "NE:NEXT WAVEN 5" overlap).
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
		-- Build the step ladder: flashes speed-decay until they've spent the spin window. The LAST
		-- step is the real outcome; every earlier flash shows a DIFFERENT name than the one before it
		-- (a roll never stutters on one word).
		local steps = {}
		local t, dur = 0, FIRST_STEP
		while t + dur < secs - 0.35 do -- leave a beat so the lock lands inside the window
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
			if id == prev then -- never flash the same word twice in a row
				id = IDS[(table.find(IDS, id) % #IDS) + 1]
			end
			prev = id
			showWord(id, odds, false)
			task.wait(stepDur * (1 - GAP_FRAC))
			if myTok ~= spinToken then
				return
			end
			wordLabel.Text = "" -- the blink-out (the word "goes away and comes back")
			oddsLabel.Text = ""
			task.wait(stepDur * GAP_FRAC)
		end
		if myTok ~= spinToken then
			return
		end
		-- THE LOCK: the real outcome, full color, punched scale, % underneath.
		SoundController.Play("WheelLock")
		showWord(outcome, odds, true)
		task.delay(HOLD_SECONDS, function()
			if myTok == spinToken then
				gui.Enabled = false
				localPlayer:SetAttribute("EventRollerUp", false)
			end
		end)
	end)
end

function EventWheelController.Start()
	build()
	Remotes.Get("EventSpin").OnClientEvent:Connect(runRoll)
	print("[EventWheelController] started (the roller is watching)")
end

return EventWheelController
