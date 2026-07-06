# ZombieRot — Build Roadmap (Zombie Rush)

Wave-survival co-op zombie shooter. Each phase is independently testable in Roblox Studio.
**Status legend:** ✅ done · 🔄 in progress · ⬜ planned

> **Pivoted from Call-of-Duty-Zombies to Zombie Rush.** Removed: doors, wall-buys, Pack-a-Punch, perk
> machines, the Mystery Box, and down/revive. Replaced with a **menu shop** (buy + upgrade weapons for
> cash) and **respawn-on-death endless waves**.
>
> **Division of labor (locked):** *Claude writes all the code.* *You build the map, all 3D models, and
> style the UI.* The seam is **CollectionService tags + Attributes** (map/models) and a **named-instance
> contract** for UI. Persistence is **stubbed** until the meta phase.

---

## Status at a glance

| # | Phase | Status |
|---|---|---|
| 1 | Scaffold | ✅ |
| 2 | Core combat | ✅ |
| 3 | Zombies + waves | ✅ |
| 4 | Cash + shop | ✅ |
| 5 | Animation overhaul | ✅ |
| 6 | Combat juice | ⬜ |
| 7 | Elites + bosses | ⬜ |
| 8 | Meta-progression + leaderboard | ⬜ |
| 9 | Polish & security pass | ⬜ |

---

## 1 — Scaffold ✅
Project file, folder tree, all Config modules, Remotes/Util/Types, server+client bootstraps, in-memory
`DataService` stub, `SecurityService`. **Acceptance:** join → no errors, services start.

## 2 — Core combat ✅
Server-authoritative shooting (validated fire + server raycast + ammo + reload), third-person camera,
health/regen/sprint. **You provide:** a test dummy (Humanoid + `Head`). **Acceptance:** shoot it →
damage, ammo down, reload, headshots do more.

## 3 — Zombies + waves ✅
`ZombieService` (spawn by tag, HP/speed scaling per wave, model pooling, hard cap, staggered AI, sparse
pathfinding + steering, chase + attack, stuck recovery). Endless wave loop in `MatchService` with **respawn
on death** (no team-wipe game over). **You provide:** `ZombieSpawn` + `PlayerSpawn` parts, a floor, and a
zombie Model tagged `ZombieTemplate` (a grey placeholder is used until then). **Acceptance:** escalating
waves of zombies rush + attack you; clearing a wave advances it; dying respawns you; perf holds at the cap.

## 4 — Cash + shop ✅
`PointsService` (cash from kills, the only spend path), `ShopService` (buy weapons + upgrade your current
weapon for cash, server-validated), `ShopController` (the **B** menu), weapon switching (1–9),
`WeaponModelService` (your gun shown **in the character's hand**, welded server-side). **You provide:**
weapon Models tagged `WeaponModel` (named the weaponId, with a `Handle`); a styled shop/HUD if you want.
**Acceptance:** kills earn cash; the shop buys + upgrades guns; bought guns are usable and visible in-hand.

## 5 — Animation overhaul ✅
Two layers. **Procedural (works now, no uploads):** bullet tracers (yours predicted, others' broadcast via
`ShotFired`), muzzle flash, impact bursts, a hitmarker (`CombatFeedbackController`), and server-side gun
**recoil** (weld kick) so everyone sees it. **Animation-id playback (you upload, paste ids in
`AnimationConfig`):** weapon **Hold** pose + **Reload** on the character, **zombie** walk/attack/death, and
**player** walk/run overrides (defaults animate walk/run already). All id-gated — blank ids fall back
gracefully. **You provide:** uploaded animations (optional), and a `Muzzle` attachment on guns for a precise
tracer origin (optional). **Acceptance:** shots show tracers + muzzle flash + recoil + hitmarkers; once ids
are filled in, guns/zombies/players animate.

## 6 — Combat juice ⬜
The rest of the feel pass: screen shake, hitstop, headshot pops, bigger stylized blood/goo, kill feedback,
sound. Builds on the Phase 5 hooks. **You provide:** optional VFX/sound assets. **Acceptance:** killing feels
chunky and impactful.

## 7 — Elites + bosses ⬜
Runner/Brute/Mutant elites + the Abomination boss at higher waves (they already exist in `ZombieConfig`,
gated by `minRound`), special spawn announce + VFX via `ZombieSpawned`. **You provide:** elite/boss Models
(or reuse the default with `ZombieConfig` tints). **Acceptance:** elites appear at their waves; a boss on
the interval; they force you to move.

## 8 — Meta-progression + leaderboard ⬜
`ProgressionService` (account XP/levels — kill-weighted — + weapon unlocks at run end), `LeaderboardService`
(global **best wave**), end-of-run summary. **You provide:** a leaderboard board model; styled summary UI.
> ⚠ **Persistence dependency:** `DataService` is an in-memory stub today, so XP/unlocks/leaderboard won't
> survive a restart. This phase swaps it to a real datastore (one-file change by design).
**Acceptance:** runs grant XP + unlocks that persist; the best-wave leaderboard populates.

## 9 — Polish & security pass ⬜
Full anti-exploit audit (every remote validated + rate-limited), perf tuning at 4 players, onboarding,
settings, sound. **Acceptance:** exploit-resistant; performant with full hordes; polished first run.

---

## Parallel tracks you can run anytime
- **Map:** build the arena to the tag contract in `CLAUDE.md` §10 (`PlayerSpawn`, `ZombieSpawn`, a floor).
- **Models:** zombie → Model tagged `ZombieTemplate` (Humanoid + HumanoidRootPart + `Head`). Weapon → Model
  named after the gun (e.g. `m1911`, `ak47`) with a `Handle`, placed in `ReplicatedStorage > Assets` (or
  tagged `WeaponModel`); it's welded into the character's hand. (Third-person only — no viewmodels.)
- **UI:** name your HUD text elements `AmmoLabel`/`HealthLabel`/`RoundLabel`/`PointsLabel`; restyle the
  `ShopMenu` ScreenGui freely. The code populates them with data.

## How we work each phase
1. Claude implements the phase (complete, server-authoritative, tunables-at-top).
2. You sync with Rojo, build any models/tags/UI it needs, run the acceptance check in Studio.
3. Commit at the boundary; move on.
4. Tuning feel/difficulty = edit only `Config/` (incl. `ShopConfig`, `GameConfig`), never service logic.
