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
	aoe: { damage: number, radius: number }?,      -- explosion/splash on impact: AoE damage to every zombie in radius
	ability: string?,      -- one-line ability text shown on the inventory panes
	price: number?,        -- (legacy) Coins price — guns now unlock by ACCOUNT LEVEL, not purchase
	unlock: number?,       -- account level that PERMANENTLY unlocks this gun (0/nil = starter)
}

-- ===== WEAPON TABLE =====
-- Add a weapon = add an entry here, give it a hand model (tag a Model "WeaponModel" named the id, or put
-- it in ReplicatedStorage>Assets>Weapons), and add it to the lobby's WEAPONS catalog + a case pool.
-- XP-ONLY UNLOCKS, in ladder order (pistol -> revolver -> shotgun -> ...). Reaching the level grants
-- the gun automatically (server: GunShopService.GrantUnlocks) — Coins no longer buy guns.
local UNLOCK_LEVELS = {
	pistol = 0, revolver = 2, shotgun = 4, tommygun = 6, ak47 = 8, crossbow = 10,
	honeybadger = 12, m4 = 14, p90 = 16, flamethrower = 18, freezeray = 20, minigun = 22,
	sniper = 24, plasma = 26, rocket = 28, raygun = 30,
}

-- CHANGED: full DPS-ladder retune — damage now climbs with unlock level (no more AK-47 out-gunning
-- the level-30 Ray Gun, no more unlocks weaker than the free pistol). Ranges are HONEST now: combat
-- clamps every shot to GameConfig.ArcRange (60), so ranges above 60 were fiction — all set to 60
-- (short-range cones keep their real reach: shotgun 40, flamethrower 38).
-- DPS ladder (damage × fireRate, by unlock level):
--   pistol 150 → revolver 162 → shotgun 173 → tommygun 216 → ak47 234 → crossbow 240 →
--   honeybadger 260 → m4 286 → p90 312 → flamethrower 324 → freezeray (utility) → minigun 396 →
--   sniper 432 → plasma 468+splash → rocket (blast) → raygun 520.
local WeaponConfig: { [string]: Weapon } = {
	pistol  = { id="pistol",  name="M1911",         tier=1, damage=30, fireRate=5,   range=60, pellets=1, auto=false, knockback=26 },
	revolver = { id="revolver", name="Revolver",    tier=2, damage=90, fireRate=1.8, range=60, pellets=1, auto=false, knockback=34, price=1500,
		pierce=3, ability="PIERCE — rounds punch through up to 3 zombies in a line" },
	shotgun = { id="shotgun", name="Pump Shotgun",  tier=2, damage=24, fireRate=1.2, range=40, pellets=6, maxTargets=6, spreadArc=100, auto=false, knockback=48, price=2500 },
	ak47    = { id="ak47",    name="AK-47",         tier=3, damage=26, fireRate=9,   range=60, pellets=1, auto=true,  knockback=24, price=6000 },
	crossbow = { id="crossbow", name="Crossbow",    tier=3, damage=240, fireRate=1.0, range=60, pellets=1, auto=false, knockback=10, price=8000,
		pin={secs=2}, ability="PIN — bolts nail zombies in place for 2s" },
	freezeray = { id="freezeray", name="Freeze Ray", tier=4, damage=16, fireRate=10, range=60, pellets=1, auto=true, knockback=6, price=20000,
		chill={slowPct=1, secs=4}, shatter={damage=45, radius=10},
		ability="CRYO — freezes zombies SOLID in ice for 4s; frozen zombies SHATTER on death (frost AoE)" },
	minigun = { id="minigun", name="Minigun",       tier=4, damage=22, fireRate=18,  range=60, pellets=1, auto=true,  spinUp=1.0, knockback=16, price=15000 },
	raygun  = { id="raygun",  name="Ray Gun",       tier=5, damage=130, fireRate=4,  range=60, pellets=1, auto=true,  knockback=40, price=40000 },

	-- ===== NEW GUNS =====
	m4         = { id="m4",         name="M4 Carbine",         tier=3, damage=26,  fireRate=11,  range=60, pellets=1, auto=true,  knockback=22, price=7000 },
	tommygun   = { id="tommygun",   name="Tommy Gun",          tier=2, damage=18,  fireRate=12,  range=60, pellets=1, auto=true,  knockback=18, price=3500 },
	sniper     = { id="sniper",     name="Bolt-Action Sniper", tier=4, damage=480, fireRate=0.9, range=60, pellets=1, auto=false, knockback=40, price=12000,
		pierce=4, ability="PIERCE — one shot punches through a whole line" },
	-- Cone spray: many fast weak bolts across a wide short-range arc (no DoT code needed — the flames melt up close).
	flamethrower = { id="flamethrower", name="Flamethrower",   tier=4, damage=9,   fireRate=12,  range=38, pellets=3, maxTargets=3, spreadArc=55, auto=true, knockback=4, price=18000,
		ability="INFERNO — sprays a short cone of fire" },
	-- aoe = blast on impact (damages every zombie within radius; kills credit the shooter's cash/XP).
	rocket     = { id="rocket",     name="Rocket Launcher",    tier=5, damage=20,  fireRate=0.7, range=60, pellets=1, auto=false, knockback=60, price=35000,
		aoe={damage=95, radius=18}, ability="EXPLOSIVE — the blast damages everything nearby" },
	plasma     = { id="plasma",     name="Plasma Rifle",       tier=5, damage=78,  fireRate=6,   range=60, pellets=1, auto=true,  knockback=20, price=30000,
		aoe={damage=22, radius=6}, ability="PLASMA — bolts splash on impact" },
	honeybadger = { id="honeybadger", name="Honey Badger",     tier=3, damage=26,  fireRate=10,  range=60, pellets=1, auto=true,  knockback=20, price=6500 },
	p90         = { id="p90",         name="P90",              tier=3, damage=24,  fireRate=13,  range=60, pellets=1, auto=true,  knockback=16, price=5000 },
}

for id, w in WeaponConfig do
	w.unlock = UNLOCK_LEVELS[id] or 0
end

return WeaponConfig
