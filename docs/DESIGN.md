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

## Coordinate system: right-handed, Y up, Z depth

- **Chosen:** X horizontal (right), Y vertical (up), Z depth, right-handed, so +Z points toward
  the viewer and a camera looks down -Z. Same as Maya, Godot and OpenGL conventions. Axis colors
  X red, Y green, Z blue. Constants: `core.WORLD_RIGHT`, `core.WORLD_UP`, `core.WORLD_FORWARD`.
- **Alternatives:** Z up (Blender, Unreal, 3ds Max); left-handed Y up (Unity, D3D tradition).
- **Why:** the owner's choice. Y-up matches how screen space reads (x across, y up) and most
  game and graphics references. Right-handedness matches the cross-product and winding
  conventions used throughout the math (counter-clockwise = front-facing).
- **Enforced by:** `test_coordinate_system_is_right_handed` in `core_test.odin`.

## Depth: reverse-Z, infinite far plane, 32-bit float

- **Chosen:** clip depth 1 at the near plane falling to 0 at infinity; `Depth32Float`; clear to
  0; compare `.Greater`.
- **Why:** float precision is concentrated near 0, and the perspective divide needs it far away;
  reversing the range cancels the two out, so there's almost no z-fighting at distance and no far
  plane to tune (Nathan Reed, *Depth Precision Visualized*).

## Editor UX: Unity scene-view style

- **Chosen:** Unity's scene-view navigation (Alt+left orbit, middle pan, Alt+right or wheel zoom,
  right-drag flythrough with WASD/QE, F to frame) and, when the editor gets them, Unity-style
  transform gizmos and QWERTY tool keys. Applied in our right-handed, Y-up space; Unity itself is
  left-handed.
- **Alternatives:** Blender's keymap (middle-mouse orbit, G/R/S modal transforms), Maya's.
- **Why:** the owner's preference. A Blender keymap can be added later as a second preset; the
  reference Modeler3D supports both.

## Hot reload: host executable + game DLL

- **Chosen:**
  - `engine.exe` (host) owns the window and main loop, and loads `game.dll`;
  - each build replaces `game.dll`, and the host loads a *copy* (`game_<n>.dll`) so the file
    stays writable;
  - persistent state is one `Game_Memory` block passed to each new DLL;
  - if `size_of(Game_Memory)` changes, the game restarts instead (F6 forces a restart);
  - old DLLs stay loaded until exit;
  - shaders are embedded in the DLL with `#load` and rebuilt on reload inside a validation
    error scope, so a broken shader reports its error and the last working pipelines stay.
- **Details that matter:**
  - game procedures run with the host's `context`, so allocators live in the never-unloaded exe;
  - wgpu is linked as a shared library (`WGPU_SHARED`) so every DLL copy uses the same wgpu
    state;
  - the build writes `game_tmp.dll` and renames it, so the host never sees a half-written file;
  - a unique PDB name per build avoids link failures while a previous build is loaded.
- **Known limit:** a change that keeps `Game_Memory`'s size but changes its layout (e.g. swapping
  two fields of the same type) is not detected; press F6.
- **Verified:** reloading with unchanged code, with a deliberately broken shader (error printed
  with the right file line, old pipelines kept) and with the fix, all while the engine ran.

## Window to GPU surface: native handles in `platform`

- **Chosen:** the host turns SDL's window properties into a `platform.Native_Window` (Win32
  HWND/HINSTANCE, CAMetalLayer, Xlib, Wayland); `render.init` creates the wgpu surface from it.
- **Rejected:** Odin's `wgpu/sdl3glue`, which would put SDL calls in the renderer (or wgpu calls
  in the host).
- **Why:** keeps both boundary rules (SDL only in `host/`, wgpu only in `render/`). A web host
  would add a canvas variant.

## Mesh drawing: sorted draw list + instancing from a storage buffer

- **Chosen:**
  - the frame's draws are sorted by a 64-bit key (mesh slot in the high bits);
  - per-draw data (world matrix, normal matrix, color) is written to one storage buffer;
  - each run of draws with the same mesh is one `DrawIndexed` with `instanceCount` = run
    length and `firstInstance` = run start; the vertex shader indexes the storage buffer with
    `instance_index`.
