--!strict
-- Types.lua — cross-cutting shared types. (Per-content types live in their Config module:
-- WeaponConfig exports Weapon, ZombieConfig exports ZombieType, PerkConfig exports Perk.)
-- This module returns an empty table; require it for its exported types only.

-- The match's high-level phase. MatchService owns transitions.
export type MatchPhase = "Lobby" | "Starting" | "Playing" | "RoundBreak" | "GameOver"

-- Per-weapon ammo held in a match (ephemeral).
export type AmmoState = {
	mag: number,      -- rounds in the magazine
	reserve: number,  -- rounds in reserve
}

-- One player's ephemeral, per-match state. Thrown away at game over (see CLAUDE.md §6).
export type PlayerMatchState = {
	userId: number,
	points: number,
	ownedWeapons: { string },               -- weapon ids owned this match
	equippedWeapon: string,                 -- currently held weapon id
	ammo: { [string]: AmmoState },          -- weaponId -> ammo
	perks: { string },                      -- perk ids bought this match
	packAPunched: { [string]: boolean },    -- weaponId -> upgraded?
	isDown: boolean,
	isDead: boolean,
	health: number,
	maxHealth: number,
	kills: number,
	specialKills: number,
	revives: number,
}

-- The whole match's ephemeral state, owned by MatchService.
export type MatchState = {
	phase: MatchPhase,
	round: number,
	zombiesRemaining: number,   -- still owed to spawn this round
	zombiesAlive: number,       -- currently alive in the world
	players: { [number]: PlayerMatchState },  -- keyed by userId
	startedAt: number,          -- os.clock() at match start
}

-- A live fire request from a client (validated server-side before use).
export type FireRequest = {
	weaponId: string,
	origin: Vector3,
	direction: Vector3,
}

return {}
