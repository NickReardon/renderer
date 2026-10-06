# Entity Models: The Debate

How should the engine represent "things in the world": meshes, lights, cameras and empties in
the modeler, and players, enemies and pickups in a game? This compares eight approaches, makes
the strongest case for and against each, and ends with a recommendation.

> **Decision (October 2026): hybrid fat struct.** Recorded in `DESIGN.md`; the rules are in
> `STYLE.md` §15.

## What we need from it

| Need | Why it matters here |
|---|---|
| **Editor support** | Selection, an inspector panel, undo, save/load. The modeler comes first, so this weighs heavily. |
| **Gameplay variety** | Phase 3 adds game objects with behavior that combines features in new ways. |
| **Iteration speed** | Per-frame loops over many objects (transforms, culling, physics). |
| **Hot reload** | State must be plain data in `Game_Memory`, with no procedure pointers. |
| **Simplicity** | One person plus Claude; every line must be understandable. |
| **Learning value** | Part of the point is to understand these designs. |

---

## 1. Inheritance hierarchy (the baseline we're avoiding)

`Entity` → `Actor` → `Pawn` → `Character`, with virtual `update()` and `draw()`.

- **For:** familiar; maps to how people describe the world; Unreal's `AActor` still works this way.
- **Against:**
  - the "diamond" problem the first time something is both a `Light` and a `Pickup`;
  - behavior is scattered across virtual overrides;
  - objects are separate heap allocations in random order;
  - procedure pointers (vtables) break hot reload.
- **Verdict:** not an option for this project. It's here as the reference point.

## 2. Game objects with attached component objects (classic Unity, Godot nodes)

Each entity holds a list of component objects, and each component has its own `update`.

- **For:**
  - composition instead of inheritance;
  - designers can mix behaviors in the editor;
  - easy to build an inspector, since each component draws its own UI.
- **Against:**
  - still one object at a time, with a virtual call per component per frame;
  - components scattered in memory;
  - order of updates is implicit;
  - Unity built DOTS largely because this model didn't scale.
- **Verdict:** better than inheritance, but it's still OOP with components bolted on.

## 3. Fat struct + handles ("megastruct")

One `Entity` struct contains *every* field any entity might need; flags say which parts are in
use. Entities live in a fixed pool and are referred to by generational handles. (Muratori,
Fleury)

```odin
Entity_Flag :: enum { Visible, Selected, Has_Mesh, Has_Light, Has_Physics, Player_Controlled }

Entity :: struct {
	generation: u32,
	flags:      bit_set[Entity_Flag],
	parent:     Entity_Handle,
	position:   [3]f32,
	rotation:   quaternion128,
	scale:      [3]f32,
	mesh:       Mesh_Handle, // used when .Has_Mesh
	light:      Light,       // used when .Has_Light
	velocity:   [3]f32,      // used when .Has_Physics
}

entities: [MAX_ENTITIES]Entity

for &e in entities {
	if .Has_Physics in e.flags {
		e.position += e.velocity * dt
	}
}
```

- **For:**
  - the simplest model there is: one type, one array, one handle type;
  - **any combination of features is free**: a light that's also physical and player-controlled
    needs no new code;
  - generic code (inspector, save/load, undo, selection, transform gizmo) is written once,
    because there is only one shape of data;
  - undo can snapshot the whole array;
  - hot reload is trivial, since it's plain data;
  - **your friend's Modeler3D already uses this** (`Object` with a `kind` and every field
    inline), and it handles a full modeler.
- **Against:**
  - every entity pays for every field: with 50 fields at ~500 bytes, 10k entities is ~5 MB,
    and loops stride over unused bytes;
  - nothing stops code from reading `light` on an entity without `.Has_Light`;
  - the struct grows into a junk drawer if nobody is disciplined;
  - large variable data (mesh geometry, inventory lists) can't be stored inline and must be
    handles to other storage anyway.
- **Mitigations:**
  - keep big data behind handles;
  - when one loop becomes hot, move just those fields into a separate `#soa` array indexed by
    the same slot.
- **Best for:** editors and games with up to several thousand entities. That covers this project
  for a long time.

## 4. Tagged union per kind

```odin
Entity :: struct {
	position: [3]f32,
	variant:  union { Player, Enemy, Light_Source, Camera },
}

switch &v in e.variant {
case Player:       // player-specific code
case Light_Source: // ...
}
```

- **For:**
  - type-safe: you can't read light fields on a player;
  - each variant is only as big as it needs to be (the union is the size of the largest);
  - idiomatic in Odin.
- **Against:**
  - **combinations are the problem:** a "light that is also a pickup" needs a new variant or
    nesting, which is the inheritance diamond again;
  - generic code must switch on every variant;
  - the Handmade forum discussion in `REFERENCES.md` argues this scales as the number of
    combinations (O(2^N)) where a fat struct scales with the number of features (O(N)).
- **Best for:** data that really has a few disjoint kinds that never combine, such as UI
  widgets, shapes in a parametric recipe, or commands in an undo log. It's a good tool *inside*
  entities, not as the entity model itself.

## 5. One table per kind (existence-based processing)