- **Alternatives:** a uniform buffer with dynamic offsets per draw (one draw call per object).
- **Why:** one upload per frame and one draw call per unique mesh. The sort key grows later
  (pass, material, depth) without changing the loop.
- **Mesh vertex data is struct-of-arrays on the GPU too:** positions and normals are separate
  vertex buffers.

## UI: our own immediate-mode widgets on Clay's layout

- **Chosen:**
  - `src/ui/` is our own immediate-mode UI;
  - **Clay** computes layout (sizing, padding, scrolling, floating elements);
  - **fontstash** (bundled with Odin) produces glyphs;
  - widgets, interaction state and text editing are ours;
  - output goes to the renderer's 2D overlay;
  - nothing outside `src/ui/` calls Clay or fontstash.
- **Alternatives:**
  - microui: bundled and readable, but manual row layout and a plain look;
  - Dear ImGui: complete (docking, ImGuizmo), but a large C++ dependency we wouldn't understand
    or own;
  - Nuklear: no maintained Odin bindings;
  - ARC: not publicly available;
  - writing our own layout too: possible later, and the boundary allows it.
- **Precedents:**
  - Blender's UI is the closest model: an immediate-mode description each redraw, automatic
    layout, and state matched by widget identity;
  - Godot uses retained nodes;
  - the reference Modeler3D has a 635-line hand-made immediate-mode UI with manual rectangles.
- **How it works:**
  - widgets are identified by Clay ids hashed from labels relative to their parent element;
  - the UI keeps only `active_id` (mouse), `edit_id` (keyboard) and drag state between frames;
  - hit testing uses the previous frame's layout (inherent to auto-layout immediate mode);
  - containers are `if` blocks closed by `@(deferred_none)`.
- **Hot reload:** Clay is statically linked into the game DLL, so each reload gets fresh Clay
  globals; `ui.on_hot_reload` restores the context and the text-measure callback. Verified with
  a capture taken after a reload.
- **Tests:** `src/ui/ui_test.odin` drives real frames with simulated input:
  - click to edit, type, Enter, Escape;
  - drag a number field;
  - toggle a checkbox;
  - button click, and dragging off a button to cancel;
  - mouse routing between viewport and panel.

## Text: fontstash + stb_truetype now, kb_text_shape later

- **Chosen:**
  - fontstash rasterizes glyphs on demand into a single-channel atlas (1024², grows as needed);
  - fonts are Inter (UI) and JetBrains Mono (numbers), SIL Open Font License, embedded with
    `#load` and copied to the heap at startup;
  - the renderer uploads only the atlas region that changed.
- **Limit:** no shaping. Latin, Greek, Cyrillic and CJK (with a fallback font) work; Arabic,
  Indic scripts and right-to-left text don't.
- **Upgrade path:** `vendor:kb_text_shape` (bundled) for segmentation, bidi and shaping, plus our
  own glyph-ID cache rasterized with stb_truetype. All text goes through `measure_text` and
  `draw_text` in `ui/text.odin`, so the upgrade stays in one file.
