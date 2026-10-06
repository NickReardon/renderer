# CLAUDE.md

A 3D modeler that grows into a small game engine, written in **Odin** with **SDL3** (platform)
and **wgpu** (graphics). It targets Windows, macOS and Linux natively, and the web later. It is
also a learning project: the owner wants to understand data-oriented, procedural and
immediate-mode design, so code must be easy to read and every non-obvious decision explained.

Read `docs/STYLE.md` for the full rules and reasoning, `docs/DESIGN.md` for past decisions, and
`docs/REFERENCES.md` for sources.

## Build and run (Windows)

```
build.bat          full build: build\engine.exe + build\game.dll, copies SDL3.dll and wgpu_native.dll
build.bat game     rebuild only game.dll; a running engine hot-reloads it (shaders included)
build.bat test     run the core tests
build.bat run      full build, then start the engine
```

- Odin: `dev-2026-09`, at `%LOCALAPPDATA%\Programs\odin` (the script finds it even when it isn't
  on PATH). Uses the MSVC linker from Visual Studio.
- From the Bash tool, run `cmd //c "D:\\Renderer\\build.bat game"`. A relative `build.bat`
  isn't found from there.
- **Verify a change in the running engine:** start `build\engine.exe` with stdout and stderr
  redirected to files, rebuild, then read the logs. wgpu validation and shader errors go to
  stderr. F6 forces a full game restart.
- macOS and Linux build scripts don't exist yet.

## Conventions

- **Coordinates: right-handed, X horizontal (right), Y vertical (up), Z depth (+Z toward the
  viewer, camera forward = -Z).** Use `core.WORLD_RIGHT`, `core.WORLD_UP`, `core.WORLD_FORWARD`;
  don't hard-code axes. Axis colors: X red, Y green, Z blue.
- **Reverse-Z depth:** the near plane is depth 1, clear depth to 0, compare `.Greater`.
- **Editor UX follows Unity's scene view:**
  - navigation: Alt+left orbit, middle pan, Alt+right or wheel zoom, right-drag fly with
    WASD/QE, F to frame;
  - transform gizmos (move, rotate, scale handles) and the QWERTY tool keys when the editor
    gets them;
  - all of it in our right-handed, Y-up space.

## Package layout

```
src/platform/  plain shared types (Input, Native_Window); no procedures, importable by all
src/host/      executable: SDL3 window, input, main loop, hot reload; only package using SDL
src/game/      editor + game, hot-reloaded DLL; all persistent state in Game_Memory
src/render/    renderer; only package using wgpu (render.odin API, device.odin, pipelines.odin, shaders/)
src/core/      math and mesh; imports no engine package, no GPU or OS code; tests in core_test.odin
```

The host passes OS window handles (`platform.Native_Window`) to the game, and `render/` builds
the wgpu surface from them. That keeps SDL out of the renderer and wgpu out of the host.

## Hard rules

1. **No wgpu types or calls outside `src/render/`. No SDL calls outside `src/host/`.**
2. **`src/core/` imports no engine package**, no GPU or OS code. It must stay testable alone.
   `src/platform/` holds only plain data types and may be imported by any package.
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
   **Explicit full-word names, never short symbols:** `renderer` not `r`, `face_index` not `f`,
   `delta_seconds` not `dt`, including loop variables, callback parameters and WGSL. Only vector
   components (`.x`, `.rgb`) and domain words (`uv`, `gpu`) are exempt.
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
- **Don't set an environment variable named `ODIN_ROOT` in scripts.** Odin reads it and
  fails with "Invalid ODIN_ROOT".
- **Batch files must have CRLF line endings,** or `goto` labels can break (`.gitattributes`
  enforces this).
- **Untyped float constants default to `f64`** when assigned with `:=`. Declare `f32`
  explicitly when the value is mixed with `[3]f32` math.
- **Appending to `#soa[dynamic]T` needs a typed literal:** `append(&ps, Particle{...})`.
- **Odin only ships Windows binaries** for SDL3 and wgpu. macOS and Linux need SDL3 from the
  system package manager and wgpu-native v29.0.1.1 from GitHub.
