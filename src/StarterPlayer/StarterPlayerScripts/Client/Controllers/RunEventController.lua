--!nonstrict
-- RunEventController.lua — client side of the EVENT WHEEL's wave modifiers + announcements:
--   • RunEvent "announce"  → the HUD announcement lane (event names ride the same queue as boss banners).
--   • RunEvent "fog"       → thick Lighting fog rolls in and SITS for the whole wave ({hold = true});
--     RunEvent "fogclear"  → the wave cleared: burn it back off.
--   • RunEvent "bloodmoon" → {on} the sky bleeds red for the whole wave (ambient + fog tint), then heals.
-- (The wheel's visible SPIN itself is EventWheelController; this file only renders the world FX.)

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)

local HUDController = require(script.Parent.HUDController)

local RunEventController = {}

-- ===== TUNABLES =====
local FOG_END = 90            -- how close the fog closes in (studs)
local FOG_TWEEN = 3           -- seconds to roll in / burn off
local MOON_TWEEN = 2          -- seconds for the blood-moon sky to bleed in / heal
local ANNOUNCE_SECONDS = 4

local COLORS = {
	gold = Color3.fromRGB(240, 196, 82),
	green = Color3.fromRGB(124, 219, 35),
	red = Color3.fromRGB(255, 96, 34),
	grey = Color3.fromRGB(180, 186, 168),
}

-- ===== FOG ===== (whole-wave: "fog" rolls it in and holds; "fogclear" burns it off)
-- FIXED (owner report: "fog doesn't work, I can still see fine"): when Lighting has an ATMOSPHERE,
-- Roblox IGNORES the classic FogStart/FogEnd properties entirely — so we drive Atmosphere.Density/Haze
-- when one exists, and fall back to classic fog when it doesn't. Both paths restore on clear.
local fogToken = 0
local fogBase -- Lighting/Atmosphere values before the fog landed (restored by fogclear)

local function atmosphere(): Atmosphere?
	return Lighting:FindFirstChildOfClass("Atmosphere")
end

local function rollFog()
	fogToken += 1
	local atmo = atmosphere()
	fogBase = fogBase or {
		FogEnd = Lighting.FogEnd,
		FogStart = Lighting.FogStart,
		FogColor = Lighting.FogColor,
		Density = atmo and atmo.Density or nil,
		Haze = atmo and atmo.Haze or nil,
		AtmoColor = atmo and atmo.Color or nil,
	}
	Lighting.FogColor = Color3.fromRGB(120, 128, 112)
	TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = FOG_END, FogStart = 12 }):Play()
	if atmo then -- the path that actually shows on a modern place
		TweenService:Create(atmo, TweenInfo.new(FOG_TWEEN), {
			Density = 0.72, -- thick: ~40-stud practical visibility
			Haze = 3,
			Color = Color3.fromRGB(120, 128, 112),
		}):Play()
	end
end