No generic "entity" at all: each kind gets its own array.

```odin
World :: struct {
	meshes:  [dynamic]Mesh_Object,
	lights:  [dynamic]Light_Object,
	cameras: [dynamic]Camera_Object,
	bullets: #soa[dynamic]Bullet,
}
```

- **For:**
  - maximal data orientation: each array is exactly the data its loop needs;
  - no flags to check, because being in the array *is* the flag (Fabian, *Existence-based
    processing*);
  - simple loops.
- **Against:**
  - cross-cutting features (selection, parenting, the gizmo, the inspector, save/load) must be
    written once per table or need a generic "reference to any table" handle;
  - something that is both a light and a mesh doesn't fit.
- **Best for:** high-count, single-purpose data (particles, bullets, decals) *alongside* a main
  entity model. As the only model it fights the editor.

## 6. Sparse components / component managers (Bitsquid, EnTT)

An entity is just an ID. Each component type lives in its own dense array with a lookup from
entity → slot (a hash map or a *sparse set*). Systems loop over one component array.

```odin
Entity :: distinct u32

Transform_Store :: struct {
	owner:    [dynamic]Entity,       // dense: slot -> entity
	position: [dynamic][3]f32,       // dense component data (SoA)
	rotation: [dynamic]quaternion128,
	slot_of:  [dynamic]i32,          // sparse: entity -> slot, -1 if absent
}
```

- **For:**
  - any combination of components;
  - each system touches only dense, packed data;
  - adding a component type doesn't affect others;
  - scales to hundreds of thousands of entities;
  - Bitsquid shipped real games on it.
- **Against:**
  - **joins are the cost:** a system needing transform + velocity + mesh must look up each
    entity in three stores (random access), or the stores must be kept sorted together;
  - more code per component type: add, remove, lookup, iterate;
  - the editor inspector and undo need per-store code or a reflection layer;
  - entity identity is spread over many places, which makes it harder to debug.
- **Best for:** large games where a few systems dominate frame time and touch one or two
  components each.

## 7. Archetype ECS (flecs, Bevy, Unity DOTS)

Entities with the same *set* of components are stored together in a table, one column per
component. Adding or removing a component moves the entity to another table. Queries match
tables.

