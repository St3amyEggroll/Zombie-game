--!strict
-- EventLook.lua — how each EVENT ROLLER outcome READS on screen: its display name and its colour.
--
-- ONE SOURCE OF TRUTH. The reel (EventWheelController) and the live "what's running right now" chip
-- on the HUD (HUDController) both render event names, and they used to be able to drift apart. Adding
-- a new wheel outcome now means: a weight in GameConfig.Events.Weights, a row in EventService.OUTCOMES,
-- and a row HERE.
--
-- (Odds are NOT here on purpose — they're server-authoritative and arrive with each roll.)

export type Look = { name: string, color: Color3 }

local EventLook: { [string]: Look } = {
	calm       = { name = "CALM WAVE",       color = Color3.fromRGB(124, 219, 35) },
	fog        = { name = "FOG",             color = Color3.fromRGB(180, 186, 168) },
	rain       = { name = "RAIN",            color = Color3.fromRGB(165, 195, 225) },
	meteors    = { name = "METEOR SHOWER",   color = Color3.fromRGB(255, 140, 40) },
	bombsquad  = { name = "BOMB SQUAD",      color = Color3.fromRGB(255, 96, 34) },
	blizzard   = { name = "BLIZZARD",        color = Color3.fromRGB(200, 232, 255) },
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

return EventLook