-- ===== BLIZZARD ===== a WHITE-OUT: the same Atmosphere blindfold as the fog but cold and brighter,
-- plus driving snow that sweeps across the camera. (The server owns the speed penalties; this is the
-- look.) It reuses fogBase/fogToken so a blizzard and a fog can never fight over the sky — only one
-- weather event runs per wave anyway.
local snowHolder   -- the camera-riding rig carrying the three snow depth layers
local snowDrift    -- the low rig blowing snow across the ground
local blizzardCC   -- ColorCorrection that blue-shifts the whole world
local frostGui     -- the icy screen-edge vignette
local breathToken = 0 -- cancels the breath-puff loop when the blizzard lifts
local function rollBlizzard()
	fogToken += 1
	local atmo = atmosphere()
	fogBase = fogBase or {
		FogEnd = Lighting.FogEnd,
		FogStart = Lighting.FogStart,
		FogColor = Lighting.FogColor,
		Density = atmo and atmo.Density or nil,
		Haze = atmo and atmo.Haze or nil,
		AtmoColor = atmo and atmo.Color or nil,
	}
	Lighting.FogColor = Color3.fromRGB(226, 238, 248)
	TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = 120, FogStart = 8 }):Play()
	if atmo then
		TweenService:Create(atmo, TweenInfo.new(FOG_TWEEN), {
			Density = 0.62,
			Haze = 4,
			Color = Color3.fromRGB(226, 238, 248), -- cold white, not the fog's sickly grey-green
		}):Play()
	end
	-- COLD-SHIFT THE WHOLE WORLD: a ColorCorrection tint + a little desaturation, so the map itself
	-- looks frozen instead of just having white particles drawn over it.
	if not blizzardCC then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "BlizzardCC"
		cc.TintColor = Color3.fromRGB(255, 255, 255)
		cc.Saturation = 0
		cc.Brightness = 0
		cc.Parent = Lighting
		blizzardCC = cc
		TweenService:Create(cc, TweenInfo.new(FOG_TWEEN), {
			TintColor = Color3.fromRGB(214, 233, 255), -- blue-shifted
			Saturation = -0.22,
			Brightness = 0.03,
		}):Play()
	end

	-- THE SNOW — three DEPTH LAYERS instead of one flat sheet: big soft flakes drifting close to the
	-- camera, fine fast ones far away. That parallax is what makes it read as a volume you're standing
	-- inside rather than an overlay stuck to the screen.
	local cam = Workspace.CurrentCamera
	if cam and not snowHolder then
		local holder = Instance.new("Part")
		holder.Name = "BlizzardSnow"
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.Transparency = 1
		holder.Size = Vector3.new(1, 1, 1)
		holder.CFrame = cam.CFrame
		holder.Parent = cam
		snowHolder = holder

		-- {size, rate, speed, lifetime, transparency} per depth: near → far
		local LAYERS = {
			{ size = 0.42, rate = 55,  speed = { 16, 24 }, life = { 1.1, 1.8 }, t0 = 0.42 },
			{ size = 0.22, rate = 130, speed = { 26, 38 }, life = { 0.9, 1.5 }, t0 = 0.3 },
			{ size = 0.1,  rate = 190, speed = { 40, 58 }, life = { 0.6, 1.0 }, t0 = 0.22 },
		}
		for _, L in LAYERS do
			local e = Instance.new("ParticleEmitter")
			e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			e.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
			e.LightEmission = 0.5
			e.LightInfluence = 0
			e.Size = NumberSequence.new(L.size, L.size * 0.3)
			e.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, L.t0),
				NumberSequenceKeypoint.new(1, 0.9),
			})
			e.Rate = L.rate
			e.Lifetime = NumberRange.new(L.life[1], L.life[2])
			e.Speed = NumberRange.new(L.speed[1], L.speed[2])
			e.SpreadAngle = Vector2.new(30, 30)
			e.Acceleration = Vector3.new(0, -14, 0)
			e.EmissionDirection = Enum.NormalId.Front
			e.Parent = holder
		end

		-- GROUND DRIFT: a separate low emitter blowing snow flat across the floor, so the ground moves
		-- too. Without it the world reads as a static plane with flakes falling past it.
		local ground = Instance.new("Part")
		ground.Name = "BlizzardDrift"
		ground.Anchored = true
		ground.CanCollide = false
		ground.CanQuery = false
		ground.CanTouch = false
		ground.Transparency = 1
		ground.Size = Vector3.new(1, 1, 1)
		ground.Parent = cam
		local d = Instance.new("ParticleEmitter")
		d.Texture = "rbxasset://textures/particles/smoke_main.dds"
		d.Color = ColorSequence.new(Color3.fromRGB(236, 246, 255))
		d.LightInfluence = 0
		d.Size = NumberSequence.new(2.2, 5.5)
		d.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.82),
			NumberSequenceKeypoint.new(0.4, 0.72),
			NumberSequenceKeypoint.new(1, 1),
		})
		d.Rate = 26
		d.Lifetime = NumberRange.new(1.2, 2)
		d.Speed = NumberRange.new(30, 46)
		d.SpreadAngle = Vector2.new(8, 4)
		d.EmissionDirection = Enum.NormalId.Front
		d.Parent = ground
		snowDrift = ground

		-- Both rigs ride the camera. The falling snow comes in over your shoulder; the drift sits at
		-- ankle height and blows straight across.
		task.spawn(function()
			while snowHolder == holder and holder.Parent do
				local c = Workspace.CurrentCamera
				if c then
					holder.CFrame = c.CFrame * CFrame.new(0, 14, 26) * CFrame.Angles(math.rad(-115), 0, 0)
					local look = c.CFrame.LookVector
					local flat = Vector3.new(look.X, 0, look.Z)
					flat = (flat.Magnitude > 0.01) and flat.Unit or Vector3.zAxis
					local base = c.CFrame.Position + flat * 34 - Vector3.new(0, 9, 0)
					ground.CFrame = CFrame.lookAt(base, base + Vector3.new(-flat.Z, 0, flat.X))
				end
				task.wait(0.06)
			end
			holder:Destroy()
			if ground.Parent then
				ground:Destroy()
			end
		end)
	end

	-- FROST VIGNETTE: ice creeping in from the screen edges. Four gradient frames (the same trick the
	-- event roller's edge glow uses) — cheap, and it frames every shot without hiding the middle.
	if not frostGui then
		local gui = Instance.new("ScreenGui")
		gui.Name = "BlizzardFrost"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 3 -- under the HUD; this is atmosphere, not information
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		frostGui = gui
		local function edge(anchor, pos, size, rot)
			local f = Instance.new("Frame")
			f.AnchorPoint = anchor
			f.Position = pos
			f.Size = size
			f.BackgroundColor3 = Color3.fromRGB(214, 238, 255)
			f.BackgroundTransparency = 1
			f.BorderSizePixel = 0
			f.Parent = gui
			local g = Instance.new("UIGradient")
			g.Rotation = rot
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.55),
				NumberSequenceKeypoint.new(1, 1),
			})
			g.Parent = f
			TweenService:Create(f, TweenInfo.new(FOG_TWEEN), { BackgroundTransparency = 0 }):Play()
		end
		edge(Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), UDim2.fromScale(1, 0.16), 90)
		edge(Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), UDim2.fromScale(1, 0.16), -90)
		edge(Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), UDim2.fromScale(0.11, 1), 0)
		edge(Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), UDim2.fromScale(0.11, 1), 180)
	end

	-- BREATH: little white puffs off your character. Cheap, and it sells "cold" harder than the snow.
	breathToken += 1
	local myBreath = breathToken
	task.spawn(function()
		while myBreath == breathToken do
			task.wait(2.4 + math.random() * 1.2)
			if myBreath ~= breathToken then
				return
			end
			local char = Players.LocalPlayer.Character
			local head = char and char:FindFirstChild("Head")
			if head then
				local puff = Instance.new("Part")
				puff.Shape = Enum.PartType.Ball
				puff.Anchored = true
				puff.CanCollide = false
				puff.CanQuery = false
				puff.CanTouch = false
				puff.CastShadow = false
				puff.Material = Enum.Material.SmoothPlastic
				puff.Color = Color3.fromRGB(238, 248, 255)
				puff.Transparency = 0.55
				puff.Size = Vector3.new(0.3, 0.3, 0.3)
				local out = head.CFrame.LookVector
				puff.CFrame = CFrame.new(head.Position + out * 0.9)
				puff.Parent = Workspace.CurrentCamera
				TweenService:Create(puff, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					CFrame = CFrame.new(head.Position + out * 3.2 + Vector3.new(0, 0.8, 0)),
					Size = Vector3.new(1.5, 1.5, 1.5),
					Transparency = 1,
				}):Play()
				game:GetService("Debris"):AddItem(puff, 1.2)
			end
		end
	end)
