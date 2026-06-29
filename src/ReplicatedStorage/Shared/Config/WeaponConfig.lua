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
local WeaponConfig: { [string]: Weapon } = {
	pistol  = { id="pistol",  name="M1911",      damage=30, headshotMult=2,
		fireRate=5,  magSize=8,  reserveAmmo=80,  reloadSeconds=1.4, range=200, pellets=1, spread=1,  auto=false, wallBuyCost=0,    ammoCost=250,  ppDamageMult=3 },
	smg     = { id="smg",     name="MP5",        damage=22, headshotMult=1.5,
		fireRate=12, magSize=30, reserveAmmo=240, reloadSeconds=2.0, range=180, pellets=1, spread=3,  auto=true,  wallBuyCost=1000, ammoCost=500,  ppDamageMult=3 },
	shotgun = { id="shotgun", name="Trench Gun", damage=24, headshotMult=1.5,
		fireRate=1.4,magSize=6,  reserveAmmo=48,  reloadSeconds=0.6, range=60,  pellets=8, spread=12, auto=false, wallBuyCost=1500, ammoCost=500,  ppDamageMult=3 },
	rifle   = { id="rifle",   name="AK-47",      damage=40, headshotMult=2,
		fireRate=9,  magSize=30, reserveAmmo=270, reloadSeconds=2.4, range=300, pellets=1, spread=2,  auto=true,  wallBuyCost=3000, ammoCost=1000, ppDamageMult=3 },
	lmg     = { id="lmg",     name="RPK",        damage=55, headshotMult=2,
		fireRate=10, magSize=75, reserveAmmo=375, reloadSeconds=4.0, range=300, pellets=1, spread=4,  auto=true,  wallBuyCost=5000, ammoCost=1500, ppDamageMult=3 },

	-- ===== WONDER WEAPON (box-only jackpot pull — see MysteryBoxConfig.Pool) =====
	raygun  = { id="raygun",  name="Ray Gun",    damage=150, headshotMult=2,
		fireRate=4,  magSize=20, reserveAmmo=160, reloadSeconds=2.0, range=250, pellets=1, spread=0.5, auto=false, wallBuyCost=0,    ammoCost=4950, ppDamageMult=2.5,
		boxOnly=true, wonder=true, splashRadius=8, ppName="Porter's X2 Ray Gun" },
}

return WeaponConfig
