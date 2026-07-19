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

function RunEventController.Start()
	Remotes.Get("RunEvent").OnClientEvent:Connect(function(kind, payload)
		payload = typeof(payload) == "table" and payload or {}
		if kind == "announce" and typeof(payload.text) == "string" then
			HUDController.Announce(payload.text, COLORS[payload.color] or COLORS.gold, ANNOUNCE_SECONDS)
		elseif kind == "fog" then
			rollFog()
		elseif kind == "fogclear" then
			clearFog()
		elseif kind == "bloodmoon" then
			setBloodMoon(payload.on == true)
		end
	end)

	print("[RunEventController] started")
end

return RunEventController