end

local function clearBlizzard()
	breathToken += 1 -- stop breathing
	if snowHolder then
		for _, e in snowHolder:GetDescendants() do
			if e:IsA("ParticleEmitter") then
				e.Rate = 0 -- stop making flakes; in-flight ones finish naturally
			end
		end
		snowHolder = nil -- the ride loop sees this and tears both rigs down
	end
	if snowDrift then
		for _, e in snowDrift:GetDescendants() do
			if e:IsA("ParticleEmitter") then
				e.Rate = 0
			end
		end
		snowDrift = nil
	end
	if blizzardCC then
		local cc = blizzardCC
		blizzardCC = nil
		local out = TweenService:Create(cc, TweenInfo.new(FOG_TWEEN), {
			TintColor = Color3.fromRGB(255, 255, 255),
			Saturation = 0,
			Brightness = 0,
		})
		out.Completed:Once(function()
			cc:Destroy()
		end)
		out:Play()
	end
	if frostGui then
		local gui = frostGui
		frostGui = nil
		for _, f in gui:GetChildren() do
			if f:IsA("Frame") then
				TweenService:Create(f, TweenInfo.new(FOG_TWEEN), { BackgroundTransparency = 1 }):Play()
			end
		end
		task.delay(FOG_TWEEN + 0.2, function()
			gui:Destroy()
		end)
	end