- **Not yet:** typing non-Latin text through an IME (SDL text editing events aren't forwarded);
  Clay wraps lines only at spaces.

## Renderer 2D overlay

- **Chosen:** an immediate-mode overlay API in `render/`:
  - `overlay_rect` (rounded, filled or outlined), `overlay_glyph`, `overlay_set_scissor`,
    `set_overlay_atlas`;
  - each quad is one 64-byte instance; one instanced draw per scissor batch;
  - rounded corners and borders come from a signed distance function in the fragment shader,
    so they're anti-aliased at any size with no extra geometry;
  - colors are sRGB as authored and converted to linear in the shader.
- **Why:** the UI (and later in-game HUDs and gizmo labels) needs only boxes and text; keeping
  the API to plain quads means the renderer knows nothing about widgets.
- **3D viewport:** the camera carries a viewport rectangle (the UI's `Viewport` area), so the
  scene renders beside the panel instead of under it.

## Frame capture for verification

- **Chosen:**
  - `engine.exe --screenshot` (or `--screenshot-after-reload`) copies the swapchain image to a
    buffer, maps it, writes `screenshot.bmp` with `core:image/bmp`, and exits;
  - the surface is configured with `CopySrc` when it supports it.
- **Why:** capturing the desktop was unreliable (the window may be behind others) and could
  record unrelated windows. Reading the frame back is exact and needs no new dependency.

## Frame pacing

- **Current:**
  - presentation is vsync (`PresentMode.Fifo`), so the frame rate follows the display refresh
    (60 Hz on the development laptop at the time of measuring);
  - simulation uses the variable frame time.
- **Planned:** a fixed simulation step with interpolated rendering (*Fix Your Timestep*) in the
  engine phase; possibly an uncapped present mode (Mailbox or Immediate) toggle for profiling.

## Render resolution: fixed or dynamic, 50–200%, FSR 1 below native, supersampling above

- **Chosen:**
  - one render scale controls the scene's resolution relative to the viewport. **Fixed mode**
    uses a set scale. **Dynamic mode** moves it between a minimum and maximum (default 50–200%)
    to keep GPU time within the target frame rate's budget (default: the display's refresh
    rate);
  - below 100%, **AMD FSR 1** upscales: EASU (edge-adaptive upsampling) then RCAS
    (contrast-adaptive sharpening), ported from `ffx_fsr1.h` (MIT) to WGSL in
    `shaders/post.wgsl`. Bilinear upscaling is available for comparison;
  - above 100%, **supersampling**: the scene renders larger and a bilinear pass filters it down
    in linear light (an exact 2×2 average at 200%);
  - the UI is always drawn at native resolution, after scaling.
- **How it's built:**
  - scene color and depth targets are allocated once at the window size × 2 and the scene
    renders into a sub-rectangle, so changing the scale never reallocates (as Unreal and
    console engines do);
  - the scene texture is sRGB with an RGBA8Unorm view of the same bytes: rendering and bilinear
    sampling go through the sRGB view (linear values), while FSR reads the encoded values it
    expects through the other view;
  - **GPU timing** uses timestamp queries (the first pass's start, the window pass's end), read
    back asynchronously through a ring of 4 buffers, so measuring never stalls. CPU frame time
    is useless here: with vsync it's always about one refresh interval;
  - **the controller** (`core.next_render_scale`, unit-tested) aims for 90% of the budget,
    ignores errors within ±6%, drops at most 15% and rises at most 5% per adjustment, snaps
    to 2.5% steps, and adjusts every 8 frames. It assumes GPU cost grows with scale squared.
- **Precedents:** Unreal's screen percentage and dynamic resolution; Unity's dynamic resolution.
  Usually dynamic resolution only goes down to native, and supersampling is a separate fixed
  setting. Here both modes cover the full range, by the owner's choice, which makes
  performance scaling easy to test.
- **Known limits:**
  - FSR 1 needs anti-aliased input. With no anti-aliasing yet, it upscales stair-steps
    (sharper than bilinear, but 2-pixel steps at 50%). Adding MSAA or TAA is the next step for
    image quality;
  - temporal upscaling (FSR 2/3-style) needs motion vectors and camera jitter, and is a later
    project;
  - EASU may sample one texel beyond the rendered area at its right and bottom edges (the
    cleared color); not visible in practice so far.
- **Verified:**
  - captures at 100%, FSR 50%, bilinear 50% and 200% show the expected differences (zoomed
    comparison);
  - dynamic mode climbed to 200% when far under budget and dropped to 50% with an unreachable
    5000 fps target;
  - hot reload with FSR active works.
- **Also added:** a VSync toggle. Off uses Immediate, falling back to Mailbox if Immediate isn't
  supported.

## Anti-aliasing: 4x MSAA with a custom resolve

- **Chosen:** 4× MSAA on the scene (meshes, debug lines, grid), on by default, with a toggle.
- **Why MSAA first:**
  - it suits a forward renderer;
  - it smooths geometry edges at moderate cost;
  - it gives FSR 1 the anti-aliased input AMD requires: with MSAA, FSR 50% no longer shows
    2-pixel stair-steps.
- **Custom resolve instead of the hardware resolve:**
  - the scene renders into a sub-rectangle of larger targets (dynamic resolution);
  - a hardware resolve needs equal-sized source and destination and resolves the whole texture
    even at 50% scale;
  - `shaders/resolve.wgsl` instead averages each pixel's samples only over the rendered area,
    in linear light (it reads through the sRGB format, as a hardware resolve of an sRGB target
    does).
- **Memory:**
  - MSAA targets exist only while MSAA is on;
  - they grow in 256-pixel steps to the largest render size used, so dynamic resolution
    doesn't reallocate on every adjustment;
  - they're released when the window resizes or MSAA changes;
  - worst case (200% at 2448×1530) is about 3840×3072 × 4 samples × 8 bytes ≈ 380 MB.
- **Changing the sample count rebuilds the scene pipelines** (sample count is part of a
  pipeline).
- **Not covered:** aliasing *within* surfaces (shading, textures, thin geometry smaller than a
  sample). The grid is already anti-aliased analytically in its shader. **TAA** (with motion
  vectors and jitter) is the planned next step; it would also lay the groundwork for temporal
  upscaling (FSR 2-style).
- **Verified:** captures with no AA, MSAA, MSAA + FSR 50% and MSAA + 200% (zoomed comparison);
  dynamic mode climbing to 200% with MSAA on ran without errors.
- **Also:** in `--screenshot` modes the host now ignores real mouse and keyboard input. A capture
  once came out zoomed because someone scrolled while the window was open.

## Modeler, step 1: scene, picking, selection, Hierarchy, generated Inspector

- **Entities** (`game/scene.odin`), the hybrid fat struct as decided:
  - a fixed pool of 4096, slot 0 nil, generational handles;
  - flags `Alive`, `Selected`, `Has_Mesh`;
  - the transform is Euler degrees applied Z, X, Y (Unity's order);
  - names are stored inline in a fixed 48-byte buffer (no allocation, hot-reload safe);
  - `#assert(size_of(Entity) <= ENTITY_SIZE_BUDGET)` (512) holds.
- **Meshes are shared** (Blender's object/data split): `Mesh_Asset` holds the CPU `core.Mesh`
  (for picking, outlines and later editing), the GPU handle and local bounds. Primitives exist
  once and every cube points at the cube asset; the renderer batches them into one instanced
  draw. Primitive sizes match Unity's.
- **Selection is a flag on the entity,** not a separate list. The editor already walks the pool,
  and a flag can't refer to a deleted entity.
- **Picking:**
  - the mouse pixel becomes a world ray (`core.ray_from_viewport`) using the viewport rectangle
    from the last frame's layout, which is what was on screen when the click happened;
  - each mesh is tested in its own local space: the ray goes through the inverse world matrix,
    so t values stay comparable across scaled objects. First a bounding-box slab test, then
    Möller–Trumbore against each face's triangle fan;
  - a press counts as a click only if the mouse moves under 4 pixels.
- **Selection outline:** the selected objects' edges, drawn as orange debug lines pulled 0.2%
  toward the camera so they win the depth test. Unity draws a silhouette outline instead, which
  needs a post pass (stencil or object-ID buffer); planned later.
- **Generated Inspector** (`ui/inspector.odin`): `ui.inspect(state, pointer, type)` walks the
  struct's fields with `core:reflect` and draws a widget for each field tagged `inspect`, with
  `step`, `min`, `max`, `format` and `hint:"color"` tags. Adding a tagged field to `Entity` makes
  it editable with no UI code (Godot's ClassDB and Blender's RNA work the same way).
- **Unity conventions:**
  - layout: Hierarchy left, 3D view, Inspector right;
  - click, Shift+click (add) and Ctrl+click (toggle) selection;
  - Delete, Ctrl+D duplicate (copies become the selection), F frame selection;
  - new objects are named "Cube", "Cube (1)", …;
  - Escape clears the selection and **no longer quits** (closing the window does).
- **Verified:**
  - `--pick-center-of=Sphere` projects an object's centre with the renderer's matrices and
    clicks there through the normal path. The capture shows the sphere outlined, selected in
    the Hierarchy and shown in the Inspector, so picking and rendering agree;
  - tests for rays, boxes, triangles, meshes through transforms, the new primitives (closed,
    outward-facing, correct volumes), the vector field, selectable rows and the reflection
    inspector;
  - hot reload with a selection in place.
- **Not yet:** undo, renaming objects (needs a text field), multi-object editing in the
  Inspector, and an outline silhouette.
