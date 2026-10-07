# Backlog

Work that was proposed but didn't belong in the branch where it came up. Each item says what,
why, and roughly how, so it can become its own branch later. When an item is done, delete it
here and record the decision in `docs/DESIGN.md`.

Older "Not yet" notes still live in their sections of `docs/DESIGN.md`.

## Hot reload first

Goal: nearly every change lands with `build.bat game` while the engine runs. Today three things
force a game restart (F6, state lost) or a full relaunch:
- changes to the host / `platform` interface;
- changes to `Game_Memory`'s layout;
- GPU resources created once at startup.

- **Map every key in the host.** `platform.Key` only lists the keys used so far, so a new
  shortcut on another key (Insert, the numpad, punctuation) changes the host and `platform`,
  which means a relaunch. Translate every SDL scancode once; then shortcuts are game-only.
- **A host service table instead of growing `platform.Output`.** Give the game a struct of
  host procedures at `game_init` and `game_hot_reloaded`: clipboard get/set, mouse cursor,
  window title, later file dialogs. Pointers into the host are safe to keep across reloads
  (the host never unloads). Clipboard and cursor would move there from `platform.Input` and
  `platform.Output` (added in the text-editing branch). Adding a service still changes the
  host, so add the likely ones in one go.
- **Detect `Game_Memory` layout changes by a layout hash, not its size.** The host restarts the
  game only when `game_memory_size()` changes. A change that keeps the size (reordered or
  retyped fields) hot-reloads into misread memory. Export a hash of the type's full layout
  (from Odin's type info) and compare that.
- **Carry state across a game restart.** When the layout changes, the old DLL (still loaded at
  that moment) saves the scene, camera, selection and settings in a stable format, and the new
  one loads them after `game_init`, so a restart keeps your work. The format is the start of
  scene save/load, which the modeler needs anyway, so this fits as its own milestone.
- **Recreate layout-dependent GPU resources on reload.** The frame uniform buffer and bind
  groups are sized at startup, so changing `Frame_Uniforms` needs F6 (the grid changes did).
  `render.reload_shaders` already rebuilds pipelines; let it also recreate the buffers and bind
  groups whose size comes from code.

## Text editing

- **Input method (IME) composition preview.** Japanese and Chinese typing works, but text only
  appears once committed; show the composition (SDL's TEXT_EDITING events) at the caret.
- **Shift+Insert / Ctrl+Insert** for paste and copy, and a right-click Cut / Copy / Paste menu.
- **Tab from the Inspector's name box to the number boxes** (Tab only moves between number
  boxes today).

## View and camera

- **Keyboard shortcuts for the axis views** (Blender's numpad layout). Unity has none. Needs
  the numpad keys mapped, which "Map every key in the host" covers.
- **Corner knobs can overlap negative-axis knobs** in the view gizmo at some angles. The front
  one wins the click, so it works, but it looks crowded. Try placing corners at a different
  radius, or a ViewCube.
- **Grid behind geometry in orthographic axis views,** as Blender does (`GRID_BEHIND_GEOMETRY`:
  depth at the far plane), so the grid doesn't cut through objects in Front·Ortho and similar.
  Proposed alongside the multi-pass soft depth test, not chosen then.

## Rendering

- **Selection outlines as a real silhouette** (a post pass), instead of the selected mesh's
  edges pulled toward the camera.
