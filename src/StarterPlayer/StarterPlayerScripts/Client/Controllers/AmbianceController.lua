--!nonstrict
-- AmbianceController.lua — world mood: night time + a little distance fog. Lighting is client render
-- state, so this sets it locally for each player. Tune the look at the top.

local Lighting = game:GetService("Lighting")

local AmbianceController = {}

-- ===== TUNABLES =====
local CLOCK_TIME      = 0                        -- 0 = midnight, 6 = dawn, 12 = noon
local BRIGHTNESS      = 2                        -- sun/moon strength
local OUTDOOR_AMBIENT = Color3.fromRGB(90, 95, 120)  -- skylight colour (raised so you can see at night)
local AMBIENT         = Color3.fromRGB(80, 85, 110)  -- shadow fill colour (raised = brighter dark areas)
local FOG_COLOR       = Color3.fromRGB(40, 46, 62)   -- night fog (a bit lighter so it reads + lifts the dark)
local FOG_START       = 25                       -- studs before fog begins
local FOG_END         = 150                      -- studs where fog is full (lower = thicker; was 280)

function AmbianceController.Start()
	Lighting.ClockTime = CLOCK_TIME
	Lighting.Brightness = BRIGHTNESS
	Lighting.OutdoorAmbient = OUTDOOR_AMBIENT
	Lighting.Ambient = AMBIENT
	Lighting.FogColor = FOG_COLOR
	Lighting.FogStart = FOG_START
	Lighting.FogEnd = FOG_END
	print("[AmbianceController] started (night + fog)")
end

return AmbianceController
