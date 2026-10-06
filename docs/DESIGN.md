# Design Decisions

A log of choices made between real alternatives: what was chosen, what was rejected, and why.
Newest at the bottom. Add an entry whenever a decision would surprise someone reading the code.

---

## Language: Odin

- **Chosen:** Odin (`dev-2026-09`).
- **Alternatives:** Jai (not publicly available), C, C++, Zig.
- **Why:** built-in `#soa`, allocators and `context`, `bit_set`, enumerated arrays, `distinct`
  types and vector math suit data-oriented and procedural code. Bundled `vendor:` libraries
  (SDL3, wgpu, microui, cgltf, stb, miniaudio) mean no package manager.

## Platform layer: SDL3

- **Chosen:** SDL3, kept entirely inside `src/host/`.
- **Alternatives:** GLFW (no audio, weaker gamepads), sokol_app, our own Win32/Cocoa/X11 layer.
- **Why:** windows, input, gamepads and audio on all three desktop platforms. It is bundled with
  Odin, has a stable API, and is widely used. Writing our own platform layer stays possible
  later as a learning exercise, because nothing outside `host/` touches SDL.

## Graphics: wgpu

- **Chosen:** wgpu (wgpu-native v29 via `vendor:wgpu`), kept entirely inside `src/render/`.
- **Alternatives:**
  - SDL_GPU: stable and light, but needs offline shader cross-compilation and has no web
    support;
  - OpenGL: deprecated on macOS and stuck at 4.1;
  - sokol_gfx: older backends;
  - raw Vulkan, D3D12 or Metal: three times the work.
- **Why:**
  - native D3D12, Vulkan and Metal from one API;
  - WGSL shaders translated automatically, so no shader toolchain;
  - thorough validation errors, which help while learning;
  - a browser target.
- **Costs accepted:**
  - a large Rust dependency;
  - API changes between versions;
  - more CPU overhead per call than thinner APIs;
  - the default instance crashed on this machine, so we restrict it to the primary backends.
- **Escape hatch:** the engine talks to `render/` only through its own handles and draw lists,
  so another backend can replace wgpu without touching engine code.
- **Verified:** on Windows (Intel GPU), SDL3 + wgpu ran on both D3D12 and Vulkan.

## Renderer interface: handles + draw list

- **Chosen:** `render/` exposes handles (`Mesh_Handle`, `Material_Handle`, …), immediate-mode
  debug drawing, and a per-frame list of plain `Draw` structs with 64-bit sort keys.
- **Why:** keeps backend types out of engine code and makes batching and sorting a single
  pass over an array (Ericson, *Order your graphics draw calls around!*).

## Mesh layout: flat struct-of-arrays

- **Chosen:** `positions`, `face_offsets` (one per face, plus a final end offset),
  `corner_verts`, and optional per-corner arrays (UVs and so on), following Blender's mesh
  struct-of-arrays refactor.
- **Rejected:** `[dynamic][dynamic]int` faces (the reference C++ repo's
  `vector<vector<int>>`), which costs one heap allocation per face and chases pointers; and
  pointer-based half-edge structures.
- **Note:** adjacency (edges, vertex→face) is derived data, built on demand into arrays when
  an operation needs it.

## Entity model: hybrid fat struct

- **Chosen:** one `Entity` fat struct in a fixed pool with generational handles, with slot 0 as
  the nil entity. Optional fields are grouped under feature flags; large or shared data
  (meshes) lives behind handles, following Blender's Object/data split. High-count data
  (particles, draw commands) gets its own tables. Tagged unions are used inside the entity for
  one-of data. Hot fields are split into SoA arrays only when profiling demands it. Size budget
  `ENTITY_SIZE_BUDGET` = 512 bytes, enforced with `#assert`.
- **Alternatives:** inheritance, component objects (Unity/Godot style), tagged union per
  kind, table per kind, sparse components (Bitsquid/EnTT), archetype ECS (Unity DOTS,
  Unreal Mass, Bevy), property objects (Our Machinery's Truth). Full comparison in
  `docs/ENTITIES.md`.
- **Why:**
  - simplest model to understand and to write generic editor code against (inspector,
    undo, save/load, gizmo);
  - any combination of features works without new types;
  - trivially safe for hot reload;
  - fast enough for thousands of entities.
- **Evidence:** the reference Modeler3D uses this model for a full modeler. Blender
  separates objects from data the same way. Large engines (Unity, Unreal, Godot, Blender)
  separate an authoring model from a runtime model rather than make the editor model an ECS.
- **Main risk:** the struct grows into a junk drawer. Mitigated by flag grouping, handles for
  big data, and the size budget.
- **Revisit:** at phase 3, if gameplay needs tens of thousands of interacting entities. The
  escape route is to keep `Entity` as the authoring model and generate sparse-component or
  archetype runtime tables from it.