end

local function clearFog()
	fogToken += 1
	local myTok = fogToken
	if not fogBase then
		return
	end
	local base = fogBase
	local atmo = atmosphere()
	if atmo and base.Density ~= nil then
		TweenService:Create(atmo, TweenInfo.new(FOG_TWEEN), {
			Density = base.Density,
			Haze = base.Haze or atmo.Haze,
			Color = base.AtmoColor or atmo.Color,
		}):Play()
	end
	local out = TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = base.FogEnd, FogStart = base.FogStart })
	out.Completed:Once(function()
		if myTok == fogToken then
			Lighting.FogColor = base.FogColor
			fogBase = nil
		end
	end)
	out:Play()
end

-- ===== BLOOD MOON ===== (whole-wave: ambient bleeds red + a red haze; heals when the wave clears)
local moonBase -- Lighting values before the moon rose
local moonCC   -- the red ColorCorrection while it's up

local function setBloodMoon(on: boolean)
	if on then
		if not moonBase then
			moonBase = {
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
				FogColor = Lighting.FogColor,
			}
		end
		if not moonCC then
			moonCC = Instance.new("ColorCorrectionEffect")
			moonCC.Name = "BloodMoonCC"
			moonCC.TintColor = Color3.fromRGB(255, 255, 255)
			moonCC.Saturation = 0
			moonCC.Parent = Lighting
		end
		TweenService:Create(Lighting, TweenInfo.new(MOON_TWEEN), {
			Ambient = Color3.fromRGB(110, 30, 30),
			OutdoorAmbient = Color3.fromRGB(140, 45, 40),
			FogColor = Color3.fromRGB(120, 40, 35),
		}):Play()
		TweenService:Create(moonCC, TweenInfo.new(MOON_TWEEN), {
			TintColor = Color3.fromRGB(255, 190, 180),
			Contrast = 0.06,
		}):Play()
	else
		if moonBase then
			TweenService:Create(Lighting, TweenInfo.new(MOON_TWEEN), {
				Ambient = moonBase.Ambient,
				OutdoorAmbient = moonBase.OutdoorAmbient,
				FogColor = moonBase.FogColor,
			}):Play()
			moonBase = nil
		end
		if moonCC then
			local cc = moonCC
			moonCC = nil
			local heal = TweenService:Create(cc, TweenInfo.new(MOON_TWEEN), {
				TintColor = Color3.fromRGB(255, 255, 255),
				Contrast = 0,
			})
			heal.Completed:Once(function()
				cc:Destroy()
			end)
			heal:Play()
		end
	end
end

-- ===== RAIN ===== the shared downpour rig: an invisible emitter sheet riding ~55 studs above the
-- camera, streaking particles straight down (VelocityParallel = rain streaks, not dots). RAIN uses a
-- grey-blue wash; ACID RAIN reuses the same rig dyed toxic green. One emitter, one follow connection.
local rainPart, rainEmitter, rainConn

