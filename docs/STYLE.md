# Style Guide

How code in this engine is written, and why. The short, enforceable version for Claude is in
`CLAUDE.md`; this file has the reasoning. Sources are in `docs/REFERENCES.md`.

## 1. Principles

1. **Data first.** A program transforms data. Decide what the data is, how much of it there is,
   and how it is accessed, then write the code that transforms it. (Acton, Fabian)
2. **Concrete before abstract.** Write the specific code first. Pull out a procedure or type only
   after the same thing appears two or three times. (Muratori, *Semantic Compression*)
3. **No hidden work.** Allocation, I/O, GPU calls and expensive loops should be visible at the
   call site. Nothing happens "automatically" in a constructor, destructor or property.
4. **Many at once.** Write procedures that process arrays of things, not one thing per call
   behind a virtual interface.
5. **Measure.** Performance claims come from the profiler or a back-of-envelope estimate, not
   intuition. (TigerStyle)

## 2. Naming

These follow the Odin core library.

| Kind | Convention | Example |
|---|---|---|
| Types (structs, enums, unions, distinct) | `Ada_Case` | `Mesh`, `Draw_Command`, `Mesh_Handle` |
| Enum members | `Ada_Case` | `.Vertex_Mode`, `.Out_Of_Memory` |
| Procedures, variables, fields | `snake_case` | `build_render_mesh`, `face_count` |
| Constants | `SCREAMING_SNAKE_CASE` | `MAX_DRAWS`, `GRID_SIZE` |
| Packages | short lowercase | `core`, `render`, `ui` |

- **Explicit names, no short symbols.** Every variable, parameter, field and procedure name is
  written out in full words:
  - `renderer` not `r`, `camera` not `cam`, `position` not `pos`, `direction` not `dir`,
    `normal` not `n`, `delta_seconds` not `dt`, `properties` not `props`;
  - this includes loop variables (`for face_index in 0 ..< face_count(mesh)`, not `for f`),
    callback parameters, `switch` bindings and test parameters (`test: ^testing.T`);
  - the exceptions are vector components (`.x`, `.rgb`), established domain terms used as
    words (`uv`, `gpu`, `rgb`, `sdl`), and package names chosen by their authors (`linalg`).
- **Procedures are `verb_noun`:** `create_mesh`, `submit_frame`, `extrude_faces`.
- **Don't repeat the package name:** `render.create_mesh`, not `render.render_create_mesh`.
- **Put units in names when ambiguous:** `dt_seconds`, `width_px`, `angle_rad`.
- **Be consistent with indices and counts:** `vertex_index`, `vertex_count`, `face_offsets`.
  A `count` is a number of items; a `size` is a number of bytes.

## 3. Data layout

- **Plain structs and procedures.** No proc fields used as virtual methods, no "manager" types
  that own behavior, no inheritance emulation through `using`.
- **Arrays are the default container.** A fixed array (`[N]T`) when the bound is known, a slice
  for views, a `[dynamic]T` when it must grow.
- **Struct-of-arrays (`#soa`)** for data that hot loops touch one field at a time across many
  items, such as particles, transforms or vertex positions. Array-of-structs is fine everywhere
  else; don't change layout without a reason.
- **Use the language's data tools:**
  - `bit_set` for flags;
  - enumerated arrays (`[Kind]T`) for per-kind tables;
  - `distinct` for handles and indices so they can't be mixed up;
  - tagged `union` only when the variants really have nothing in common.
- **Separate hot and cold data.** Data read every frame (transforms, flags) doesn't share a
  struct with data read rarely (names, file paths, editor-only settings).
