# ZOMBIE LOBBY — Build Doc & Source of Truth

A 3D co-op last-stand zombie survival shooter (Call of Duty Zombies lineage): **hold the line → earn
points from kills → spend on weapons, perks, and Pack-a-Punch between waves → survive escalating
rounds with elite and boss zombies → revive your friends when they go down → push for a higher round
than last time.** Third-person by default (with an optional first-person toggle), built for drop-in co-op.

> Built from an autonomous Claude Code spec (working title "HOLDOUT"). Renamed to **Zombie Lobby**.
> Build **phase by phase** — each phase is independently testable in Roblox Studio before the next.

---

## 0. Project state & decisions (READ FIRST)

**These decisions override anything that contradicts them elsewhere in this doc:**

| Decision | Choice |
|---|---|
| Game name | **Zombie Lobby** (project name in `default.project.json`) |
| Data persistence | **SKIPPED for now.** `DataService` is an in-memory stub with the final API — swap in ProfileStore later by editing one file. No data survives a server restart yet. |
| Progression XP | **Kill-weighted** (most XP from kills; round reached is a small bonus). See `ProgressionConfig`. |
| Wonder weapon | **Ray Gun** added — box-only jackpot pull (`WeaponConfig.raygun`, in `MysteryBoxConfig.Pool` at low weight). |
| Map | **The owner builds it** in Studio. Code never references map parts by name — only by **CollectionService tag** (see §10). |
| 3D models | **The owner builds them** (zombies, guns, machines, the box). |
| UI | **The owner styles all UI; Claude writes all the code.** Controllers own the logic and look up the owner's named UI elements (named-instance contract). Each UI-driving controller will document the exact element names it expects, and tolerate missing elements gracefully. |

### Phase tracker
- [x] **Phase 0 — Scaffold** ✅ (project file, folder tree, all Config modules, Remotes/Util/Types, bootstraps, in-memory DataService, SecurityService, MatchService state skeleton)
- [x] **Phase 1 — Core combat** ✅ (PlayerStateService, InputController, CameraController FP/TP, server-authoritative CombatService + raycast, WeaponViewController recoil/muzzle, ammo+reload, minimal HUD; added Sprint remote)
- [ ] **Phase 2 — Zombies + rounds** (ZombieService spawn/AI/scaling/pooling/caps, MatchService round loop, chase/attack, death+ragdoll)
- [ ] **Phase 3 — Points + buying** (PointsService, BuyService wall-buys/ammo/doors, HUD, BuyPrompt)
- [ ] **Phase 4 — Combat juice** (blood/goo, headshot pops, hitmarkers, shake, hitstop)
- [ ] **Phase 5 — Perks + PaP + Mystery Box** (PerkService, Pack-a-Punch, the roller)
- [ ] **Phase 6 — Down/revive co-op** (ReviveService, revive UI, all-down game over)
- [ ] **Phase 7 — Elites + bosses** (runner/brute/mutant, boss on BossInterval, special VFX)
- [ ] **Phase 8 — Meta-progression + leaderboard** (ProgressionService XP/unlocks, LeaderboardService, GameOver summary)
- [ ] **Phase 9 — Polish & security pass** (full anti-exploit audit, perf tuning, onboarding, settings)

---

## 1. The loop (the whole game)

**kill → points → spend → survive harder → snowball → die a little deeper than last time.**

Start with a pistol, 500 points, one locked door. Shoot zombies for points (10/hit, 60/kill,
100/headshot-kill). Spend points between waves on wall guns, the Mystery Box (gamble a random gun,
maybe the Ray Gun), perk machines (Juggernog +150 HP, Speed Cola faster reload…), opening new map
areas, Pack-a-Punch (upgrade your gun), and ammo. Special zombies (Runner/Brute/Mutant) and bosses
(Abomination) force you off your camp spot. Downs aren't death — a friend can revive you. Everyone
down at once = game over. Reward = account XP (kill-weighted) + a best-round leaderboard number to beat.

---

## 2. Architecture (the rules everything follows)

