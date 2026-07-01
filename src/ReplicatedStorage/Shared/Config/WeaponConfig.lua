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
}

-- ===== WEAPON TABLE =====
-- Add a weapon = add an entry here, give it a hand model (tag a Model "WeaponModel" named the id, or put
-- it in ReplicatedStorage>Assets>Weapons), and add it to the lobby's WEAPONS catalog + a case pool.
local WeaponConfig: { [string]: Weapon } = {
	pistol  = { id="pistol",  name="M1911",         tier=1, damage=30, fireRate=5,   range=200, pellets=1, auto=false, knockback=26 },
	shotgun = { id="shotgun", name="Pump Shotgun",  tier=2, damage=16, fireRate=1.2, range=40,  pellets=6, maxTargets=6, auto=false, knockback=48 },
	ak47    = { id="ak47",    name="AK-47",         tier=3, damage=40, fireRate=9,   range=300, pellets=1, auto=true,  knockback=24 },
	minigun = { id="minigun", name="Minigun",       tier=4, damage=16, fireRate=18,  range=300, pellets=1, auto=true,  spinUp=1.0, knockback=16 },
	raygun  = { id="raygun",  name="Ray Gun",       tier=5, damage=80, fireRate=4,   range=250, pellets=1, auto=true,  knockback=40 },
}

return WeaponConfig
