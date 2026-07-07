--!strict
-- WeaponConfig.lua — every weapon. Add a weapon = add an entry (no logic edits anywhere).
-- Weapons come from the LOBBY (cases → tier loadout); there is no in-run gun buying and no ammo/reload.

export type Weapon = {
	id: string, name: string,
	tier: number,          -- 1..5 — position on the gun ladder (drives the in-run NEXT GUN price)
	damage: number,
	fireRate: number,      -- rounds/sec — THE fire cap (constant; nothing changes it)
	range: number,         -- studs (auto-aim reach is min(this, GameConfig.ArcRange))
	pellets: number,       -- >1 = shotgun (pellets split across up to maxTargets zombies)
	auto: boolean,         -- true = hold to fire continuously; false = one shot per click
	-- ===== OPTIONAL (safe to omit) =====
	spinUp: number?,       -- >0 = seconds of firing to ramp fire rate from slow -> full (minigun feel)
	maxTargets: number?,   -- pellets may spread across this many zombies (default 1 = focus the closest)
	knockback: number?,    -- studs/sec the zombie is shoved on a NON-lethal hit (death knockback is separate)
	spreadArc: number?,    -- degrees: this weapon's pellets hit across a WIDER arc than GameConfig.ArcDegrees
	-- ===== ABILITIES (all optional; CombatService/ZombieService read these, no logic edits to add one) =====
	pierce: number?,       -- shot hits up to this many zombies lined up behind each other (full damage each)
	pin: { secs: number }?,                        -- non-lethal hits nail the zombie in place
	chill: { slowPct: number, secs: number }?,     -- non-lethal hits slow the zombie
	shatter: { damage: number, radius: number }?,  -- a CHILLED zombie killed = frost AoE around the corpse
	ability: string?,      -- one-line ability text shown on the inventory panes
}

-- ===== WEAPON TABLE =====
-- Add a weapon = add an entry here, give it a hand model (tag a Model "WeaponModel" named the id, or put
-- it in ReplicatedStorage>Assets>Weapons), and add it to the lobby's WEAPONS catalog + a case pool.
local WeaponConfig: { [string]: Weapon } = {
	pistol  = { id="pistol",  name="M1911",         tier=1, damage=30, fireRate=5,   range=200, pellets=1, auto=false, knockback=26 },
	revolver = { id="revolver", name="Revolver",    tier=2, damage=70, fireRate=1.8, range=220, pellets=1, auto=false, knockback=34,
		pierce=3, ability="PIERCE — rounds punch through up to 3 zombies in a line" },
	shotgun = { id="shotgun", name="Pump Shotgun",  tier=2, damage=16, fireRate=1.2, range=40,  pellets=6, maxTargets=6, spreadArc=100, auto=false, knockback=48 },
	ak47    = { id="ak47",    name="AK-47",         tier=3, damage=40, fireRate=9,   range=300, pellets=1, auto=true,  knockback=24 },
	crossbow = { id="crossbow", name="Crossbow",    tier=3, damage=110, fireRate=1.0, range=260, pellets=1, auto=false, knockback=10,
		pin={secs=2}, ability="PIN — bolts nail zombies in place for 2s" },
	freezeray = { id="freezeray", name="Freeze Ray", tier=4, damage=10, fireRate=10, range=180, pellets=1, auto=true, knockback=6,
		chill={slowPct=0.3, secs=2}, shatter={damage=45, radius=10},
		ability="CRYO — chills 30%; chilled zombies SHATTER on death (frost AoE)" },
	minigun = { id="minigun", name="Minigun",       tier=4, damage=16, fireRate=18,  range=300, pellets=1, auto=true,  spinUp=1.0, knockback=16 },
	raygun  = { id="raygun",  name="Ray Gun",       tier=5, damage=80, fireRate=4,   range=250, pellets=1, auto=true,  knockback=40 },
}

return WeaponConfig
