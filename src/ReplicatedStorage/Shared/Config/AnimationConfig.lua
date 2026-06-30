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

-- Screen shake + camera kick on fire (applied via the local player's Humanoid.CameraOffset).
-- Uses a "trauma" model: each shot adds trauma; shake = trauma² so it falls off smoothly. A sharp single
-- shot (pistol) spikes then settles = a pop; rapid fire (minigun) keeps trauma topped up = a rumble.
AnimationConfig.Shake = {
	Enabled = true,
	Decay = 7,          -- trauma lost per second (higher = settles faster)
	MaxOffset = 0.9,    -- studs of random camera shake at full trauma
	KickRecover = 14,   -- how fast the per-shot upward kick settles (higher = snappier)
	Default = { Trauma = 0.28, Kick = 0.12 }, -- used for any weapon not in PerWeapon below
	-- Per weapon: Trauma added per shot (pop vs rumble) and Kick = upward camera nudge (studs) per shot.
	PerWeapon = {
		pistol  = { Trauma = 0.40, Kick = 0.18 }, -- sharp pop
		ak47    = { Trauma = 0.22, Kick = 0.10 },
		minigun = { Trauma = 0.10, Kick = 0.04 }, -- small per shot; fast fire = sustained rumble
	},
}

-- ===== ANIMATION IDS ===== (paste the rbxassetid number; "" = none)
-- Played on the CHARACTER. "Hold" makes the character pose with the gun; "Reload" plays on R.
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
