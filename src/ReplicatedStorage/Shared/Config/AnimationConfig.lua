--!strict
-- AnimationConfig.lua — the animation overhaul knobs.
--
-- TWO kinds of stuff here:
--  1) PROCEDURAL effects (tracers, muzzle flash, recoil, impacts, hitmarker) — work immediately, no uploads.
--  2) ANIMATION IDS — you upload animations in Studio's Animation Editor, publish them, and paste the asset
--     id here (just the number is fine). Empty "" = use the engine default / skip. The code plays them.

local AnimationConfig = {}

-- ===== PROCEDURAL (no uploads needed) =====
AnimationConfig.Tracer = {
	Enabled = true,
	Color = Color3.fromRGB(255, 231, 150),
	Width = 0.12,   -- studs
	Life = 0.06,    -- seconds visible
}

AnimationConfig.MuzzleFlash = {
	Enabled = true,
	Color = Color3.fromRGB(255, 221, 150),
	Brightness = 5,
	Range = 10,
	Life = 0.045,
}

AnimationConfig.Recoil = {
	Enabled = true,
	KickBack = 0.15,    -- studs the gun jerks back
	KickUp = 7,         -- degrees the muzzle rises
	RecoverTime = 0.12, -- seconds to settle back
}

AnimationConfig.Impact = {
	Enabled = true,
	Color = Color3.fromRGB(120, 200, 90),  -- stylized green goo for zombies (kept cartoonish)
	WorldColor = Color3.fromRGB(180, 180, 180),
	Life = 0.25,
}

AnimationConfig.Hitmarker = {
	Enabled = true,
	Color = Color3.fromRGB(255, 255, 255),
	KillColor = Color3.fromRGB(255, 80, 80),
	Size = 24,    -- pixels
	Life = 0.18,
}

-- ===== ANIMATION IDS ===== (paste the rbxassetid number; "" = none)
-- Played on the CHARACTER. "Hold" makes the character pose with the gun; "Reload" plays on R.
AnimationConfig.Weapons = {
	pistol = { Hold = "", Reload = "" },
	ak47   = { Hold = "", Reload = "" },
}

-- Played on each ZOMBIE rig. Walk loops while chasing; Attack on a hit; Death on death.
-- A type-specific entry (e.g. ["walker"]) overrides Default.
AnimationConfig.Zombies = {
	Default = { Walk = "", Attack = "", Death = "" },
}

-- Player movement overrides applied to the default Animate script. "" keeps Roblox's defaults
-- (which already animate walking + running).
AnimationConfig.Player = { Idle = "", Walk = "", Run = "", Jump = "" }

-- Normalize an id ("123", "rbxassetid://123", or "") into a usable AnimationId, or nil.
function AnimationConfig.Resolve(id: string?): string?
	if not id or id == "" then
		return nil
	end
	if string.match(id, "^%d+$") then
		return "rbxassetid://" .. id
	end
	return id
end

return AnimationConfig
