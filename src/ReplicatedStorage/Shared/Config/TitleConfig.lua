--!strict
-- TitleConfig.lua — switchable overhead TITLES (trophies). Earned in the GAME (TitleService grants
-- achievements into profile.titlesOwned), equipped in the LOBBY (the classes showcase's TITLES
-- section saves profile.titleEquipped), rendered on the TOP line of the overhead tag
-- (PlayerTagService + TitleFXController animates the fancy styles).
--
--   style  : "static" | "rainbow" (hue cycles) | "pulse" (breathes) | "flicker" (unstable dips)
--   source : "gamepass"    — VIP: live pass check, never stored
--            "achievement" — stored in profile.titlesOwned the moment it's earned
--            "level"       — derived from account level at display/equip time, never stored
--
-- KEEP THE LOBBY'S MIRROR IN SYNC BY HAND (lobby-src LobbyServer TITLES + LobbyClient catalog).

local TitleConfig: { [string]: any } = {}

-- Display order for pickers (roughly: flex first, then the ladder, then the trophies).
TitleConfig.Order = {
	"vip", "survivor", "veteran", "nightmare", "unkillable",
	"bloodmoon", "vaultcracker", "apocalypse", "god", "elite", "legend",
}

TitleConfig.Titles = {
	vip          = { name = "VIP",                 style = "rainbow", color = Color3.fromRGB(230, 180, 76),  source = "gamepass",    how = "Own the VIP gamepass" },
	survivor     = { name = "SURVIVOR",            style = "static",  color = Color3.fromRGB(235, 235, 235), source = "achievement", how = "Reach wave 10" },
	veteran      = { name = "VETERAN",             style = "static",  color = Color3.fromRGB(95, 205, 95),   source = "achievement", how = "Reach wave 20" },
	nightmare    = { name = "NIGHTMARE",           style = "flicker", color = Color3.fromRGB(175, 95, 235),  source = "achievement", how = "Reach wave 30" },
	unkillable   = { name = "UNKILLABLE",          style = "pulse",   color = Color3.fromRGB(255, 215, 70),  source = "achievement", how = "Reach wave 40" },
	bloodmoon    = { name = "BLOOD MOON",          style = "static",  color = Color3.fromRGB(255, 70, 50),   source = "achievement", how = "Clear a BLOOD MOON wave" },
	vaultcracker = { name = "VAULT CRACKER",       style = "pulse",   color = Color3.fromRGB(240, 196, 82),  source = "achievement", how = "Crack the BODYGUARDS vault" },
	apocalypse   = { name = "APOCALYPSE SURVIVOR", style = "pulse",   color = Color3.fromRGB(255, 120, 40),  source = "achievement", how = "Survive an APOCALYPSE wave" },
	god          = { name = "GOD",                 style = "pulse",   color = Color3.fromRGB(120, 255, 235), source = "achievement", how = "Land a GOD MODE roll" },
	elite        = { name = "ELITE",               style = "static",  color = Color3.fromRGB(80, 145, 255),  source = "level", level = 20, how = "Reach account level 20" },
	legend       = { name = "LEGEND",              style = "rainbow", color = Color3.fromRGB(255, 80, 120),  source = "level", level = 40, how = "Reach account level 40" },
}

return TitleConfig
