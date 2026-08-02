--!nonstrict
-- RunEventController.lua — client side of the EVENT WHEEL's wave modifiers + announcements:
--   • RunEvent "announce"  → the HUD announcement lane (event names ride the same queue as boss banners).
--   • RunEvent "fog"       → thick Lighting fog rolls in and SITS for the whole wave ({hold = true});
--     RunEvent "fogclear"  → the wave cleared: burn it back off.
--   • RunEvent "bloodmoon" → {on} the sky bleeds red for the whole wave (ambient + fog tint), then heals.
-- (The wheel's visible SPIN itself is EventWheelController; this file only renders the world FX.)

local Lighting = game:GetService("Lighting")
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
local snowEmitter -- ParticleEmitter parented to the camera, so the snow follows you
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
	-- The snow itself: driven sideways past the camera so it reads as WIND, not gentle flakes.
	local cam = Workspace.CurrentCamera
	if cam and not snowEmitter then
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
		local e = Instance.new("ParticleEmitter")
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		e.LightEmission = 0.5
		e.LightInfluence = 0
		e.Size = NumberSequence.new(0.18, 0.05)
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 0.85),
		})
		e.Rate = 260
		e.Lifetime = NumberRange.new(0.8, 1.5)
		e.Speed = NumberRange.new(26, 42)
		e.SpreadAngle = Vector2.new(28, 28)
		e.Acceleration = Vector3.new(0, -14, 0)
		e.EmissionDirection = Enum.NormalId.Front
		e.Parent = holder
		snowEmitter = e
		-- Keep the emitter riding the camera without parenting particles to a moving CFrame every frame.
		task.spawn(function()
			while snowEmitter == e and holder.Parent do
				local c = Workspace.CurrentCamera
				if c then
					holder.CFrame = c.CFrame * CFrame.new(0, 14, 26) * CFrame.Angles(math.rad(-115), 0, 0)
				end
				task.wait(0.06)
			end
			holder:Destroy()
		end)
	end
end

local function clearBlizzard()
	if snowEmitter then
		snowEmitter.Rate = 0 -- stop making flakes; the loop tears the holder down once the ref clears
		snowEmitter = nil
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