- **Server-authoritative throughout.** Client sends *intent* (fire direction, "buy this", "revive").
  Server owns health, ammo, points, round number, every zombie's HP, who's down — and raycasts/
  computes all of it. This is the anti-exploit spine (CLAUDE.md §14). Non-negotiable.
- **Two kinds of state (CLAUDE.md §6):**
  - *Ephemeral* (per-match, server memory, discarded at game over): round, points, owned weapons,
    ammo, perks, Pack-a-Punch state, who's down. Lives in `MatchService.State`.
  - *Persistent* (meta-progression): account XP/level, unlocks, best round, stats. **Stubbed in
    memory for now** via `DataService`.
- **Tag-driven map.** Systems find spawns/windows/machines/walls by CollectionService tag, with
  costs/ids as Attributes (§10). Code never hardcodes part references.
- **Server pattern:** each Service is a ModuleScript returning a table with `.Start()`.
  `init.server.lua` builds remotes, then starts services in dependency order
  (Data → Security → PlayerState → Match → everything). New `*Service` files auto-start.
- **Client pattern:** each Controller is a ModuleScript with `.Start()`, auto-discovered and started
  by `init.client.lua`.

---

## 3. Repo structure (Rojo)

```
src/
├── ReplicatedStorage/Shared/
│   ├── Config/   GameConfig, WeaponConfig, ZombieConfig, PerkConfig, MysteryBoxConfig, ProgressionConfig
│   └── Modules/  Remotes (registry), Types, Util
├── ServerScriptService/Server/
│   ├── init.server.lua            # bootstrap
│   └── Services/                  # DataService, SecurityService, MatchService (more per phase)
└── StarterPlayer/StarterPlayerScripts/Client/
    ├── init.client.lua            # bootstrap
    └── Controllers/               # (added per phase)
```

`default.project.json` maps `src/` → Roblox services. Sync with Rojo into a fresh Studio place.

---

## 5. Coding conventions (HARD REQUIREMENTS)

1. **Complete, copy-paste-ready scripts.** No stubs, no `-- TODO`, no partial functions in shipped
   phases. (Phase 0's skeleton services are the documented exception — they run clean and mark exactly
   where later phases extend.)
2. **Tunables grouped at the TOP** of each module (`-- ===== TUNABLES =====` style).
3. **`-- NEW:` / `-- CHANGED:`** markers when iterating an existing file.
4. **Data-driven.** Content in `Config/`; logic reads config. Adding a weapon/zombie/perk = a table
   entry, never a logic edit.
5. **Server-authoritative + anti-exploit by default** (§14). Client sends intent; server validates,
   raycasts, computes.
6. **One service/controller per file.**
7. `--!strict` on config + shared modules; `--!nonstrict` on services where Instance typing fights.

---

## 8. Combat math (server computes ALL of it)

```
DAMAGE per hit = weapon.damage × (headshot and weapon.headshotMult or 1)
                              × (packAPunched and weapon.ppDamageMult or 1)
  (shotguns/raygun splash: per-pellet/per-target; total = sum of hits)
FIRE RATE effective = weapon.fireRate × (hasDoubleTap and perk.fireRateMult or 1)
RELOAD effective    = weapon.reloadSeconds × (hasSpeedCola and perk.reloadMult or 1)
MAX HEALTH          = PlayerMaxHealth + (hasJug and perk.healthBonus or 0)
ZOMBIES this round  = floor( BaseZombiesPerRound × RoundZombieGrowth^(round-1)
                             × (1 + (playerCount-1) × PlayerCountScale) )
ZOMBIE HEALTH       = floor( ZombieBaseHealth × ZombieHealthGrowth^(round-1) × type.healthMult )
ZOMBIE SPEED        = min( ZombieMaxSpeed, (ZombieBaseSpeed + ZombieSpeedPerRound×(round-1)) × type.speedMult )
POINTS: hit = PointsPerHit; kill = (headshotKill and PointsHeadshotKill or PointsPerKill); both × type.pointsMult
```

The client renders results; it never sends damage, kills, ammo counts, or points.

---

## 10. Map & model contract — CollectionService tags + Attributes (BUILD THE MAP TO THIS)

