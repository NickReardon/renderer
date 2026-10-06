# CLAUDE.md

A 3D modeler that grows into a small game engine, written in **Odin** with **SDL3** (platform)
and **wgpu** (graphics). It targets Windows, macOS and Linux natively, and the web later. It is
also a learning project: the owner wants to understand data-oriented, procedural and
immediate-mode design, so code must be easy to read and every non-obvious decision explained.

Read `docs/STYLE.md` for the full rules and reasoning, `docs/DESIGN.md` for past decisions, and
`docs/REFERENCES.md` for sources.

## Build and run

*Not created yet; the project skeleton is the next milestone. Update this section when it lands.*

- Odin: `dev-2026-09`, at `%LOCALAPPDATA%\Programs\odin` (on PATH). Uses the MSVC linker from
  Visual Studio.
- Planned: `build.bat` builds the host exe and game DLL; `build.bat game` rebuilds only the DLL
  for hot reload; `odin test src/core` runs the core tests.

## Hard rules

1. **No wgpu types or calls outside `src/render/`. No SDL calls outside `src/host/`.**
2. **`src/core/` imports no engine package**, no GPU or OS code. It must stay testable alone.
3. **Plain structs and procedures.** No proc fields used as virtual methods, no inheritance
   emulation, no "manager" objects that own behavior.
4. **Handles (`index` + `generation`) between systems, not pointers.** Never keep a pointer into
   a `[dynamic]` array across appends.
5. **Memory by lifetime:**
   - per-frame scratch uses `context.temp_allocator` (freed every frame);
   - procedures returning allocations take `allocator := context.allocator`;
   - no allocation in per-frame hot paths.
6. **Meshes use flat struct-of-arrays layouts** (`positions`, `face_offsets`, `corner_verts`,
   per-corner attributes). Never `[dynamic][dynamic]` per face.
7. **Immediate-mode APIs** for UI and debug drawing; **draw lists** of plain structs for the
   renderer.
8. **Hot reload safety:**
   - all persistent state lives in `Game_Memory`;
   - never store procedure pointers (including allocators made inside the DLL) in persistent
     state;
   - changing `Game_Memory`'s layout needs a full restart.
9. **Naming:** `Ada_Case` types and enum members, `snake_case` procedures and variables,
   `SCREAMING_SNAKE_CASE` constants, `verb_noun` procedures, no package-name prefixes.
10. **Long, linear procedures are fine.** Extract helpers only when code repeats.
11. **Assertions (moderate):**
    - assert preconditions and invariants in `core/` and `render/`;
    - use `ensure` (always on) where continuing would corrupt data;
    - use fixed capacities for per-frame arrays;
    - never crash on user data.

## How to work

- **Build before saying a change is done,** and run `odin test src/core` when `core/` changed.
  Report failures honestly, with the output.
- **Every new operation in `core/` gets tests first** (exact values or properties such as
  "closed mesh stays closed").
- **Ask before adding any dependency,** including another `vendor:` package.
- **End each change with a short explanation** of why it is built the way it is, aimed at someone
  learning these techniques. Record real design decisions (choices between alternatives) in
  `docs/DESIGN.md`.
- **Keep changes to one milestone at a time;** don't build ahead of what was asked.
- **Cite sources** in comments for non-obvious algorithms (see `docs/REFERENCES.md`).
- **Entity model: hybrid fat struct** (`docs/STYLE.md` §15):
  - one `Entity` struct in a fixed pool with `Entity_Handle { index, generation }`; slot 0 is
    the nil entity;
  - every optional field belongs to an `Entity_Flag` and is only read when its flag is set;
  - meshes and other large or shared data live behind handles, never inline;
  - `#assert(size_of(Entity) <= ENTITY_SIZE_BUDGET)` (512); don't raise it without recording
    why in `DESIGN.md`;
  - particles, draw commands and similar high-count data are separate tables, not entities.

## Known problems (Odin dev-2026-09, wgpu-native v29)

- **wgpu `CreateInstance(nil)` crashes on this machine** when every backend is enabled. Always
  pass `InstanceExtras{sType = .InstanceExtras, backends = wgpu.InstanceBackendFlags_Primary}`
  (D3D12, Vulkan, Metal).
- **Build with `-define:WGPU_SHARED=true`** so the host and the game DLL share one
  `wgpu_native.dll`. Statically linking wgpu into the hot-reloaded DLL would duplicate its
  state. Copy `wgpu_native.dll` and `SDL3.dll` next to the exe.
- **The wgpu bindings use the v29 API:**
  - `StringView` is an Odin `string`;
  - adapter and device requests take a `*CallbackInfo` struct with a `proc "c"` callback, and
    you call `InstanceProcessEvents` until it fires;
  - set up uncaptured errors through `DeviceDescriptor.uncapturedErrorCallbackInfo`.

  Check `vendor/wgpu/wgpu.odin` and https://github.com/odin-lang/examples/tree/master/wgpu
  rather than older wgpu tutorials.
- **`sdl.Init` returns a bool that must be used:** `if !sdl.Init({.VIDEO}) do ...`.
- **Appending to `#soa[dynamic]T` needs a typed literal:** `append(&ps, Particle{...})`.
- **Odin only ships Windows binaries** for SDL3 and wgpu. macOS and Linux need SDL3 from the
  system package manager and wgpu-native v29.0.1.1 from GitHub.
