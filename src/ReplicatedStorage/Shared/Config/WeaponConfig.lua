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
}

-- ===== WEAPON TABLE =====
-- Only weapons that have a 3D model are in the game right now. Add a weapon = add an entry here, give it
-- a hand model (tag a Model "WeaponModel" named the id, or put it in ReplicatedStorage>Assets>Weapons),
-- and (if it should be buyable) add it to ShopConfig.
local WeaponConfig: { [string]: Weapon } = {
	pistol = { id="pistol", name="M1911", damage=30, headshotMult=2,
		fireRate=5, magSize=8,  reserveAmmo=80,  reloadSeconds=1.4, range=200, pellets=1, spread=1, auto=false, wallBuyCost=0,    ammoCost=250,  ppDamageMult=3 },
	ak47   = { id="ak47",   name="AK-47", damage=40, headshotMult=2,
		fireRate=9, magSize=30, reserveAmmo=270, reloadSeconds=2.4, range=300, pellets=1, spread=2, auto=true,  wallBuyCost=3000, ammoCost=1000, ppDamageMult=3 },
}

return WeaponConfig
