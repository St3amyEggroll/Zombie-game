--!nonstrict
-- SettingsController.lua — the ⚙ gear (bottom-right) opens a small themed panel with three volume
-- sliders: MASTER / MUSIC / SFX. Values apply live through SoundController and persist through the
-- SetSoundSettings remote (saved into the profile's settings.vol by SoundFXService + DataService).
-- Sliders work with mouse AND touch (press anywhere on the track, drag, release).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Modules.UITheme)
local Remotes = require(Shared.Modules.Remotes)

local SoundController = require(script.Parent.SoundController)

local SettingsController = {}

-- ===== TUNABLES =====
local PANEL_W, PANEL_H = 340, 250
local SAVE_DEBOUNCE = 0.6 -- seconds after the last slider move before the save fires

local localPlayer = Players.LocalPlayer

local saveAt = 0
local function queueSave()
	saveAt = os.clock() + SAVE_DEBOUNCE
	task.delay(SAVE_DEBOUNCE + 0.05, function()
		if os.clock() >= saveAt then
			local m, mu, s = SoundController.GetVolumes()
			Remotes.Get("SetSoundSettings"):FireServer({ master = m, music = mu, sfx = s })
		end
	end)
end

function SettingsController.Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Settings"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 30
	gui.Parent = playerGui
	UITheme.Attach(gui)

	-- Gear button, bottom-right corner.
	local gear = Instance.new("TextButton")
	gear.AnchorPoint = Vector2.new(1, 1)
	gear.Position = UDim2.new(1, -12, 1, -12)
	gear.Size = UDim2.fromOffset(44, 44)
	gear.BackgroundColor3 = UITheme.PANEL
	gear.BorderSizePixel = 0
	gear.FontFace = UITheme.BodyBoldFace
	gear.TextSize = 22
	gear.TextColor3 = UITheme.DIM
	gear.Text = "⚙"
	gear.Parent = gui
	UITheme.Corner(gear, 8)
	UITheme.Edge(gear)
	UITheme.Studs(gear)

	-- Panel.
	local panel = UITheme.Panel(gui, "SettingsPanel", { accent = UITheme.TOXIC })
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -12, 1, -64)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.Visible = false
	UITheme.Header(panel, "SETTINGS", 40)

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -6, 0, 2)
	closeBtn.Size = UDim2.fromOffset(38, 38)
	closeBtn.BackgroundTransparency = 1
	closeBtn.FontFace = UITheme.TitleFace
	closeBtn.TextSize = 26
	closeBtn.TextColor3 = Color3.fromRGB(235, 55, 45)
	closeBtn.Text = "✕"
	closeBtn.Parent = panel
	local xs = Instance.new("UIStroke")
	xs.Color = UITheme.BLACK
	xs.Thickness = 1.4
	xs.Parent = closeBtn

	-- One slider row: label + % readout + a draggable track.
	local function sliderRow(y, labelText, getValue, setValue)
		local label = UITheme.Label(panel, nil, 14, UITheme.DIM, true)
		label.Position = UDim2.fromOffset(18, y)
		label.Size = UDim2.fromOffset(120, 18)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = labelText

		local pct = UITheme.Label(panel, nil, 14, UITheme.TEXT, true)
		pct.AnchorPoint = Vector2.new(1, 0)
		pct.Position = UDim2.new(1, -18, 0, y)
		pct.Size = UDim2.fromOffset(60, 18)
		pct.TextXAlignment = Enum.TextXAlignment.Right

		local track = Instance.new("TextButton") -- button = easy press capture on mouse + touch
		track.Position = UDim2.fromOffset(18, y + 24)
		track.Size = UDim2.new(1, -36, 0, 14)
		track.BackgroundColor3 = UITheme.TRACK
		track.BorderSizePixel = 0
		track.Text = ""
		track.AutoButtonColor = false
		track:SetAttribute("NoClickSound", true)
		track.Parent = panel
		UITheme.Corner(track, 7)
		UITheme.Edge(track, UITheme.BLACK, 1.5)

		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = UITheme.TOXIC
		fill.BorderSizePixel = 0
		fill.Parent = track
		UITheme.Corner(fill, 7)

		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Size = UDim2.fromOffset(20, 20)
		knob.BackgroundColor3 = UITheme.TEXT
		knob.BorderSizePixel = 0
		knob.ZIndex = 2
		knob.Parent = track
		UITheme.Corner(knob, 10)
		UITheme.Edge(knob, UITheme.BLACK, 2)

		local function render()
			local v = getValue()
			fill.Size = UDim2.new(v, 0, 1, 0)
			knob.Position = UDim2.new(v, 0, 0.5, 0)
			pct.Text = math.floor(v * 100 + 0.5) .. "%"
		end

		local dragging = false
		local function applyFromX(x)
			local v = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			setValue(v)
			render()
			queueSave()
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

	local renders = {}
	table.insert(renders, sliderRow(58, "MASTER", function()
		local m = SoundController.GetVolumes()
		return m
	end, function(v)
		local _, mu, s = SoundController.GetVolumes()
		SoundController.SetVolumes(v, mu, s)
	end))
	table.insert(renders, sliderRow(120, "MUSIC", function()
		local _, mu = SoundController.GetVolumes()
		return mu
	end, function(v)
		local m, _, s = SoundController.GetVolumes()
		SoundController.SetVolumes(m, v, s)
	end))
	table.insert(renders, sliderRow(182, "SFX", function()
		local _, _, s = SoundController.GetVolumes()
		return s
	end, function(v)
		local m, mu = SoundController.GetVolumes()
		SoundController.SetVolumes(m, mu, v)
	end))

	local function renderAll()
		for _, r in renders do
			r()
		end
	end

	gear.Activated:Connect(function()
		panel.Visible = not panel.Visible
		if panel.Visible then
			renderAll()
		end
	end)
	closeBtn.Activated:Connect(function()
		panel.Visible = false
	end)

	-- The profile's saved volumes may land after we've built (SoundController fetches async) — re-render
	-- whenever the panel opens covers it; also refresh once shortly after boot.
	task.delay(3, renderAll)

	print("[SettingsController] started")
end

return SettingsController
