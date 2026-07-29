# ZOMBIEROT — Build Doc & Source of Truth

A 3D co-op zombie **wave shooter with a WHEEL OF FATE**: **kill the wave → the EVENT ROLLER flashes
through next wave's possible fates and locks one in with its % odds (Blood Moon / Fog / Meteor Shower /
Calm) → the whole wave plays under it → your Coins bank live as you kill → die as a team and the run
ends → back in the lobby, spend Coins on GUN CRATES and level up to unlock new guns free and harder
worlds.** Third-person, drop-in co-op.

> Built from an autonomous Claude Code spec (working title "HOLDOUT"). Renamed to **ZombieRot** (formerly "Zombie Lobby").
> **Pivoted four times:** Call-of-Duty-Zombies loop → simpler Zombie Rush (removed doors, wall-buys,
> Pack-a-Punch, perks, Mystery Box) → EXTRACTION (cash out / double down) → CONTINUOUS HORDE + POWER
> DRAFT (no waves, stacking power picks) → the current **WAVES + EVENT ROLLER** model: wave-based again,
> progressively harder forever, and EVERY wave break the roller lands a whole-wave modifier. The Power
> Draft is GONE (and the short-lived in-run Locker was built + deleted the same day — owner call).
> **SKINS ARE DELETED. Crates pay GUNS now** (dupes → coins) — guns ALSO still unlock free at account
> level, so a crate is how you pull one EARLY. Build incrementally, testable in Studio.
>
> ⚠️ **DOC-VS-CODE:** older sections below still describe earlier pivots (respawn/no-game-over, coin
> gun-shop, cash-out windows, the continuous horde, skins). The **shipped code is waves + event roller +
> gun crates + level-unlock** — trust §0/§1 here and the code over any stale mention further down.

---

## 0. Project state & decisions (READ FIRST)

**These decisions override anything that contradicts them elsewhere in this doc:**