- **For:**
  - the fastest iteration for multi-component queries: every column of a matching table is
    dense and aligned, so joins are free;
  - queries are declarative;
  - scales to millions of entities;
  - well documented (Sander Mertens' ECS FAQ).
- **Against:**
  - **by far the most complex** to build: table storage, moving entities between tables, query
    caching, and deferred structural changes so a loop doesn't change the table it iterates;
  - adding or removing components is expensive;
  - debugging is indirect;
  - the editor needs reflection;
  - for a few thousand entities, it's slower to build *and* not faster at runtime than a fat
    struct.
- **Best for:** very large simulations, or a dedicated learning exercise. Writing a small one
  later is a great project; making it the foundation now isn't.

## 8. Generic property objects (Our Machinery's "The Truth")

Every object is a type ID plus an array of typed properties described by data (schema). The
editor, undo, save/load, copy-paste, prototypes/prefabs and even collaboration are written once,
generically, against the schema.

- **For:**
  - the most powerful editor model;
  - undo, serialization and the inspector come for free for any new type;
  - prefabs and inheritance of values ("prototypes") are natural.
- **Against:**
  - indirection on every property access, so it's slow for per-frame simulation;
  - it's a data model for the editor, not for runtime: Our Machinery compiled it into separate
    runtime data for the game;
  - substantial infrastructure before anything is on screen.
- **Best for:** the *editor document* in a large engine. The ideas (schema-driven inspector,
  undo as data) are worth borrowing later.

---

## Comparison

| | Simplicity | Feature combinations | Iteration speed (few thousand) | Iteration speed (100k+) | Editor (inspector, undo, save) | Hot reload |
|---|---|---|---|---|---|---|
| 1. Inheritance | Medium | ❌ | Poor | Poor | Medium | ❌ vtables |
| 2. Component objects | Medium | ✅ | Poor | Poor | ✅ | ❌ vtables |
| 3. **Fat struct** | ✅✅ | ✅ | Good | Medium | ✅✅ (one shape) | ✅ |
| 4. Tagged union | ✅ | ❌ | Good | Good | Medium | ✅ |
| 5. Table per kind | ✅ | ❌ | ✅✅ | ✅✅ | Poor | ✅ |
| 6. Sparse components | Medium | ✅✅ | Good | ✅ | Medium (needs reflection) | ✅ |
| 7. Archetype ECS | ❌ | ✅✅ | Good | ✅✅ | Medium (needs reflection) | ✅ |
| 8. Property objects | ❌ | ✅✅ | Poor | Poor | ✅✅✅ | ✅ |

## How major engines and tools do it (as of October 2026)

| Engine / tool | Model | Notes |
|---|---|---|
| **Unreal (Actors)** | #1 + #2: `AActor` inheritance plus attached `UActorComponent` objects | The classic model; still how most UE5 games are built. |
| **Unreal (Mass)** | #7: archetype ECS: *fragments* (data), *archetypes*, *processors* (systems) | A specialized subsystem for crowds and traffic (the City Sample), running *alongside* Actors rather than replacing them. |
| **Unreal (Scene Graph, UEFN → UE6)** | Closer to #2: *entities* containing *components* (data + Verse logic), entity hierarchies, *prefabs* | Replaces Actors in UEFN (beta, publishable). Epic says UE6 is built around merging UE and UEFN, with early access targeted around the end of 2027. It's a composition model, not an archetype ECS. |
| **Unity** | #2 (GameObjects + MonoBehaviours) *plus* #7 (DOTS Entities, archetype chunks) | "ECS for all": every GameObject backed by an entity, unified transforms, unified authoring. The ECS packages are now core packages; full integration is planned for Unity 7, with an alpha expected around late 2026 according to community summaries of Unity's posts. |
| **Godot** | #1 + #2: a node tree with inheritance; scenes are reusable node trees | Deliberately *not* ECS (Linietsky, 2021). Performance-critical work lives in data-oriented **servers** (RenderingServer, PhysicsServer, AudioServer) under the nodes. |
| **Blender** | Close to #3 + #8: `Object` (transform, parent, type, flags) points at an obdata ID (`Mesh`, `Light`, `Camera`…) | Separating Object from data lets many objects share one mesh. DNA (C structs saved directly into `.blend`) plus RNA (reflection that drives the UI, Python and animation). The depsgraph evaluates *copies* of the data for display. Meshes are SoA attribute arrays. |
| **Houdini** | Not entities, but geometry as SoA attribute tables (detail / primitive / vertex / point) inside a node network | The most data-oriented of the DCC tools. Blender's geometry nodes adopted a similar attribute model. |
| **Maya** | A dependency graph of nodes with attributes; DAG *transform* nodes over *shape* nodes | The same object/data split as Blender. |
| **Substance 3D Painter** | No entity system: a document of texture sets, each with a **layer stack** (paint, fill, folder layers; multi-channel, masks, effects) evaluated into textures | Internals aren't public. The data model is a non-destructive layer tree, closer to #4 (layers as a tagged union) feeding a GPU compositing pipeline. |
| **Bevy** | #7: archetype ECS; each component chooses table or sparse-set storage | ECS is the entire engine, editor included. |
| **Minecraft Bedrock** | #6: sparse-set ECS (EnTT; Mojang maintains a fork) | |
| **Overwatch** | ECS (Timothy Ford, GDC 2017) | Credited with keeping gameplay and netcode complexity manageable. |
| **Bitsquid / Stingray, Our Machinery** | #6 at runtime; Our Machinery added #8 ("The Truth") for the editor | The authoring model is compiled into a separate runtime model. |
| **Handmade-style games** (Handmade Hero, many Odin/C indie games) | #3: fat struct | |

**The common thread: almost every large engine ends up with *two* models.** One is an
*authoring/editor* model optimized for editing, undo and reflection: Unity GameObjects, Godot
nodes, Blender's ID/RNA, Our Machinery's Truth. The other is a *runtime* model optimized for
iteration: Unity entities, Godot servers, Blender's evaluated depsgraph copies, Unreal Mass.
The "pivot to ECS" in Unity and Unreal is mostly about moving the *runtime* side to
data-oriented storage while keeping a familiar authoring model on top.

**What this means for us:**
- the fat struct can be both models while the project is small;
- borrow Blender's Object/data split: entities hold a `Mesh_Handle`, so meshes can be shared
  and instanced;
- if a split is ever needed, follow the industry pattern: keep the fat struct as the editor
  model and generate runtime tables (#5/#6) from it.

## Recommendation: a hybrid built on the fat struct

1. **Scene objects are a fat struct in a handle pool** (#3). It's the best fit for an editor
   first, combinations are free, hot reload is trivial, and it's the easiest to understand. The
   friend's modeler shows it carries a full feature set.
2. **High-count, single-purpose data gets its own tables** (#5): particles, debug lines, draw
   commands, physics contacts. They're not entities.
3. **Tagged unions inside entities** (#4) where data is truly one-of: a light's type-specific
   settings, a parametric shape's recipe, undo commands.
4. **Split hot fields into SoA arrays only when profiling shows a loop is hot.** For example,
   world transforms computed into a flat array each frame (which we'd do anyway for rendering).
5. **Revisit at phase 3.** If gameplay needs tens of thousands of interacting entities, the
   escape route is sparse component stores (#6) for the hot systems, keeping the fat struct for
   editor-facing objects.
6. **Optional learning project:** build a small archetype ECS (#7) as a side experiment, to
   understand it, not to depend on.

### The strongest argument against this recommendation

A fat struct makes it easy to keep adding fields "just for this one feature". In a few months
`Entity` could have 80 fields and be read everywhere without checking flags. The defense is
discipline, written into the style guide:
- every optional field is grouped under a flag;
- large data goes behind handles;
- the struct's size is checked with `#assert(size_of(Entity) <= N)` so growth is a deliberate
  decision.

If that discipline sounds unlikely to hold, sparse components (#6) enforce the separation
structurally, at the cost of more code.