- **Meshes use flat layouts** (Blender's struct-of-arrays model): `positions`, `face_offsets`,
  `corner_verts`, with optional per-corner attributes. No per-face heap allocations.

## 4. References between things

- **Handles, not pointers,** for anything that refers to another system's data across frames:
  `Mesh_Handle :: struct { index: u32, generation: u32 }`. A stale handle fails a check instead of
  reading freed memory. (Weissflog)
- **Pointers are fine inside a procedure** and as parameters.
- **Never keep a pointer into a `[dynamic]` array** past the next append; the array can move.
- **No owning graphs of pointers** (parent/child pointer trees). Hierarchies are arrays with
  parent indices or handles.

## 5. Memory

Allocation is grouped by lifetime, not done one object at a time. (Fleury, gingerBill)

| Lifetime | Allocator | Example |
|---|---|---|
| Whole program | `context.allocator` or a permanent arena | GPU device, renderer state |
| Scene or level | A scene arena, reset or freed when the scene unloads | Loaded meshes, entities |
| One frame | `context.temp_allocator`, freed with `free_all` at end of frame | Draw lists, UI layout, scratch |

- **A procedure that returns allocated memory takes an allocator parameter:**
  ```odin
  triangulate :: proc(mesh: Mesh, allocator := context.allocator) -> []u32 {
  	indices := make([dynamic]u32, 0, len(mesh.corner_verts), allocator)
  	// ...
  	return indices[:]
  }
  ```
- **No allocation in per-frame hot paths** except from the temp allocator.
- **Every `make` has an obvious owner and matching `delete`/`free_all`.** Use `defer` for
  procedure-local cleanup.

## 6. Procedures

- **Long and linear is fine.** A frame step or tool operation can be one long procedure that
  reads top to bottom with commented sections. Extract a helper when code repeats, or when a
  piece has a clear name and is reused, not just to shorten a procedure. (Carmack, Muratori)
- **Explicit inputs and outputs.** Pass what a procedure needs; return what it produces. Avoid
  reaching into globals. Odin parameters are immutable and large ones are passed by reference
  automatically, so use `^T` only when the procedure mutates.
- **Multiple return values for results:** `(value, ok)` or `(value, Error)`, with `or_return`
  to propagate. No panics for expected failures such as a bad file or user input.
- **Process arrays.** Prefer `update_particles(particles: #soa[]Particle, dt: f32)` to
  `update_particle(p: ^Particle, dt: f32)` called in a loop.

## 7. Assertions and limits (moderate)

- **Assert preconditions and invariants** in `core/` and `render/`: valid handles, indices in
  range, matching array lengths, non-degenerate inputs. An assertion documents an assumption
  and catches the bug where it starts.
- **`assert` for debug-only checks; `ensure` for checks that must stay on.** `assert` is removed
  by `-disable-assert`; `ensure` always runs. Use `ensure` where continuing would corrupt data,
  for example a handle generation mismatch on a write.
- **Use fixed capacities for per-frame data** (`MAX_DRAWS`, `MAX_DEBUG_LINES`) and handle
  overflow explicitly: assert in debug builds, drop and count in release.
- **Growable arrays are fine** in editor, tool and asset-loading code.
- **Never crash on user data.** Bad files and impossible operations return errors and are shown
  in the editor.

## 8. Packages and dependencies

```
src/platform/  plain data shared by host and game (Input, Native_Window)
src/host/      executable: SDL3 window, input, main loop, hot reload; the only package that touches SDL
src/game/      editor + game; hot-reloaded DLL
src/core/      math, mesh, geometry operations; imports no engine package, no GPU, no OS
src/render/    renderer; the only package that touches wgpu
src/ui/        immediate-mode UI (our widgets on Clay layout + fontstash text)
src/third_party/  vendored third-party code, unmodified (Clay)
```

- **Imports flow one way:** `game → ui, render, core, platform`; `ui → render, platform`;
  `render → core, platform`;
  `host → platform`; `core →` nothing in the engine. `host` doesn't import `game`; it loads
  it as a DLL.
- **No wgpu types outside `render/`. No SDL calls outside `host/`.** These boundaries are what
  let us swap backends (SDL_GPU, raw Vulkan or Metal, a web host) later.
- **Ask before adding dependencies,** including other `vendor:` packages.

## 9. APIs in immediate mode

- **UI and debug drawing are immediate mode:** call `ui.button(...)` or
  `render.debug_line(a, b, color)` every frame; nothing is registered or retained by the caller.
- **The renderer takes a draw list:** the engine appends plain `Draw` structs each frame; the
  renderer sorts them by key and submits. (Ericson)

## 10. Hot reload rules

- **All persistent state lives in one `Game_Memory` struct** allocated by the game and handed
  back by the host after each reload. The game package has no other globals that must survive a
  reload.
- **Never store procedure pointers in persistent state;** they point into the old DLL. This
  includes allocators created inside the game DLL. The host keeps old DLLs loaded so existing
  pointers stay valid, but new code shouldn't depend on that.
- **Changing the layout of `Game_Memory` requires a full restart.** The host compares a hash
  of its layout (`core.type_layout_hash`) and restarts the game instead of reloading it when
  the hash changes. After changing a field's meaning but not its type, press F6.

## 11. Comments

- **Explain why, not what.** The code says what.
- **Start each file with a short header** describing its data layout and invariants.
- **Cite sources** for non-obvious algorithms: `// Möller–Trumbore ray/triangle, see REFERENCES.md`.

## 12. Formatting

- Tabs for indentation, as in the Odin core library; aim for lines under about 100 characters.
- Align related assignments and struct fields when it helps reading tables of data.

## 13. Testing

- **Every operation in `core/` has tests** (`odin test src/core`) before the editor uses it.
- **Prefer exact and property-based checks:** known volumes and areas, "closed mesh stays
  closed", "face count after subdivision", round-trips through save and load.
- Your friend's Modeler3D test cases are a source of expected values for ported operations.

## 14. Performance

- **Profile before optimizing.** Use the built-in profiler (to be added) or `core:prof/spall`.
- **For hot paths, write the estimate first:** how many items, how many bytes touched, the
  expected time.

## 15. Entities: hybrid fat struct

Chosen model; the comparison is in `docs/ENTITIES.md`.

- **One `Entity` struct holds every field any scene object may need.** Entities live in a
  fixed-capacity pool and are referred to by `Entity_Handle { index, generation }`.
- **Slot 0 is the nil entity.** A zeroed handle is invalid, so "no entity" needs no special
  value, and looking up a stale or zero handle returns a pointer to the nil slot instead of
  crashing.
- **Optional features are grouped under flags.** Every field that only applies to some entities
  belongs to a feature flag in `bit_set[Entity_Flag]` (`.Has_Mesh`, `.Has_Light`, …). Code
  checks the flag before reading the field. Comment which flag each field belongs to.
- **Object and data are separate** (Blender's model). Large or shareable data lives in other
  storage behind handles: `mesh: Mesh_Handle`, not the mesh itself. Many entities can share one
  mesh.
- **Size budget:** `#assert(size_of(Entity) <= ENTITY_SIZE_BUDGET)`, starting at 512 bytes.
  Raising the budget is a deliberate decision recorded in `DESIGN.md`.
- **Data that's truly one-of uses a tagged union inside the entity**, e.g. a light's
  type-specific settings, or a parametric shape's recipe.
- **High-count, single-purpose data is not entities:** particles, debug lines, draw commands
  and contacts get their own tables (often `#soa`).
- **Hot fields move to SoA arrays only when profiling shows the loop matters,** indexed by the
  same entity slot. World transforms, computed each frame into a flat array, are the expected
  first case.
- **If the project ever outgrows this,** keep `Entity` as the editor/authoring model and generate
  runtime tables from it, as Unity, Godot and Blender separate authoring from runtime data.