| Decision | Choice |
|---|---|
| Game style | **Waves + the EVENT ROLLER.** Endless waves, progressively harder forever (`computeCount`/HP/speed growth per round). **Every wave break (8s) the roller runs** (`EventService.SpinForWave` → two-stage `EventSpin` remote: odds at spin start, `{lock=outcome}` at half-spin (anti-datamine) → `EventWheelController`): a top-center **VERTICAL REEL** — event names scroll through a clipped center window like a slot machine, each row stamped with its live % chance, decelerating until the locked outcome settles between the center rails and **blooms in its event color** (drama scaled by rarity; words only, no icons). The landed modifier runs the **WHOLE wave**: **CALM** (normal — weight shrinks as waves climb), **BLOOD MOON** (×1.35 zombie speed, ×2 Coins/kill, bleeding sky), **FOG** (sits all wave), **METEOR SHOWER** (strikes all wave). Supply Drop + Nest were CUT (so were the flawless-wave streak and the kill-streak cash multiplier — Coins pay flat). Wave clear pays per-wave Coins + case drops; boss every `BossEvery`-th wave. **Coins bank LIVE** (2/kill, 50/wave). **Death → spectate; a TEAM WIPE ends the run** — a paid **Robux revive** can buy back in during the wipe-grace window; **SKIP WAVE** (Robux) clears the current wave. Extraction stays dead (remotes dormant, `Extraction.Every = 0`); the in-run Locker was deleted. |
| Guns & economy | **SKINS DELETED — crates pay GUNS.** Guns still unlock **free at account level** (the lobby's XP-ONLY UNLOCKS auto-grant on load); **Coins buy GUN CRATES** which roll a gun by rarity (`CASES.gunWeights` → `GUNS_BY_RARITY`) — an unowned pull is yours EARLY, a **duplicate converts to Coins** (`GUN_DUP_COINS`); pity forces a legendary within `PityEvery` opens. The lobby's `gunLevels/gunCopies` copies system stays dormant. Old profiles' `skins` blobs are scrubbed on save; the game place renders base gun models only. |
| Worlds = difficulty | **Worlds ARE the difficulty knob** (`GameConfig.Maps` mult/speedMult × `WaveMult`). Worlds unlock by **account level** (`WorldUnlockLevel`). The old Easy…Nightmare/Endless difficulty ladder is GONE. |
| Game name | **ZombieRot** (project name in `default.project.json`) |
| Data persistence | **LIVE** — profiles persist via DataStore in both places (game + lobby share the save). Coins/XP/best-wave/wins/owned/loadout/cases/skins all save. |
| Progression XP | **Kill-weighted** (most XP from kills; round reached is a small bonus). See `ProgressionConfig`. Level gates gun + world unlocks. |
| Wonder weapon | **Ray Gun** — a top-tier level-unlock (`WeaponConfig.raygun`). (MysteryBox is retired.) |
| Map | **The owner builds it** in Studio. Code never references map parts by name — only by **CollectionService tag** (see §10). |
| 3D models | **The owner builds them** (zombies, guns, machines, the box). |
| UI | **The owner styles all UI; Claude writes all the code.** Controllers own the logic and look up the owner's named UI elements (named-instance contract). Each UI-driving controller will document the exact element names it expects, and tolerate missing elements gracefully. |

### Phase tracker
- [x] **Scaffold** ✅ (project file, folder tree, all Config modules, Remotes/Util/Types, bootstraps, in-memory DataService, SecurityService)
- [x] **Core combat** ✅ (PlayerStateService, InputController, CameraController FP/TP, server-authoritative CombatService + raycast, WeaponViewController recoil/muzzle, ammo+reload)
- [x] **Zombies + waves** ✅ (ZombieService spawn/AI/scaling/pooling/caps + stuck recovery, endless wave loop, chase/attack, **respawn on death**; tag-driven zombie models)
- [x] **Cash + shop** ✅ (cash from kills, **menu shop** to buy + upgrade weapons, weapon switching, **in-hand weapon models** welded server-side)
- [x] **Animation overhaul** ✅ (procedural: bullet tracers, muzzle flash, impacts, hitmarker, server gun **recoil**; id-gated playback via `AnimationConfig`: weapon hold/reload, zombie walk/attack/death, player run)
- [ ] **Combat juice** (screen shake, hitstop, headshot pops, bigger goo, sound — the rest of the feel pass)
- [ ] **Elites + bosses** (runner/brute/mutant + Abomination at higher waves, special spawn announce/VFX)
- [ ] **Meta-progression + leaderboard** (account XP/levels, weapon unlocks, global best-wave board)
- [ ] **Polish & security pass** (anti-exploit audit, perf at full hordes, onboarding, settings, sound)

> **Removed across the pivots:** doors, wall-buys, Pack-a-Punch, perk machines, the Mystery Box (CoD-Zombies);
> and the Zombie-Rush coin gun-shop + gun upgrading + respawn/no-game-over. `PerkConfig`/`MysteryBoxConfig`
> exist but are unused. **Known dead code (invisible to players, left in place — do NOT rip out casually):**
> `WeaponConfig.price` + the `BuyGun` charge path (guns are level-unlocks), and the gun-level/copies fields
> in the profile (no earn/spend path). The in-wave `Points` currency (`PointsService`) has no HUD readout and
> only feeds `TrapService`; treat it as legacy score, not a player-facing wallet.

---

## 1. The loop (the whole game)

**kill the wave → the wheel spins next wave's fate → survive whatever it lands on → Coins bank live →
wipe ends the run → spend Coins on cosmetics + level up for new guns/worlds → go again, push deeper.**

You spawn into a **world** (which is also the difficulty) with your level-unlocked loadout. Zombies come
in **waves** that grow forever (count, health and speed all scale per wave). Each kill banks **Coins** to
your profile *immediately* (2/kill, 50/wave — tune in `GameConfig`), so nothing you earn is ever lost.
Clear the wave and the **8-second break** hits: the **EVENT ROLLER** runs top-center — event names flash
one after another, each stamped with its **live % chance**, slowing like a thrown die until next wave's
fate **locks in**. **CALM** is a normal wave (rarer the deeper you go); **BLOOD MOON** turns the sky red,
speeds the horde up, and pays **double Coins** all wave; **FOG** blinds the map all wave; **METEOR
SHOWER** rains telegraphed strikes all wave. A **team wipe ends the run** (a Robux revive can buy back in
during the grace window; a Robux **SKIP WAVE** clears a wave that's about to eat you). Special/boss
zombies force you to move — dangerous types read by a **colored threat outline** before they reach you.
Between runs, in the **lobby**, spend Coins on **GUN CRATES** — a crate rolls a gun by rarity: an unowned
pull is **yours early**, a duplicate pays Coins back — while your **account level** keeps unlocking guns
free and gating the next world.

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
- **HUD corner grammar (BOTH places — the anti-confusion system):** left = money (coins pill),
  right = PEOPLE + progress (the party column, LVL/XP card — never buttons), bottom-center = actions
  (hotbar/loadout + the dock), top-center = status (wave strip / squad status). New UI slots into the
  corner its meaning belongs to; the two places must keep matching (shared builders: `LobbyLook.lua`).

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

| Tag | What to tag | Required Attributes | Read by |
|---|---|---|---|
| `PlayerSpawn` | a Part where players spawn | — | MatchService |
| `ZombieSpawn` | a Part at each zombie spawn point (can be invisible) | — | ZombieService |
| `ZombieTemplate` | your zombie **Model** (needs a `Humanoid`, a `HumanoidRootPart`/PrimaryPart, and a part named `Head`) | — | ZombieService (cloned + pooled as the zombie; named after a zombie typeId, else used as the default) |
| `WeaponModel` | your weapon **Model**, **named the weaponId** (e.g. `pistol`), with a part named `Handle` (or a PrimaryPart) | optional `Grip` (CFrame) | WeaponModelService (welds it into the holder's hand on equip) |

(Removed in the Zombie Rush pivot: `Door`, `WallBuy`, `AmmoBuy`, `PerkMachine`, `MysteryBox`, `PackAPunch`.)

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
