--!strict
-- WeaponConfig.lua — every weapon. Add a weapon = add an entry (no logic edits anywhere).
-- Optional fields (boxOnly/wonder/splashRadius/ppName) are read by later phases and may be omitted.

export type Weapon = {
	id: string, name: string,
	damage: number, headshotMult: number,
	fireRate: number,      -- rounds/sec
	magSize: number, reserveAmmo: number, reloadSeconds: number,
	range: number,         -- studs
	pellets: number,       -- >1 = shotgun
	spread: number,        -- degree cone
	auto: boolean,
	wallBuyCost: number,   -- 0 = not on a wall (starting weapon OR box-only)
	ammoCost: number,
	ppDamageMult: number,  -- Pack-a-Punch damage ×
	-- ===== OPTIONAL / EXTENDED (safe to omit) =====
	boxOnly: boolean?,     -- true = only obtainable from the Mystery Box
	wonder: boolean?,      -- true = "wonder weapon": jackpot pull + special VFX
	splashRadius: number?, -- >0 = AoE damage radius in studs (read by CombatService later)
	ppName: string?,       -- Pack-a-Punch display name override
	spinUp: number?,       -- >0 = seconds of holding to ramp fire rate from slow -> full (minigun feel)
	maxTargets: number?,   -- pellets may spread across this many zombies (default 1 = focus the closest)
	knockback: number?,    -- studs/sec the zombie is shoved on a NON-lethal hit (death knockback is separate)
}

-- ===== WEAPON TABLE =====
-- Only weapons that have a 3D model are in the game right now. Add a weapon = add an entry here, give it
-- a hand model (tag a Model "WeaponModel" named the id, or put it in ReplicatedStorage>Assets>Weapons),
-- and (if it should be buyable) add it to ShopConfig.
local WeaponConfig: { [string]: Weapon } = {
	pistol = { id="pistol", name="M1911", damage=30, headshotMult=2,
		fireRate=5, magSize=8,  reserveAmmo=80,  reloadSeconds=1.4, range=200, pellets=1, spread=1, auto=false, wallBuyCost=0,    ammoCost=250,  ppDamageMult=3, knockback=26 },
	shotgun = { id="shotgun", name="Pump Shotgun", damage=14, headshotMult=2,
		fireRate=1.2, magSize=6, reserveAmmo=48, reloadSeconds=3, range=40, pellets=8, spread=12, auto=false, wallBuyCost=2000, ammoCost=750, ppDamageMult=3, knockback=48 },
	ak47   = { id="ak47",   name="AK-47", damage=40, headshotMult=2,
		fireRate=9, magSize=30, reserveAmmo=270, reloadSeconds=2.4, range=300, pellets=1, spread=2, auto=true,  wallBuyCost=3000, ammoCost=1000, ppDamageMult=3, knockback=24 },
	minigun = { id="minigun", name="Minigun", damage=16, headshotMult=1.5,
		fireRate=18, magSize=200, reserveAmmo=600, reloadSeconds=5, range=300, pellets=1, spread=5, auto=true, wallBuyCost=8000, ammoCost=2500, ppDamageMult=3, spinUp=1.0, knockback=16 },
	raygun  = { id="raygun", name="Ray Gun", damage=80, headshotMult=2,
		fireRate=4, magSize=20, reserveAmmo=200, reloadSeconds=2.5, range=250, pellets=1, spread=1, auto=true, wallBuyCost=0, ammoCost=0, ppDamageMult=3, wonder=true, knockback=40 },
}

return WeaponConfig
