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
  - if `Game_Memory`'s layout changes, the game restarts instead (F6 forces a restart). Each
    build exports a hash of the layout (`game_memory_layout_hash`, built by
    `core.type_layout_hash` from Odin's runtime type info: field names, offsets and types,
    enum values, union variants, and everything reached through pointers, slices, dynamic
    arrays and maps), and the host compares the running build's hash with the new one's;
  - old DLLs stay loaded until exit;
  - shaders are embedded in the DLL with `#load` and rebuilt on reload inside a validation
    error scope, so a broken shader reports its error and the last working pipelines stay.
- **Details that matter:**
  - game procedures run with the host's `context`, so allocators live in the never-unloaded exe;
  - wgpu is linked as a shared library (`WGPU_SHARED`) so every DLL copy uses the same wgpu
    state;
  - the build writes `game_tmp.dll` and renames it, so the host never sees a half-written file;
  - a unique PDB name per build avoids link failures while a previous build is loaded.
- **Why a layout hash, not the size** (#13): the host used to compare `size_of(Game_Memory)`,
  which misses changes that keep the size (two fields swapped, an `f32` that became an `i32`,
  an enum reordered), and the new code then silently misread the old memory. The hash also
  changes when a field or type is only renamed: a needless restart loses editor state, a wrong
  reload corrupts it.
- **Known limits:** changes the type system can't see are not detected: a field whose meaning
  changes but not its type (degrees to radians), or bytes behind a `rawptr` or a `[]u8` buffer
  (Clay's arena). Press F6 after those.
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

## Input latency: frame pacing, one queued frame, D3D12 on Windows

- **Problem (feedback):** dragging with the gizmo, the object trailed the mouse cursor. The
  cursor is drawn by Windows with no delay, so any latency in our frames shows as a gap.
- **Measured** (60 Hz, Vulkan): each frame spent ~15 of its 16.7 ms blocked in
  `SurfaceGetCurrentTexture`. That wait comes after the frame has read input, so input was a
  whole refresh old before drawing started. wgpu also queues up to two presented frames. Total:
  roughly three refreshes (~50 ms) from mouse to screen.
- **Fix 1, pace the frame (`core/frame_pacing.odin`):** after presenting, sleep off most of
  the wait, *then* read input; the acquire only waits a small margin. The sleep is steered by
  feedback: every 30 frames, move it halfway toward leaving 2 ms for the shortest acquire wait
  seen; a frame that barely waits (< 0.3 ms, maybe a missed refresh) shortens it by 2 ms at
  once. The same idea as NVIDIA Reflex's or Unreal's frame delay. The host does the sleeping
  with `SDL_DelayPrecise` (high-resolution timers; Windows' plain `Sleep` can overshoot by
  15 ms and drop a frame); the game exports `game_frame_delay_milliseconds` for it.
- **Fix 2, one queued frame** (`desiredMaximumFrameLatency = 1`, wgpu's default is 2), saving a
  refresh.
- **Fix 3, D3D12 on Windows.** On the development laptop (hybrid graphics: the RTX 4070 renders,
  the AMD 780M drives the 60 Hz panel) Vulkan with one queued frame stopped waiting for vsync
  entirely: 354 fps on a 60 Hz display. With two queued it paced correctly. D3D12 paces
  correctly with one, and rendered identically. So the renderer asks for D3D12 first on Windows
  (any other backend if it's missing), and Vulkan keeps two queued frames.
- **Result** (same laptop, after settling): 60 fps; the frame sleeps ~10.5 ms and then waits ~4 ms
  for the display (the controller keeps the margin against the *worst* frame, so the typical
  wait is above 2 ms). Estimated mouse-to-screen latency about one refresh plus ~4 ms (~21 ms)
  instead of ~3 refreshes; this is an estimate from the timings, not a measurement with a camera.
- **Settings:** Rendering → "Low latency" (with VSync) turns the pacing off for comparison.
  Statistics show `sleep` and `wait`.
- **Tests (`core/frame_pacing_test.odin`):** with a simple vsync model, the delay settles with
  the margin left; it backs off at once when a frame gets slower, then resettles; it never goes
  negative.
- **Not done:** reading input even later (late-latching the camera/gizmo transform on the GPU),
  and measuring real latency (a high-speed camera or an LDAT-style sensor).

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
- **Not yet:** renaming objects (done later, see "Renaming objects"), multi-object editing in the
  Inspector, and an outline silhouette.

## Review fixes (external review of 2b2380a)

An outside review found eight bugs; all were confirmed in the code and fixed:

1. **A rejected game DLL blocked hot reload.** A library missing exports stayed loaded, which
   locked its copy, so every retry failed. Now it's unloaded and deleted, the version number
   moves on, and the same `game.dll` isn't retried until it changes. Verified live: a DLL with no
   game exports produced one rejection, then a real build reloaded normally.
2. **Mirrored transforms lost their outside.** Negative scale reverses winding, so back-face
   culling removed the visible faces. Draws now record `mirrored` (negative
   `core.linear_determinant`); mirrored draws sort after the rest and use a second mesh
   pipeline with clockwise front faces.
3. **Zero scale broke normals and picking.** Normal matrices now come from
   `core.normal_matrix`, built from cofactors (no division, finite at zero scale, sign-corrected
   for mirroring); the mesh shader guards zero-length normals; picking skips transforms with a
   zero determinant.
4. **FSR read past the rendered region.** EASU now loads its 12 taps per texel, clamped to the
   rendered sub-rectangle, instead of four gathers clamped by the sampler at the (larger)
   texture's edge.
5. **A failed MSAA rebuild left pipelines and targets disagreeing.** The new sample count is
   kept only if the pipelines rebuild; otherwise the old count stays and the failed request
   isn't retried until shaders build again.
6. **Frame Selection cropped objects in narrow viewports.** `core.distance_to_fit_sphere` uses
   the narrower of the vertical and horizontal fields of view.
7. **Long numbers pushed vector fields past the panel.** Number boxes clip their text. The fix
   exposed a second bug: nested clip regions (a scrolling panel holding clipped boxes) reset to
   the whole window when the inner one ended. `ui.end_frame` now keeps a scissor stack.
8. **Repeated duplication could produce identical names.** Candidates are now built to fit the
   48-byte buffer before uniqueness is checked (truncating on UTF-8 boundaries), and an existing
   " (N)" suffix is replaced rather than nested, as Unity does.

**New tests:** `test_normal_matrix`, `test_distance_to_fit_sphere`, the UI overflow check, and
`src/game/scene_test.odin` (entity handles, unique names). The game package now has tests;
`build.bat test` runs core, UI and game. Each new test was confirmed to fail without its fix.

## Modeler, step 2: transform gizmo (Unity's Q W E R)

- **Tools:** Q Hand (left-drag pans, no selection), W Move (arrows), E Rotate (rings), R Scale
  (per-axis handles plus a centre handle for uniform scale). Toolbar buttons over the 3D view
  mirror the keys, plus a Global/Local toggle for Move and Rotate (Scale always uses the
  object's own axes, as in Unity). Ctrl snaps (0.25 units, 15°, 0.1×). Escape during a drag
  cancels it. Hovered and dragged handles turn yellow.
- **Drawn as 2D overlay, hit-tested in screen space.** The gizmo is drawn on top of the scene at
  a constant size on screen (110 points), like Unity's. The overlay gained two shapes for it,
  both anti-aliased with signed distance functions: thick segments and filled triangles
  (arrowheads). Handles are picked by the distance from the mouse to their projected line or
  ring (9 points). Rotation rings draw their far halves faintly, then their near halves.
- **Dragging is solved in 3D:**
  - Move and per-axis Scale use the closest point between the mouse ray and the axis line
    (`core.closest_line_parameter_to_ray`);
  - Rotate measures the screen angle swept around the gizmo's centre, accumulated across ±180°,
    and signed by whether the axis faces the viewer (right-hand rule). This matches Unity's
    behaviour; the screen angle differs from the true angle when a ring is seen at a slant;
  - uniform scale is exponential in horizontal mouse movement (150 points doubles), so
    left and right are symmetric.
- **Every frame recomputes from the transforms saved at the press,** rather than adding
  increments. Nothing drifts, snapping is exact, and Escape restores the originals. Several
  selected objects rotate about their shared centre like a rigid group.
- **Euler angles stay continuous:** `core.euler_degrees_from_matrix_near` picks, among the angle
  triples for the same rotation, the one nearest the previous angles (Unity keeps a similar
  hint). Without it, turning past 90° about X showed e.g. (53°, 180°, 180°).
- **Input routing:**
  - the gizmo is updated before selection clicks, and a press on a handle never selects;
  - while dragging it reads unfiltered input, so the drag continues over panels and the
    release is never lost;
  - Alt+left stays orbiting.
- **Tests:**
  - core: Euler round trips (including gimbal lock and Unity's axis convention), the
    nearest-angles choice, and line/ray closest points;
  - game: Move by exactly one handle length on X only; drift-free return and Escape restore;
    rotation about Y only; X scale doubling exactly; uniform scale; hidden for the Hand tool
    and an empty selection;
  - UI: toolbar button clicks, and the toolbar taking the mouse.
- **Not yet:** plane handles (move on two axes at once), a screen-space rotation
  ring, Pivot/Center toggle, and scaling several objects' positions about their centre. (All
  added in step 4.)

## Modeler, step 3: undo and redo

- **Keys:** Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo (Unity on Windows). They work wherever the
  mouse is, but not while a field is being typed into or a drag is under way.
- **Chosen: diff the entity pool against a committed copy.** `Undo_History.committed` holds the
  pool as of the last step. Once per frame, when no edit is in progress (left button up, no
  gizmo drag, no text field active), `commit_undo_step` compares each live entity with its
  copy, byte for byte. The slots that differ become one step, storing the whole `Entity`
  before and after. Undo writes the befores back; redo writes the afters.
- **Alternatives:**
  - *command pattern* (one do/undo pair per operation): every edit path needs its own inverse,
    and the generated Inspector would need an undo hook per field type;
  - *explicit "record before change"* (Unity's `Undo.RecordObject`): no inverse code, but every
    edit site must remember to call it, and a forgotten call is a silent bug;
  - *whole-scene snapshots*: simplest, but about 0.5 MB per step for 4096 entities;
  - *versioned objects* (Our Machinery's The Truth): the most general, but it needs every edit
    to go through a property API.
- **Why:**
  - nothing that edits entities knows undo exists. The Inspector, the gizmo, Create, Delete and
    Ctrl+D needed no changes, and a new `inspect` field is undoable for free;
  - a step costs only the entities it touched, about 230 bytes each;
  - the comparison (at most 4096 × 116 bytes) costs microseconds a frame and allocates nothing.
  This works because the editor's data is a flat pool of plain structs (the fat-struct model
  promised this in `docs/ENTITIES.md`).
- **One step per gesture.** Nothing is committed while the left button is held or a field has
  the keyboard, so a whole gizmo or number-field drag becomes one step, recorded on release.
  Escape during a gizmo drag restores the transforms, so the release finds nothing to record.
  One exception: a number field applies typed text when the mouse is pressed elsewhere, so
  that edit is finished while the button is down, and the same press can go on to click a
  button or start a drag. `ui.typed_value_applied` reports it, and `game_update` records it as
  its own step right after the UI pass. (Found in review: typing a Position value and then
  clicking Create made one step, so Ctrl+Z removed the cube *and* reverted the value.)
- **Selection:** a change of selection alone doesn't make a step (Unity records selection
  changes too; the history then fills with clicks). A step does store each touched entity's
  selection, and applying a step selects exactly the touched entities that were selected on
  that side. Undoing a move reselects what moved; undoing Ctrl+D reselects the originals.
- **Handles survive undo.** A restored entity gets its old generation back, so a handle to a
  deleted entity works again after undoing the delete. To keep handles unique anyway,
  `Scene.slot_generations` remembers each slot's highest generation ever issued, and
  `create_entity` counts up from that rather than from the current entity's generation.
- **Memory:** fixed arrays in `Game_Memory` (256 steps, 8192 changed entities in total, about
  2.4 MB with the committed copy), so the history survives hot reload with no allocator. When
  full, the oldest steps are dropped. An edit touching more than 8192 entities isn't recorded;
  the history is cleared with a message, because older steps would no longer match the scene.
- **Not covered:** mesh assets (they're immutable and never freed today; mesh editing will
  need its own undo data), the camera, and render settings (Unity doesn't undo scene view
  navigation either). Steps have no names yet ("Undo Move"); the diff doesn't know which tool
  made a change.
- **Tests (`src/game/undo_test.odin`):** edit, undo, redo; selection-only changes; delete and
  undo keeping the handle, and generations never reused (fails without `slot_generations`);
  Ctrl+D undo reselecting the originals; a new edit ending the redo branch; dropping the
  oldest steps when full; a multi-frame gizmo drag committed as in `game_update` making one
  step.

## Modeler, step 4: plane handles, view ring, Pivot/Center

- **Plane handles (Move):** a square per pair of axes, coloured by the axis it faces (Unity's
  convention), spanning 0.12–0.38 of the handle length on both axes. Like Unity's, each square
  flips to the side of its axes that faces the camera, so it's never hidden behind the gizmo.
  A square seen within ~78° of edge-on (facing cosine below 0.2) is hidden: it would be a
  sliver, and the ray/plane hit would swing wildly with small mouse moves. Hit test: inside the
  projected quad, which wins over the axis lines bordering it. Drag: the mouse ray against the
  plane (`core.ray_plane_intersection`, new and tested), measured from where it hit at the
  press along the plane's two axes; Ctrl snaps each axis on its own. Drawn as two translucent
  triangles plus an outline; the shared diagonal shows no visible seam.
- **View ring (Rotate):** an outer circle at 1.15× the handle length, drawn with the overlay's
  rounded-rect border (a circle is a rounded rect with a radius of half its size), and grabbed
  within 9 points of its radius. It turns around the direction from the gizmo to the camera,
  captured at the press, using the same screen-angle measurement as the axis rings (with the
  axis always facing the viewer, the sign needs no flip). Unity's free rotation (dragging
  inside the sphere, like a trackball) isn't done yet.
- **Pivot / Center (Z), Unity's "tool handle position":**
  - *Pivot:* the gizmo sits on the active object's origin; Rotate and Scale act on each object
    around its own origin (positions don't change).
  - *Center:* the gizmo sits in the middle of the selection's world bounds (the same box F
    frames, now `selection_world_bounds`); Rotate turns the selection as one rigid group
    around it, and Scale also scales the objects' offsets from it (along the dragged axis, or
    uniformly), so a group grows like one object (exactly for uniform scale, or when the
    objects share a rotation; see the limitation below).
  - The point is fixed at the press, so the gizmo doesn't chase the bounds while scaling.
  - **Known limitation: an axis Scale drag on objects with different rotations** (found by an
    outside review). The handles show the active object's axes, and the offsets from the centre
    scale along that axis, but each object's scale changes along *its own* axis of the same
    name. Example: the active cube is turned 90° about Y and a second cube isn't. Dragging the X
    handle to 2× doubles the active cube's world Z size, but the second cube's world X size,
    while moving the second cube along world Z. So the group doesn't stretch as one piece.
    - *Why not fix it:* stretching a rotated object along some other axis turns it into a skewed
      shape, and an entity's transform (position, rotation, scale) can't store skew. The only
      exact fixes are storing full matrices or baking the skew into the mesh, and both are too
      much for an editor convenience.
    - *Why not approximate it:* the alternatives are scaling only the spacing, or switching to
      uniform scale for mixed rotations. Both surprise more than the current behaviour.
    - Unity does the same: each object's local scale changes along its own axis. Uniform scale
      (the centre handle), and axis drags on objects that share a rotation, are exact.
  - Default is Pivot.
- **Global / Local (X)** got Unity's key too. Local now takes the *active* object's axes rather
  than the first selected in pool order.
- **The gizmo follows the drag** (feedback: it jumped to the new place on release). The drawn
  gizmo now travels with a move, turns with a Local rotation, and stretches the dragged Scale
  handle by the scale factor (Unity's look). It snaps back to normal length on release. The
  centre of a rotation or scale stays where it was pressed, because it's the drag's fixed point.
  Only the drawing changed: the drag is still solved from the origin and axes saved at the
  press (`drag_origin`, `drag_axes`), with `drag_offset` and `drag_handle_stretch` recorded
  just for display, so nothing feeds back into the maths and nothing drifts.
- **Active object:** the one selected last (a click, a Hierarchy click, or Create), as in
  Unity. Stored as a handle in `Editor_State`, and checked on use: if it's no longer selected
  (Ctrl+click, Delete, undo, Ctrl+D), the first selected object stands in. That way nothing has
  to keep it up to date, the same reasoning as selection being a flag. It isn't part of undo,
  so after an undo the active object may differ from Unity's choice. The fallback keeps the
  gizmo correct anyway.
- **Bug caught by the tests:** `ray_plane_intersection` returns a distance, and assigning that
  `f32` to a `[3]f32` compiles in Odin (a scalar fills every component), so the first version
  moved the cube diagonally. The gizmo now goes through `mouse_on_plane`, which returns the
  point.
- **Tests:** core: ray/plane hits from either side, parallel and behind misses. game: a plane
  drag moves exactly the projected amount with nothing along the normal; looking straight
  down, the facing square is grabbable and edge-on ones aren't; the view ring gives exactly
  90° about the view axis, and turns screen-right to screen-up; Pivot vs Center placement,
  fallback when the active object is deselected, rotation in place vs orbiting, and scale
  keeping vs spreading positions.

## Tab between number boxes

- **Tab / Shift+Tab** while typing into a number box apply the value and start typing into the
  next / previous box with its text selected, wrapping around at either end (Unity, Godot).
  Each applied value is its own undo step, through `ui.typed_value_applied` as for Enter.
- **Order is drawing order, not a declared tab index.** Retained-mode toolkits keep a focus
  chain of widget objects; an immediate-mode UI has no objects, but it does draw its widgets in
  the same order every frame, and that order is already top-to-bottom, left-to-right (Position
  X, Y, Z, then Rotation X...). Dear ImGui tabs the same way. So each box records itself as it
  is drawn (`previous_box_id`, `first_box_id`), and nothing else has to be kept up to date.
- **Moving forward needs one frame of lookahead:** the next box hasn't been drawn when Tab is
  handled, so `focus_request = .Next` is left for it to pick up. Shift+Tab can start the
  previous box at once. Requests nobody picked up (Tab from the last box, Shift+Tab from the
  first) are resolved in `finish_layout` by wrapping to the first or last box.
- **The box typed into is scrolled into view.** Every box takes part, including ones clipped
  by a scrolled panel, so moving the typing sets `scroll_to_edit`. The next `begin_frame` reads
  the box's position from the finished layout and moves the panel's Clay scroll position just
  enough to show it. Reading last frame's layout costs one frame of delay; finding the box's
  position mid-layout isn't possible, because Clay only positions elements in `EndLayout`.
- Only number boxes take part; checkboxes and buttons have no keyboard focus yet.

## Renaming objects: one text editor shared by every box

- **Renaming, Unity's two ways:** the name at the top of the Inspector is a text box, and F2
  turns the active object's Hierarchy row into one. A click (or F2) starts typing with the
  whole name selected; Enter, Tab or a click elsewhere apply it, Escape cancels.
- **The name changes once, when typing is applied,** not on every keystroke. Undo then records
  one step per rename without knowing about names (it diffs entities, see step 3), and
  Escape has nothing to put back. `ui.typed_value_applied` covers text boxes too, so a click
  elsewhere records the rename before that click starts its own action.
- **Names may repeat, as in Unity** (Blender makes them unique). Only Create and Ctrl+D pick
  unique names; renaming takes what was typed, up to 48 bytes, cut at a character boundary.
  (Changed later: renaming now makes names unique too; see "Name validation".)
  `set_entity_name` clears the rest of the buffer, so equal names are equal bytes and undo's
  byte comparison sees no change in a rename that ends where it started.
- **One editor, in `Ui_State`, shared by text and number boxes** (`ui/text_edit.odin`). Only one
  box takes typing at a time, so the text being typed lives in one buffer with a caret and a
  selection, and the box only holds the id that says it's the one. This is how Dear ImGui does
  it too. The alternative, an editing state per box, would need the caller to keep it between
  frames, which an immediate-mode widget is meant to avoid. Number boxes moved onto it and got a
  real caret and selection; the old `[selected]` and `text|` displays are gone.
- **Caret and selection are two byte offsets** (now core:text/edit's `selection`; see "Text
  editing" below), `edit_caret` and `edit_anchor` (the selection
  is the range between them; Shift moves only the caret). Offsets always sit on UTF-8
  character boundaries, which can be recognized without decoding: continuation bytes look like
  `10xxxxxx`.
- **The text box doesn't store its text.** It shows the string it's given and returns a
  `Text_Box_Result` and, on `.Applied`, the new text. The caller keeps names in whatever form
  it likes (a fixed buffer in `Entity`); the UI never holds a pointer into game data.
- **Drawing the caret with Clay** (replaced; see "Text editing" below): the edited text is drawn as up to three text elements (before
  the selection, the selection on a highlight, after it) plus a 1-point-wide caret element, side
  by side with no gap. A click finds the caret position by measuring each prefix with fontstash
  and taking the nearest boundary. A test checks that Clay's layout and that measurement agree,
  trailing spaces included, or the caret would drift from the text.
- **A box that stops being drawn while typed into gives up the keyboard.** Otherwise a box
  whose panel closed, or whose object went away, would keep `edit_id` and block every shortcut.
  Boxes report being drawn (`edit_widget_drawn`); `finish_layout` drops an edit nobody drew.
- **Not yet:** clipboard, word jumps, double-click to select a word and keeping the caret
  visible in long text (all done later, see "Text editing"), and Tab from the name box to the
  number boxes.

## Orthographic view and the view gizmo

- **Unity's scene gizmo, as knobs rather than Autodesk's ViewCube.** A ViewCube's faces,
  edges and corners never overlap each other, but it needs the cube's faces drawn and
  hit-tested as 3D polygons. Knobs are circles at projected unit directions: six axes (X Y Z
  filled and lettered, the negatives hollow) and eight cube corners. They're drawn far to near
  and hit-tested near to far, so a knob behind another is reached by turning the view a
  little, as in Unity and Blender. The centre square (projection) is drawn over all knobs:
  in an axis or corner view the knob facing you sits exactly on it, and it must stay
  clickable. Corner views in orthographic mode are true isometric (pitch atan(1/√2)).
- **Snapping keeps the pivot and distance,** so what you were looking at stays centred. Top
  and Bottom use yaw 0: in Top, +X is right and the scene's back (-Z) is up, as in Unity.
  Snaps are animated (below).
- **Dragging the view gizmo orbits** (as Blender's navigation gizmo does; Unity's doesn't). A
  press on any part, or on the empty disc around the knobs, becomes a drag once the mouse moves
  past the selection-click tolerance, and the turn is exactly Alt + left drag's
  (`orbit_viewport_camera`). So clicks act on release, not press: on press it isn't known yet
  whether the user is clicking or dragging. A drag keeps the mouse over panels and outside the
  view, like a gizmo handle drag. The disc lights up on hover to show it's grabbable.
- **The camera basis comes from yaw and pitch, not `look_at(…, WORLD_UP)`.** Crossing the
  view direction with world up is zero when looking straight down, so the old camera clamped
  pitch to 89.4° and a "top" view was slightly tilted, which shows in orthographic as thin
  slivers of every side face. `right = (cos yaw, 0, -sin yaw)` is defined at the poles, so
  pitch now reaches ±90°. The view matrix, projection, picking ray, pixel size and the
  direction toward the viewer all come from `camera.odin` now; they were rebuilt in four
  places before, and adding a projection mode to four copies invites a mismatch.
- **Orthographic size is tied to `distance`:** half height = distance · tan(fov / 2), the
  perspective view's height at the pivot. Switching modes keeps the pivot's surroundings the
  same size, and zoom, pan and frame (F) work unchanged (Unity does the same).
- **Orthographic depth spans ±1000 units around the eye,** reverse-Z like perspective so the
  depth test is the same. The near plane is behind the eye because in orthographic the eye's
  position is arbitrary (moving along the view direction changes nothing on screen), and
  zooming in mustn't clip objects between the eye and the pivot. Picking rays start at that
  near plane for the same reason. Depth precision is linear: 2000 units over a 32-bit float
  depth is about 0.1 mm near depth 0.5.
- **Selection outlines move along the view direction** in orthographic mode. They used to move
  toward the eye point, which in orthographic would also slide them sideways on screen.
- **The grid faces orthographic side views, by cross-fading.** The ground is edge-on (invisible)
  from the side. In orthographic the renderer draws three grid planes (one instance each, through
  the origin), and the editor gives each an opacity that changes smoothly with the view: the
  ground fades out between 20° and 8° above or below it, and the vertical planes fade in,
  shared between XY (faced from the Front or Back) and YZ (from the Right or Left) by which one
  the view faces more. The ground-to-vertical change also follows the perspective ↔
  orthographic animation. A first version switched planes at a threshold: correct in the
  axis views, but orbiting across the threshold made the grid jump, which was jarring. A test
  orbits over every angle in half-degree steps and checks no opacity moves by more than 0.05
  and the weights always add up to 1. Perspective always uses the ground, where its horizon
  helps. The renderer only takes `grid_opacity` per `Grid_Plane`; the shader works in 2D plane
  coordinates, and collapses planes with zero opacity in the vertex shader.
- **Not done:** no keyboard shortcuts for the views (Unity has none; Blender uses the numpad).
- **Animated view changes, as in Unity.** View gizmo snaps and F move the camera over 0.3 s
  with an ease-out (fast start, so it feels responsive). A move is a start and a target pose
  (pivot, yaw, pitch, distance) and the time left; zero time left means "not moving", so
  setting the camera directly (flags, tests, the Inspector) stays instant. Yaw goes the short
  way round; distance is interpolated in log space so big zooms look even. A new move starts
  from the current target, so F during a snap still ends in the snapped view. Orbit, pan,
  zoom or fly stop a move where it is.
- **Perspective ↔ orthographic is a dolly zoom,** as Unity animates it: the field of view
  narrows toward 1° while the eye backs away so the view's height at the pivot stays the same
  (eye distance = half height / tan(fov / 2)), then the true orthographic projection takes
  over (indistinguishable at 1°). `viewport_camera_lens` is the one place that says how the
  camera projects this frame; view, projection, rays and pixel size all ask it. The switch
  uses smoothstep, not ease-out: switching back mid-way flips the time left, and only a
  symmetric curve (s(1 - t) = 1 - s(t)) continues from the same point without a jump.
- **Orbit always turns around the pivot,** and F puts the pivot on the selection, so after F,
  Alt + left drag (or dragging the view gizmo) orbits the framed object. Panning and flying
  move the pivot with the view, as in Unity.
- **Soft depth test for the grid, after Blender** (its `overlay_grid_vert.glsl`). A face lying
  in the grid's plane z-fought with it. First fix: nudge the grid toward the camera so it
  always wins. Blender instead draws the grid several times at slightly different depths, from
  just behind to just in front, each with a share of the opacity: a coplanar face keeps half
  the passes (the grid shows on it at partial strength, steadily), and an object crossing the
  grid gets a short fade instead of a hard, jagged cut. We draw 4 passes. Per-pass opacity is
  1 - (1 - alpha)^(1/4), so the four blended over each other give exactly alpha. Blender adds
  fixed amounts to clip-space z; for our reverse-Z, perspective scales the depth (a spread of
  ±0.02% of the distance, the same safety margin at every distance) and orthographic adds a
  small constant (±8 mm), since a relative spread there would be ±20 cm. Blender 3.6 did this
  with one pass reading the scene depth texture; in WebGPU that needs a separate pass with a
  read-only depth attachment, more awkward with MSAA, so we took the newer multi-pass approach.
- **Grid lines are a width in pixels, with a colour and opacity** (Inspector › View). They were
  a fraction of a cell (0.02), which made the 10-unit lines 0.2 units wide: 20-pixel grey bands
  near the camera. Constant-pixel lines would merge into a solid sheet in the distance, so each
  family of lines fades out as its cells shrink from 12 to 4 pixels apart, as Blender's grid
  levels do. Widths under a pixel draw a fainter 1-pixel line (same average brightness, no
  shimmer). The width is in window pixels; the renderer scales it by the render scale.

## Text editing: core:text/edit, drawn from one measurement

- **What was wrong with the first text box.** It laid the edited text out as separate Clay text
  elements (before the selection, the selection, after it) with the caret as a 1-point element
  between them. Each piece was placed and snapped to whole pixels on its own, so letters shifted
  by a pixel when the selection or caret moved, kerning across a boundary was lost, and the
  caret took up a pixel of room in the text. Clicks measured prefixes differently from how the
  text was drawn, so the caret could land a character off. It also didn't blink, and long text
  didn't scroll.
- **Not a reason to switch to Dear ImGui.** Its text input (stb_textedit plus years of polish)
  would have given us all of this, but adopting it means replacing the Clay UI or running two UI
  systems with two themes. Nothing about immediate mode stops a good text box; the widget was
  built the wrong way. What ImGui does, and we now do: the box is one rectangle, and inside it
  the widget positions every character once per frame, from one list. The text, the selection,
  the caret, clicks and scrolling all read that list.
- **Drawing:** Clay lays out an empty "custom" element where the text goes; end_frame gets a
  custom render command for it in the right draw order and clip region, and `draw_edited_text`
  draws the selection highlight, the glyphs and the caret into it with the overlay API. The
  positions (`edit_caret_x`) come from fontstash's own text iterator, the same calls that place
  the glyphs, with one whole-pixel origin for the whole string. Text wider than its box scrolls
  sideways just enough to keep the caret in view.
- **Editing: Odin's `core:text/edit`** (in the standard library, after rxi's "Textbox
  behaviour" and "A simple undo system"). It does the selection, word movement, word deletion
  and an undo history that groups typing less than 0.3 s apart. We map our keys to its commands.
  Copy, cut and paste we do ourselves, through the host, instead of its clipboard callbacks.
  The text lives in a fixed buffer behind a `strings.Builder` with the nil allocator, so the
  box's byte limit is the builder's capacity, and core:text/edit never cuts a character in half
  when it's full. Rejected: extending our own editing code (~150 more lines to keep correct).
- **Hot reload and core:text/edit.** Its `State` and the builder contain allocators, which are
  procedure pointers, and they live in `Game_Memory`. So `refresh_edit_pointers` sets them again
  at the start of every use; nothing from a previous frame (possibly a previous DLL) is trusted.
  Undo history is allocated with the context's allocator, which is the host's and doesn't unload.
  Clipboard callbacks would be procedure pointers kept in state, so they aren't used.
- **Clipboard and cursor go through the host,** the only package that may call SDL.
  `platform.Input` gains the clipboard's text, read only on frames where Ctrl+V is pressed
  (asking the OS can be slow). A new `platform.Output`, filled by the game each frame
  (`ui.write_output`), asks the host to set the clipboard and the mouse cursor (an I-beam over
  text boxes, and over number boxes while typing; otherwise number boxes drag, so they keep the
  arrow). `game_update` now takes the output too.
- **Mouse:** double-click selects a word and dragging then extends by words; triple-click selects
  all. The UI counts quick presses in the same place (0.4 s, 4 points) in begin_frame.
- **The caret blinks** (0.53 s on, 0.53 s off, Windows' default) and shows at once after any
  change.
- **Tests** cover the commands, the clipboard both ways, double- and triple-clicks, scrolling,
  the cursor, and drawing: the renderer's overlay API only collects quads on the CPU, so a test
  draws the edited text and checks the selection, glyph and caret quads land on the measured
  positions. Breaking the caret drawing or word movement makes them fail.
- **Fixed on the way:** starting to type in a box less than 0.3 s after an edit in another box
  merged the first change into no undo step (core:text/edit's timer carried over).
- **Fixed in review (Codex):** the same timer wasn't restarted by undo and redo either, so typing
  within 0.3 s of the last edit after a Ctrl+Z joined the undone edit, and the next Ctrl+Z
  couldn't take it back. Undo and redo now clear the timer; a test types right after each.

## Name validation

- **Rules** (`check_entity_name` in `scene.odin`), applied to renaming in both the Hierarchy and
  the Inspector:
  - spaces at either end are dropped quietly;
  - an empty name is refused;
  - only letters (any script, so "Café" works), digits, spaces and `_ - . ( )` are allowed, so a
    name can later be part of a file name or a reference typed by hand on any system;
  - combining marks are allowed after the first character, as Unicode's identifier rules
    (UAX #31) allow them: they're part of written letters, such as Hindi vowel signs or an accent
    typed as a separate character (found in review by Codex);
  - a name another object has gets the next free " (N)", as Create and Ctrl+D already did.
- **Unique names, unlike Unity** (Blender's way). This reverses the earlier "names may repeat"
  choice: a name will identify an object once scenes are saved and objects refer to each other.
  The object being renamed never clashes with itself, so retyping its own name keeps it.
- **Feedback while typing, not after.** The text box takes an optional check procedure and calls
  it every frame while typing, so the message follows the text. A blocking problem (empty, a
  character not allowed) turns the border red and shows the reason under the box; Enter and Tab
  don't apply, Escape cancels, and a click elsewhere cancels too (the box can't stay open while
  you work elsewhere). A taken name isn't an error: a grey note says what the name will become,
  and applying makes it unique.
- **The check is a procedure parameter, not stored.** Immediate-mode widgets keep nothing between
  frames, so the box can't hold a validator; and the caller can't check before the call, because
  the text it would check is typed during the call. A parameter called inside `text_box` (with a
  `rawptr` for the caller's data: here the scene and the object) is like a sort's comparison
  procedure; hard rule 3 forbids procedure *fields* used as virtual methods, not this.
- **Finding the next free number in one pass** (found in review by Codex). The box checks every
  frame, and the first `unique_entity_name` scanned the scene once per candidate suffix: with a
  thousand "Cube (N)" objects, about a million comparisons a frame. Now one pass marks which
  numbers are taken and the smallest free one is used. Rejected: caching the result until the
  text or scene changes, which would need state kept between frames for one widget.
- **Hot reload:** nothing here changes `Game_Memory`, the host or the platform types. The error
  colour is a constant (`TEXT_ERROR_COLOR`) rather than a `Theme` field, which would have changed
  `Ui_State`'s layout and forced a restart.
