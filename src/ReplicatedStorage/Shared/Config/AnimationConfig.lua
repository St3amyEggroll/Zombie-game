--!strict
-- AnimationConfig.lua — the animation overhaul knobs.
--
-- TWO kinds of stuff here:
--  1) PROCEDURAL effects (tracers, muzzle flash, recoil, impacts, hitmarker) — work immediately, no uploads.
--  2) ANIMATION IDS — you upload animations in Studio's Animation Editor, publish them, and paste the asset
--     id here (just the number is fine). Empty "" = use the engine default / skip. The code plays them.

local AnimationConfig = {}

-- ===== PROCEDURAL (no uploads needed) =====
-- PROJECTILE: a THIN LASER BOLT that actually TRAVELS from the gun barrel to the impact point — a skinny
-- bright streak with a short fading tail. Speed = studs/sec it flies; the bolt reaches the target in
-- distance/Speed seconds, then fades over Life. PerWeapon overrides Default.
--   Color = bolt/tail color   Length = streak length (studs, along travel)   Width = thickness (studs)
--   Speed = studs/sec         Life  = fade time once it lands
AnimationConfig.Projectile = {
	Enabled = true,
	Default = { Color = Color3.fromRGB(255, 235, 170), Length = 3.5, Width = 0.1,  Speed = 420, Life = 0.05 },
	PerWeapon = {
		pistol  = { Color = Color3.fromRGB(255, 235, 170), Length = 3.5, Width = 0.1,  Speed = 420, Life = 0.05 },
		shotgun = { Color = Color3.fromRGB(255, 205, 130), Length = 2.6, Width = 0.08, Speed = 380, Life = 0.04 },
		ak47    = { Color = Color3.fromRGB(255, 242, 180), Length = 4.0, Width = 0.1,  Speed = 480, Life = 0.05 },
		minigun = { Color = Color3.fromRGB(255, 180, 100), Length = 4.0, Width = 0.08, Speed = 520, Life = 0.04 },
		raygun  = { Color = Color3.fromRGB(120, 255, 140), Length = 4.5, Width = 0.2,  Speed = 300, Life = 0.08 },
	},
}

-- (Legacy line tracer — kept for reference; the projectile above replaces it. Set Projectile.Enabled=false
-- and Tracer.Enabled=true to fall back to instant lines.)
AnimationConfig.Tracer = {
	Enabled = false,
	Default = { Color = Color3.fromRGB(255, 231, 150), Width = 0.06, Life = 0.06 },
	PerWeapon = {
		pistol  = { Color = Color3.fromRGB(255, 231, 150), Width = 0.06, Life = 0.06 },
		shotgun = { Color = Color3.fromRGB(255, 200, 120), Width = 0.05, Life = 0.05 },
		ak47    = { Color = Color3.fromRGB(255, 240, 170), Width = 0.06, Life = 0.06 },
		minigun = { Color = Color3.fromRGB(255, 170,  90), Width = 0.06, Life = 0.05 },
		raygun  = { Color = Color3.fromRGB(120, 255, 140), Width = 0.16, Life = 0.10 },
	},
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

-- Screen shake + camera kick on fire (applied via the local player's Humanoid.CameraOffset).
-- Each shot (re)starts a Perlin-noise shake (math.noise = smooth, not jittery) that decays over its
-- Duration. A semi-auto shot (pistol) fires one strong, short shake = a pop; rapid fire (minigun) keeps
-- restarting a softer, longer shake = a sustained rumble. Kick = an upward camera nudge that recovers.
AnimationConfig.Shake = {
	Enabled = true,
	KickRecover = 14,   -- how fast the per-shot upward kick settles (higher = snappier)
	-- Per weapon: Magnitude (studs of shake), Duration (s the shake decays over), Frequency (Hz of the
	-- noise wobble), Kick (upward camera nudge in studs per shot). Default covers any weapon not listed.
	Default = { Magnitude = 0.5,  Duration = 0.20, Frequency = 20, Kick = 0.12 },
	PerWeapon = {
		pistol  = { Magnitude = 0.75, Duration = 0.18, Frequency = 22, Kick = 0.18 }, -- sharp pop
		ak47    = { Magnitude = 0.45, Duration = 0.16, Frequency = 26, Kick = 0.10 },
		minigun = { Magnitude = 0.35, Duration = 0.22, Frequency = 32, Kick = 0.04 }, -- soft + sustained rumble
	},
}

-- ===== ANIMATION IDS ===== (paste the rbxassetid number; "" = none)
-- Played on the CHARACTER. "Hold" makes the character pose with the gun. (No reload — ammo is infinite.)
AnimationConfig.Weapons = {
	pistol = { Hold = "", Reload = "" },
	ak47   = { Hold = "", Reload = "" },
}

-- Played on each ZOMBIE rig, SERVER-SIDE. Walk loops while chasing (defaults to the engine's walk
-- animation for the rig if left blank, so zombies animate out of the box); Attack on a hit; Death on death.
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
