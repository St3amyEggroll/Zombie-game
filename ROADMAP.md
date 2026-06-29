# Zombie Lobby — Build Roadmap

Phase-by-phase plan. Each phase is independently testable in Roblox Studio before the next.
**Status legend:** ✅ done · 🔄 in progress · ⬜ planned

> **Division of labor (locked):** *Claude writes all the code.* *You build the map, all 3D models,
> and style the UI.* The seam between us is **CollectionService tags + Attributes** for the map/models
> (see `CLAUDE.md` §10) and a **named-instance contract** for UI (you name the elements, my controllers
> find them by name and feed them data). Persistence is **stubbed** until Phase 8 (see note there).

---

## Status at a glance

| Phase | Scope | Status |
|---|---|---|
| 0 | Scaffold | ✅ |
| 1 | Core combat | ✅ |
| 2 | Zombies + rounds | ✅ |
| 3 | Points + buying | ✅ |
| 4 | Combat juice | ⬜ |
| 5 | Perks + Pack-a-Punch + Mystery Box | ⬜ |
| 6 | Down / revive co-op | ⬜ |
| 7 | Elites + bosses | ⬜ |
| 8 | Meta-progression + leaderboard | ⬜ |
| 9 | Polish & security pass | ⬜ |

---

## Phase 0 — Scaffold ✅
**Goal:** a clean skeleton everything plugs into; no gameplay.
**Claude built:** `default.project.json`; all six `Config/` tables (incl. Ray Gun + kill-weighted progression);
`Remotes`/`Types`/`Util`; server bootstrap + `DataService` (in-memory stub), `SecurityService`, `MatchService`
state skeleton; client bootstrap; `CLAUDE.md`.
**You provide:** nothing.
**Acceptance:** join → data loads, match state machine runs (Lobby→Starting→Playing), no errors.

## Phase 1 — Core combat ✅
**Goal:** server-authoritative shooting that feels good; the security spine for the whole game.
**Claude built:** `PlayerStateService` (health/regen/move/sprint), `CombatService` (validated fire + server
raycast + ammo + reload + Hit/Kill signals), `CameraController` (FP/TP toggle + aim solve), `InputController`
(fire loop + predicted ammo mirror + sprint/reload/interact/toggle), `WeaponViewController` (viewmodel/recoil/
muzzle, placeholder-friendly), minimal `HUDController` (ammo/health, debug fallback). Added `Sprint` remote.
**You provide:** a **test dummy** (any rig with a `Humanoid`, and a part named `Head` for headshots) to shoot.
Optional: viewmodel gun models at `ReplicatedStorage>Assets>Viewmodels>{weaponId}` (placeholder used otherwise).
**Acceptance:** shoot the dummy → server validates, damage applies, ammo counts down, reload works, headshots do
more; third-person by default with a first-person toggle (**V**); recoil + muzzle flash present.

## Phase 2 — Zombies + rounds ✅
**Goal:** escalating hordes that chase and attack; the round loop; performance that holds.
**Claude builds:** `ZombieService` (spawn by tag, weighted type pick, health/speed scaling per §8, **model pooling**,
**hard cap** at `MaxAliveZombies`, staggered AI, sparse pathfinding + steering — §13), `MatchService` real round
loop (compute count, spawn over time, wait for clear, round break, advance, boss on `BossInterval`), zombie
chase/attack (deals damage via `PlayerStateService.Damage`), death + ragdoll.
**You provide:** at least one **zombie model** (Model + `Humanoid` + `Head`; tint applied from `ZombieConfig`);
tagged `ZombieSpawn` parts; a `PlayerSpawn`; optional `Barricade` windows. (Greybox is fine — see `CLAUDE.md` §10.)
**Acceptance:** rounds spawn escalating walkers that path to and attack players; clearing a round advances it; the
frame rate holds at the zombie cap.

## Phase 3 — Points + buying ✅
**Goal:** the economy — earn points, spend them on the wall.
**Claude builds:** `PointsService` (award on hit/kill from `CombatService` signals, §8), `BuyService` (wall-buys,
ammo refill, doors/area unlocks), expand `HUDController` (points/round/team), `BuyPromptController` (logic for prompts).
**You provide:** tagged `WallBuy` parts (`WeaponId`,`Cost` attrs), `Door` parts (`Cost` attr), optional `AmmoBuy`;
styled HUD elements (`PointsLabel`,`RoundLabel`,…) and a buy-prompt UI.
**Acceptance:** kills earn points; buy weapons off walls; open doors; refill ammo.

