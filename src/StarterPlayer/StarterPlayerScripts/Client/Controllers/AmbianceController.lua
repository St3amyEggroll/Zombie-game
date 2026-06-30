--!nonstrict
-- AmbianceController.lua — world mood: night time + a little distance fog. Lighting is client render
-- state, so this sets it locally for each player. Tune the look at the top.

local Lighting = game:GetService("Lighting")

local AmbianceController = {}

-- ===== TUNABLES =====
local CLOCK_TIME      = 0                       -- 0 = midnight, 6 = dawn, 12 = noon
local BRIGHTNESS      = 1.5                     -- sun/moon strength
local OUTDOOR_AMBIENT = Color3.fromRGB(45, 50, 70)  -- skylight colour (night blue)
local AMBIENT         = Color3.fromRGB(35, 38, 55)  -- shadow fill colour
local FOG_COLOR       = Color3.fromRGB(12, 15, 25)  -- dark night fog
local FOG_START       = 40                      -- studs before fog begins
local FOG_END         = 280                     -- studs where fog is full ("a little" = far; lower = thicker)

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