local function setRain(on: boolean, acid: boolean)
	if on then
		if not rainPart then
			rainPart = Instance.new("Part")
			rainPart.Name = "RainSheet"
			rainPart.Anchored = true
			rainPart.CanCollide = false
			rainPart.CanQuery = false
			rainPart.CanTouch = false
			rainPart.Transparency = 1
			rainPart.Size = Vector3.new(140, 1, 140)
			rainPart.Parent = Workspace

			rainEmitter = Instance.new("ParticleEmitter")
			rainEmitter.Rate = 320
			rainEmitter.Speed = NumberRange.new(70, 95)
			rainEmitter.Lifetime = NumberRange.new(1.1, 1.5)
			rainEmitter.EmissionDirection = Enum.NormalId.Bottom
			rainEmitter.Orientation = Enum.ParticleOrientation.VelocityParallel -- streaks, not dots
			rainEmitter.Size = NumberSequence.new(0.35)
			rainEmitter.Transparency = NumberSequence.new(0.35)
			rainEmitter.Acceleration = Vector3.new(0, -70, 0)
			rainEmitter.LightEmission = 0.2
			rainEmitter.Parent = rainPart

			rainConn = RunService.Heartbeat:Connect(function()
				local cam = Workspace.CurrentCamera
				if cam and rainPart then
					rainPart.CFrame = CFrame.new(cam.CFrame.Position + Vector3.new(0, 55, 0))
				end
			end)
		end
		rainEmitter.Color = ColorSequence.new(acid
			and Color3.fromRGB(120, 230, 60)   -- ACID: toxic green
			or Color3.fromRGB(165, 195, 225))  -- RAIN: grey-blue water
		rainEmitter.Enabled = true
	elseif rainEmitter then
		rainEmitter.Enabled = false -- in-flight drops die out on their own; the rig idles for next time
	end
end

-- ===== EARTHQUAKE ===== a short camera rumble (Humanoid.CameraOffset jitter — cheap, self-restoring).
local quakeToken = 0
local function rumble(secs: number)
	quakeToken += 1
	local myTok = quakeToken
	local player = game:GetService("Players").LocalPlayer
	if player:GetAttribute("ShakeOff") then
		return -- CHANGED: the CAMERA SHAKE setting now silences the earthquake rumble too
	end
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < secs and myTok == quakeToken do
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				local fade = 1 - (os.clock() - t0) / secs -- rumble dies down over the tremor
				hum.CameraOffset = Vector3.new(
					(math.random() - 0.5) * 1.1 * fade,
					(math.random() - 0.5) * 0.9 * fade,
					0)
			end
			task.wait(0.03)
		end
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and myTok == quakeToken then
			hum.CameraOffset = Vector3.zero
		end
	end)
end

function RunEventController.Start()
	Remotes.Get("RunEvent").OnClientEvent:Connect(function(kind, payload)
		payload = typeof(payload) == "table" and payload or {}
		if kind == "announce" and typeof(payload.text) == "string" then
			HUDController.Announce(payload.text, COLORS[payload.color] or COLORS.gold, ANNOUNCE_SECONDS)
		elseif kind == "fog" then
			rollFog()
		elseif kind == "fogclear" then
			clearFog()
		elseif kind == "blizzard" then
			if payload.on == true then
				rollBlizzard()
			else
				clearBlizzard()
				clearFog() -- the white-out uses the fog's sky slot; this restores it
			end
		elseif kind == "bloodmoon" then
			setBloodMoon(payload.on == true)
		elseif kind == "quake" then
			rumble(math.clamp(tonumber(payload.secs) or 0.9, 0.2, 3))
		elseif kind == "rain" then
			setRain(payload.on == true, false)
		elseif kind == "acidrain" then
			setRain(payload.on == true, true)
		end
	end)

	print("[RunEventController] started")
end

return RunEventController