The owner builds the level and all models. Systems find map elements **only by tag**. Put costs/ids
on parts as **Attributes** so the map stays data-driven. The map lives in `ServerStorage` and is
cloned into Workspace on match start (clean resets) — or just build it in Workspace for now while
greyboxing.

| Tag | What to tag | Required Attributes | Read by (phase) |
|---|---|---|---|
| `ZombieSpawn` | a Part at each spawn point (can be invisible) | — | ZombieService (P2) |
| `PlayerSpawn` | a Part / SpawnLocation for player starts | — | MatchService (P2) |
| `Barricade` | boardable window models | — | ZombieService break-in (P2), BuyService repair (P3) |
| `Door` | a Part that blocks an area | `Cost` (number) | BuyService (P3) |
| `WallBuy` | a Part showing a wall weapon | `WeaponId` (string), `Cost` (number) | BuyService (P3) |
| `AmmoBuy` | (optional) a Part for ammo refill | `Cost` (number, or omit to use weapon.ammoCost) | BuyService (P3) |
| `PerkMachine` | each perk machine model | `PerkId` (string, e.g. "jug") | PerkService (P5) |
| `MysteryBox` | the box model | — | BuyService (P5) |
| `PackAPunch` | the PaP machine model | — | BuyService (P5) |

**Naming for models** (so later code can find sub-parts): give weapon/zombie models a
`HumanoidRootPart` (or a `PrimaryPart`), and zombies a `Humanoid` + a part named `Head` for headshots.
Exact model expectations get pinned down when each phase that uses them is built.

---

## 13. Performance (the horde challenge — designed in from Phase 2)

- **Hard cap** simultaneous zombies at `GameConfig.MaxAliveZombies`; extra owed zombies only spawn as
  others die.
- **Stagger AI** across `GameConfig.ZombieAITickRate` — only a slice re-targets each tick.
- **Pathfind sparingly:** recompute a path every `GameConfig.PathRecompute` seconds and **steer**
  between waypoints, not full pathfinding per frame.
- **Pool zombie models** — reuse instances.
- **Raycast on fire only** — no continuous hit loops.

---

## 14. Security (cross-cutting — every remote)

1. Server-authoritative state (client sends intent only).
2. Validate every remote: types correct; can afford/owns/is-allowed; values in sane ranges; action
   currently legal.
3. Combat is the #1 surface: server raycasts from a **validated origin** (checked vs the server's
   known player position) with direction sanity; no client damage/kill claims; ammo + fire-rate
   enforced server-side via the `SecurityService` token bucket.
4. Rate-limit fire/reload/buy/revive/interact per `GameConfig.RateLimits`.
5. Meta writes funnel through `DataService` only.

`SecurityService` already provides: `Allow(player, action)` (token bucket), `OriginNearPlayer`,
`IsValidDirection`, `IsFiniteVector3`, `IsAlive`.

---

## 16. How to drive this build

Build one phase at a time. Suggested prompt:
> *"Read CLAUDE.md. Implement **Phase N** only — complete, copy-paste-ready files following the §5
> conventions (tunables at top, server-authoritative). List files changed + how to test the Phase N
> acceptance check in Studio."*

Sync with Rojo, test the acceptance check, commit, move on. **Tuning feel/difficulty later = edit
only the `Config/` modules, never service logic.**

---

## 17. Quick-tune cheat sheet

- **Too easy / too hard →** `GameConfig` round/health/speed growth.
- **Server lag with hordes →** lower `MaxAliveZombies`, raise `ZombieAITickRate`/`PathRecompute`.
- **Guns feel weak/strong →** `WeaponConfig` damage / fireRate / headshotMult.
- **Economy too tight/loose →** `GameConfig` points + wall/ammo/perk costs.
- **Zombies too samey →** tune `spawnWeight` + `minRound` in `ZombieConfig`.
- **Box too generous →** raise `MysteryBoxConfig.Cost`, reweight the `Pool`.
- **Progression too fast/slow →** `ProgressionConfig` XP-per-kill + `LevelGrowth`.
