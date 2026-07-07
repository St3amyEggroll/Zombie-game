# Maps & Worlds — what to build and where to put it

How to build a map so ZombieRot uses it. Everything is **tag/attribute-driven** — code never references your
parts by name, so you can build freely. Two worlds ship today: **Forest** (zombies dig out of graves) and
**Islands** (zombies rise from the ocean).

---

## How a map gets picked and shown

1. In the **lobby**, the host picks a **world + difficulty** (worlds come from `LobbyServer WORLDS`, currently
   `forest`, `islands`). Islands unlocks after you beat `forest : nightmare`.
2. Pressing PLAY teleports the party to the **GAME place** with `map = "<world>"` in the teleport data.
3. At run start, **`MapService`** shows the chosen world's map and tucks every other map into `ServerStorage`
   (so two maps can live in the same place without overlapping). Then **`ZombieService`** reads the world to
   decide the enemy roster and **how zombies emerge** (grave vs water) — see `GameConfig.Maps`.

**You can keep both maps in `Workspace` while building.** At run start only the selected one stays; the rest
go inert automatically.

---

## Rule 1 — wrap each map in one container, named for its world

Put **all** of a map's parts inside a single `Model` (or `Folder`), and name it so MapService can find it —
either way works:

| Option | What to do |
|---|---|
| **By name** | Name the container **`<world>Map`** — e.g. `ForestMap`, `IslandsMap`. (Case/spaces/dashes don't matter: `islands map` works too.) |
| **By tag** | Tag the container **`Map`** and give it a **String attribute `World`** = `forest` / `islands`. |

Everything for that map (ground, props, water, spawn points, its `SpawnLocation`) goes **inside** this container.

---

## Rule 2 — the universal tags (both maps)

Add these with the **Tag Editor** (View ▸ Tags) — select the part, add the tag.

| Tag | Put it on | Notes |
|---|---|---|
| **`PlayerSpawn`** *(optional)* | a `SpawnLocation` where players start | Use a real `SpawnLocation`, not a plain Part, so players actually spawn there. Put it inside the map container. |
| **`NoSpawn`** *(optional)* | any Part | A keep-out box — no zombie ever spawns inside it (+4 studs). Use for buildings, cliffs, the void. |
| **Fog folder** *(optional)* | a `Folder` **named `Fog`** holding your boundary walls | Same effect as `NoSpawn` for everything inside it — the out-of-bounds border. |

> Owner-built **zombie models** are shared across maps: tag a `Model` **`ZombieTemplate`** (needs a `Humanoid`,
> a `PrimaryPart`/`HumanoidRootPart`, and a part named `Head`). Name it after a zombie id (e.g. `drowned`) to
> use it for that type; an untagged-name one becomes the default. Or drop models in
> `ReplicatedStorage/Assets/Zombies/<id>`. See "New zombies" below.

---

## FOREST (World 1) — zombies dig out of **graves**

Forest spawns zombies **~35 studs from a random living player** and rises them out of a **grave headstone**.
You do **not** place spawn points.

**Build checklist**
- [ ] Container `Model` named **`ForestMap`** (or tagged `Map`, `World = forest`).
- [ ] Solid **walkable ground** (Terrain or Parts) — zombies raycast down to find it, so no big holes.
- [ ] A **`SpawnLocation`** inside the container (tag `PlayerSpawn`) where players start.
- [ ] A **`Fog`** folder of boundary walls around the edge (keeps zombies in bounds), and/or `NoSpawn` parts
      over anything zombies shouldn't erupt from (rooftops, water, the void).
- [ ] **Grave models** in `ReplicatedStorage/Assets/Graves` (or `ServerStorage/Assets/Graves`):
      - `Grave1`, `Grave2`, … — normal enemies
      - `BigGrave1`, … (name starts with **Big**) — Tanks
      - `HugeGrave1`, … (name starts with **Huge**) — Bosses
      - A grave is a small prop that rises out of the ground, then sinks. If you build none, zombies still
        spawn — just with no headstone.

`GameConfig.Maps.forest = { emerge = "grave", useSpawnPoints = false }` — already set.

---

## ISLANDS (World 2) — zombies rise from the **ocean**

Islands spawns zombies **at the water points you place** (`ZombieSpawn` tag) and rises them out with a
**splash** instead of a grave. This is the map you're building.

**Build checklist**
- [ ] Container `Model` named **`IslandsMap`** (or tagged `Map`, `World = islands`).
- [ ] Your **islands** (walkable land) + the **ocean** around them.
- [ ] A **`SpawnLocation`** on an island (tag `PlayerSpawn`) where players start.
- [ ] **`ZombieSpawn` parts — THIS is the "water stuff they come out of."** Place Parts where zombies should
      surface, and **tag each one `ZombieSpawn`**:
      - Put them in the **shallows / at the shoreline** so zombies can walk straight onto land. (A humanoid
        can't swim across deep ocean to reach you — spawn them where they can wade ashore.)
      - The **top face of the part = the water surface** the zombie rises to. Sit each part so its top is at
        the waterline. Make them **invisible** (`Transparency = 1`) and **`CanCollide` off** — they're just
        markers.
      - Size matters: zombies spawn anywhere within a part's footprint (up to 12×12 studs), so a wider part =
        a wider emergence area. Scatter **several** around each island so hordes come from all sides.
      - Zombies prefer `ZombieSpawn` points **within 160 studs of a player**, falling back to any point — so
        ring each island with them.
- [ ] **Splash models** *(optional)* in `ReplicatedStorage/Assets/Splashes` (`Splash1`, `Splash2`, …) — the
      water burst shown as each zombie surfaces. If you build none, a simple expanding water ring is used, so
      Islands works right away.

`GameConfig.Maps.islands = { emerge = "water", useSpawnPoints = true }` — already set.

> **Tip:** keep the ocean shallow near shore, or add thin invisible walkable "sandbar" parts just under the
> surface from each `ZombieSpawn` to the beach, so zombies have a floor to walk on out of the water.

---

## New zombies

Four **Islands-only** enemies are already in `ZombieConfig` (they only spawn on `islands` via `worlds`):

| id | name | flavor |
|---|---|---|
| `drowned` | Drowned | the basic waterlogged grunt |
| `lurker` | Lurker | fragile but very fast — rushes you |
| `angler` | Angler | leaps to close the gap |
| `brinebrute` | Brine Brute | tanky mini-elite (announces on spawn) |

To make them look unique, build a model for each and either **name it the id** (`drowned`, `lurker`, …) and
drop it in `ReplicatedStorage/Assets/Zombies/`, **or** tag a `Model` `ZombieTemplate` and name it the id.
Until then they use the default zombie model, tinted by the `tint` in config (they already work — just grey).

**Add another zombie** = one line in `ZombieConfig` (no code changes):
- Islands-only: add `worlds = { islands = true }`.
- Forest-only: add `worlds = { forest = true }`.
- Everywhere: omit `worlds`.
- `spawnWeight` = how common (0 = never random, bosses only), `minRound` = when it first appears,
  `healthMult`/`speedMult`/`damage`/`pointsMult` scale off the wave. `canLeap` / `isBomb` / `canFly` /
  `summons` add behaviors.

> The **shared Forest roster** (default, speedy, lead, leaper, tank, bombzombie, ghost) also appears on
> Islands — they just rise from the water there. Want Islands to use *only* its own enemies? Add
> `worlds = { forest = true }` to each Forest entry.

---

## Folder layout (recap)

```
Workspace (while building — MapService sorts them at run start)
├── ForestMap        (Model, or tagged Map/World=forest)
│   ├── <ground, props>
│   ├── SpawnLocation           (tag PlayerSpawn)
│   └── Fog                     (Folder of boundary walls)
└── IslandsMap       (Model, or tagged Map/World=islands)
    ├── <islands, ocean>
    ├── SpawnLocation           (tag PlayerSpawn)
    └── <invisible Parts>       (tag ZombieSpawn — in the shallows)

ReplicatedStorage/Assets/         (or ServerStorage/Assets)
├── Graves     → Grave1, BigGrave1, HugeGrave1, …   (Forest)
├── Splashes   → Splash1, Splash2, …                (Islands, optional)
└── Zombies    → drowned, lurker, angler, brinebrute, default, tank, …
```

## Final checklist before you test Islands
1. `IslandsMap` container named/tagged correctly. ✅ selectable in the lobby (add `islands` — already done).
2. A `PlayerSpawn` `SpawnLocation` on land.
3. Several **`ZombieSpawn`** parts in the shallows around each island.
4. (Optional) `Splashes` models, else the built-in ring plays.
5. (Optional) island zombie models named `drowned` / `lurker` / `angler` / `brinebrute`.

To test without grinding the unlock, temporarily set the party to Islands in the lobby (or unlock it in your
save). Zombies should surface at your `ZombieSpawn` points with a splash and wade toward you.