## Phase 4 — Combat juice ⬜
**Goal:** make it *feel* punchy (porting the Duck Game juice to 3D).
**Claude builds:** `CombatFeedbackController` — stylized blood/goo, headshot pops, hitmarkers, screen shake, hitstop,
driven by the `HitConfirmed`/`ZombieDied` remotes.
**You provide:** optional VFX/sound assets (or accept the stylized defaults — kept cartoonish per the content rules).
**Acceptance:** shooting + killing feels punchy; headshots pop; hits read instantly.

## Phase 5 — Perks + Pack-a-Punch + Mystery Box ⬜
**Goal:** the run-build depth — perks, weapon upgrades, the gamble.
**Claude builds:** `PerkService` + machines (effects already wired into PlayerState/Combat from Phase 1), Pack-a-Punch
(set PaP flag → damage ×), `BuyService` Mystery Box (server rolls the weighted pool, returns result),
`MysteryBoxController` (the case-opening roll animation/juice).
**You provide:** tagged `PerkMachine` (`PerkId` attr), `MysteryBox`, `PackAPunch` models; world/viewmodel gun models;
styled box-roll UI.
**Acceptance:** buy perks (effects apply); Pack-a-Punch a weapon (more damage); roll the box with juice.

## Phase 6 — Down / revive co-op ⬜
**Goal:** the co-op heart.
**Claude builds:** `ReviveService` (down instead of die, bleedout timer, proximity+hold revive, drop perks on down if
configured), `ReviveController` UI logic, teammate-status HUD, all-down → game over.
**You provide:** revive-prompt + teammate-status UI styling; optional downed pose/visual.
**Acceptance:** go down instead of dying; a friend revives you; everyone down = game over.

## Phase 7 — Elites + bosses ⬜
**Goal:** tactical pressure that breaks up camping.
**Claude builds:** runner/brute/mutant elite behavior + the Abomination boss on `BossInterval`, special spawn announce
+ VFX (`ZombieSpawned` remote).
**You provide:** elite/boss models (or reuse the walker model with `ZombieConfig` tints); optional special VFX.
**Acceptance:** elites appear at their `minRound`; a boss spawns every `BossInterval` rounds; they force you to move.

## Phase 8 — Meta-progression + leaderboard ⬜
**Goal:** a reason to return.
**Claude builds:** `ProgressionService` (award account XP — **kill-weighted** — grant unlock tokens, update lifetime
stats + `bestRound` at game over; spend tokens to unlock weapons/perks), `LeaderboardService` (global best-round),
`GameOverController` summary.
**You provide:** an in-world leaderboard board model; styled game-over/summary + unlock-shop UI.
> ⚠ **Persistence dependency resurfaces here.** Today `DataService` is an in-memory stub, so XP/unlocks/leaderboard
> won't survive a server restart. Before (or during) Phase 8 we swap `DataService` internals to **ProfileStore**
> (one-file change by design) and add an OrderedDataStore for the leaderboard. Flag this when we reach it.
**Acceptance:** matches grant XP + unlocks that **persist**; the best-round leaderboard populates.

## Phase 9 — Polish & security pass ⬜
**Goal:** ship-quality.
**Claude builds:** full anti-exploit audit (every remote validated + rate-limited), performance tuning with the
MicroProfiler at 4 players, first-match onboarding, settings menu wiring, sound design hooks, map-polish support.
**You provide:** final map art/theming, sound assets, UI polish.
**Acceptance:** exploit-resistant; performant with full hordes at 4 players; polished, guided first match.

---

## Parallel tracks you can run anytime
- **Map:** build/greybox the arena to the tag/attribute contract in `CLAUDE.md` §10. My code finds parts by tag,
  never by name, so you can iterate the map freely without touching code.
- **Models:** zombies need `Humanoid` + `Head`; viewmodels go under `ReplicatedStorage>Assets>Viewmodels>{weaponId}`.
- **UI:** name your text elements per the contract each HUD/prompt controller documents; I populate them with data.

## How we work each phase
1. Claude implements Phase N (complete, server-authoritative, tunables-at-top).
2. You sync with Rojo, build any models/tags/UI that phase needs, run the acceptance check in Studio.
3. Commit at the boundary; move to N+1.
4. Tuning feel/difficulty later = edit only `Config/`, never service logic.
