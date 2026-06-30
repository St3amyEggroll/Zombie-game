# Progression, Lobby & Crates — Design + Build Plan

The agreed design for the persistence / lobby / weapon-progression overhaul. Built **foundation-first**,
in shippable increments (the game stays playable at every step).

## Decisions (locked)
- **Lobby:** a **separate Roblox place** in the same experience/universe (shared DataStores). PLAY teleports
  to the game place; death teleports back to the lobby. *(Owner sets up the 2nd place + place IDs.)*
- **Run mode:** **shared co-op, drop-in.** One match per server; PLAY joins/starts it. Die → lobby, rejoin anytime.
- **Two currencies:**
  - **In-wave cash** — earned during a run, spent during the run on **weapon tier upgrades (1→6)**. **Resets each run.** (Lives in match state, NOT saved.)
  - **Lobby money** — **persistent** wallet, spent in the lobby (crates / cosmetics). Saved.
- **Weapons:**
  - You **own** a pool of weapons; you **equip up to 6** (slot 1 = starter, always the pistol).
  - **Tiers 1→6 are per-run** (reset every game); upgraded by spending in-wave cash.
  - New weapons come from **crates**, earned **every 10 waves**, **opened in the lobby**.
  - Crate rarity **scales with the wave + world** reached (wave 10 = mostly common; wave 20+ = better odds; etc.).
- **XP / level:** account XP from kills (kill-weighted) + wave reached → account level (kept).
- **Worlds:** multiple worlds later; build world 1 first, schema supports more.

## Persistent profile (DataService, DataStore-backed) — DONE ✅
`xp, level, lobbyMoney, ownedWeapons[], loadout[≤6], crates[], bestWave, stats{}, cosmetics{}, settings{}`
- Robust: pcall+retry, session cache, save on leave + BindToClose + autosave, graceful fallback if DataStores
  are unavailable (Studio API off) so the game never breaks.

## Build phases
1. **Persistence foundation** ✅ — real DataStore `DataService` (above).
2. **XP + lobby money wiring** — ProgressionService: award XP on kill/wave; award lobby money at run-end; push level/money to client.
3. **Loadout load** — at run start, a player's in-match weapons = their saved 6-slot loadout (pistol always slot 1).
4. **Lobby place + teleport** — *(needs owner's 2 place IDs)*. PLAY → teleport to game; death → teleport to lobby; loading screens.
5. **Crates** — earn 1 every 10 waves (rarity by wave/world), stored in profile, **opened in the lobby** (rarity roll → weapon).
6. **Tier system** — per-run tiers 1→6 per weapon, bought with in-wave cash.
7. **Lobby UI** — loadout editor, crate-opening, lobby shop (lobby money), stats, best wave, PLAY.
8. **Worlds + best-wave leaderboard.**

## What the OWNER needs to do for the lobby (Phase 4)
- Create a **second place** inside the same Roblox experience (one = Lobby, one = Game).
- Tell me the two **Place IDs**; I wire TeleportService both ways.
- (Until then, phases 2/3/5/6 build in the same codebase and run in both places.)
