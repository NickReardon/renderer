# CLAUDE.md

A 3D modeler that grows into a small game engine, written in **Odin** with **SDL3** (platform)
and **wgpu** (graphics). It targets Windows, macOS and Linux natively, and the web later. It is
also a learning project: the owner wants to understand data-oriented, procedural and
immediate-mode design, so code must be easy to read and every non-obvious decision explained.

Read `docs/STYLE.md` for the full rules and reasoning, `docs/DESIGN.md` for past decisions, and
`docs/REFERENCES.md` for sources. Planned work is tracked in GitHub Issues (see below).

## Build and run (Windows)

```
build.bat          full build: build\engine.exe + build\game.dll, copies SDL3.dll and wgpu_native.dll
build.bat game     rebuild only game.dll; a running engine hot-reloads it (shaders included)
build.bat test     run the core and UI tests
build.bat run      full build, then start the engine
build\engine.exe --screenshot                 save frame 30 to build\screenshot.bmp, then exit
build\engine.exe --screenshot-after-reload    same, 30 frames after the first hot reload
  --screenshot-frame=N    capture N frames after the trigger instead of 30
  --render-scale=50       fixed render scale in percent (50..200)
  --upscaler=bilinear     bilinear instead of FSR 1
  --dynamic               dynamic resolution on
  --msaa=off              no 4x MSAA
  --target-fps=120        dynamic resolution's target (default: display refresh rate)
  --pick-center-of=Sphere click the named object's centre (tests picking end to end)
  --rename                after the pick, press F2 (the Hierarchy row becomes a text box)
  --rename-type=TEXT      like --rename, then type TEXT into the box
  --mirror=Cube           scale X = -1 on the named object (mirrored-transform check)
  --flatten=Sphere        scale Y = 0 on the named object (zero-scale check)
  --tool=rotate           start with a tool (hand, move, rotate, scale); --local for Local axes
  --center                start in Center mode (gizmo at the selection's middle) instead of Pivot
  --ortho                 start in orthographic projection
  --view=top              start in an axis view (right, left, top, bottom, front, back), or
                          --view=corner for the +X +Y +Z corner (isometric with --ortho)
  --switch-projection     start the animated switch to orthographic (capture it with
                          --screenshot-frame=N)
  --camera=45,14          start at this yaw and pitch, in degrees
  --grid-width=3          grid line width in pixels
```

- Odin: `dev-2026-09`, at `%LOCALAPPDATA%\Programs\odin` (the script finds it even when it isn't
  on PATH). Uses the MSVC linker from Visual Studio.
- From the Bash tool, run `cmd //c "D:\\Renderer\\build.bat game"`. A relative `build.bat`
  isn't found from there.
- **Verify a change in the running engine:** start `build\engine.exe` with stdout and stderr
  redirected to files, rebuild, then read the logs. wgpu validation, shader and Clay errors go
  to stderr. F6 forces a full game restart.
- **Look at the result with `--screenshot`,** never by capturing the desktop: the window may be
  behind others, and a desktop capture can show the owner's other windows. Convert the BMP to
  PNG (PowerShell `System.Drawing`) and halve it to view it.
- **Game logic that needs no GPU is tested in `src/game/scene_test.odin`** (`odin test src/game`).
- **UI behaviour is tested in `src/ui/ui_test.odin`** by running real frames with simulated
  input and finding widgets by the text they show. Extend it when adding or changing widgets.
- macOS and Linux build scripts don't exist yet.

## Conventions

- **Coordinates: right-handed, X horizontal (right), Y vertical (up), Z depth (+Z toward the
  viewer, camera forward = -Z).** Use `core.WORLD_RIGHT`, `core.WORLD_UP`, `core.WORLD_FORWARD`;
  don't hard-code axes. Axis colors: X red, Y green, Z blue.
- **Reverse-Z depth:** the near plane is depth 1, clear depth to 0, compare `.Greater`.
- **Frame structure (render/):**
  - scene pass into `scene_color` (sRGB) at render resolution, within targets allocated at
    window × 2. With MSAA it renders into the 4× multisampled targets instead, then a resolve
    pass averages the samples into `scene_color`;
  - FSR EASU pass (below 100% only);
  - window pass: RCAS or bilinear resample into the viewport, then the UI overlay.

  Scene shaders output **linear** color, because the target is sRGB. Only window-pass shaders
  deal with `gamma_correct` / `surface_is_srgb`.
- **Editor UX follows Unity's scene view:**
  - navigation: Alt+left orbit, middle pan, Alt+right or wheel zoom, right-drag fly with
    WASD/QE, F to frame;
  - the view gizmo (top right) snaps to axis and corner views, and dragging it orbits; its
    centre switches perspective / orthographic;
  - transform gizmos (move, rotate, scale handles) and the QWERTY tool keys when the editor
    gets them;
  - all of it in our right-handed, Y-up space.

## Package layout

```
src/platform/  plain shared types (Input, Output, Native_Window); no procedures, importable by all
src/host/      executable: SDL3 window, input, main loop, hot reload; only package using SDL
src/game/      editor + game, hot-reloaded DLL; all persistent state in Game_Memory
               game.odin (frame, settings, panels), scene.odin (entities, mesh assets),
               editor.odin (selection, picking, Hierarchy, Inspector, renaming, shortcuts), camera.odin,
               gizmo.odin (Q W E R transform tools), undo.odin (Ctrl+Z / Ctrl+Y),
               view_gizmo.odin (axis and corner views, perspective / orthographic)
src/render/    renderer; only package using wgpu (render.odin API, device.odin, pipelines.odin, shaders/)
src/ui/        immediate-mode UI; only package using Clay and fontstash; draws via render's overlay API
src/core/      math and mesh; imports no engine package, no GPU or OS code; tests in core_test.odin
src/third_party/clay/  Clay's Odin bindings + prebuilt libs, unmodified (see VERSION.txt)
assets/fonts/  Inter (UI), JetBrains Mono (numbers), with their OFL licenses; embedded via #load
```

The host passes OS window handles (`platform.Native_Window`) to the game, and `render/` builds
the wgpu surface from them. That keeps SDL out of the renderer and wgpu out of the host.

## Hard rules

1. **No wgpu types or calls outside `src/render/`. No SDL calls outside `src/host/`. No Clay
   or fontstash calls outside `src/ui/`.** Game and editor code use only `ui.*` procedures.
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

## Branches and pull requests

The repository is private on GitHub: https://github.com/NickReardon/renderer.

- **Never commit to `main` directly.** `main` always builds and passes `build.bat test`.
- **One branch per milestone or fix,** created from an up-to-date `main`:
  `feature/<name>` (e.g. `feature/undo`), `fix/<name>`, `docs/<name>`, `chore/<name>`.
- **For implementation and other code work,** commit on the task branch as you go, push it, and
  open a pull request with `gh pr create`. The description says what changed and why, how it was
  verified (build, tests, captures), and what's not done. End it with the Claude Code attribution
  line. Proposals are written in the issue, and docs-first PRs are made on GitHub (see below).
- **Merge only after the build and all tests pass and the owner approves.** The repository
  allows **squash merges only** (`gh pr merge --squash`): each pull request becomes one commit on
  `main`, and GitHub deletes the branch. Afterwards, remove the task worktree, delete its local
  branch after confirming the squash merge, and pull GitHub `main` into the main checkout.
- **Never force-push `main` or rewrite pushed history.**
- **Commits use the GitHub no-reply address** (`32754140+NickReardon@users.noreply.github.com`,
  set in this repository's git config) because the owner's account blocks pushes that expose
  their email. Don't change `user.email`.
- **`gh` is at `C:\Program Files\GitHub CLI\gh.exe`;** it may not be on the Bash tool's PATH.

## Planned work: GitHub Issues

Work that hasn't started is tracked as GitHub Issues
(https://github.com/NickReardon/renderer/issues), one issue per unit of work, with what, why and
roughly how. Several agents (and people) may work at once, on one machine or several, so the
issue is where work is claimed and handed over:

- **Before starting,** read the issue and its comments (`gh issue view <n> --comments`), and
  check it isn't labeled `in-progress` (someone else has it).
- **Design in the issue, approved before any work.** For work with design choices (features,
  architecture), draft a high-level proposal in the issue: what we intend to build and why, the
  main choice, and the options considered. Discuss it in the comments, and update the issue's
  description as it settles. The owner approves it with a label that also picks the route:
  - **`approved: implement`** (the usual case): build it, and put the docs in the same PR as
    the code. They're written from what was actually built, so they start out true;
  - **`approved: docs-first`** (large or cross-cutting designs): first a docs PR, then the
    implementation. Use GitHub's web editor or API to create a `docs/<n>-<name>` branch and the
    PR (not a local docs worktree, local file writes, or a push). Add a section to
    `docs/DESIGN.md` (until #26 splits it) with **Status: Proposed** and a link to the issue.
    Wait for the owner to approve and merge it; the implementation PR then fills in the detail
    and sets the status to **Accepted**.

  Without an `approved:` label, nobody starts the work. Plain bug fixes and trivial changes
  skip the proposal. A design a later one replaces is marked **Superseded by …** (a link).
- **Claim it:** add the `in-progress` label and comment that work has started
  (`gh issue edit <n> --add-label in-progress`, `gh issue comment <n> --body "..."`). Add the
  branch name to the issue when the branch is created.
- **Name the branch with the issue number:** `feature/<n>-<name>` or `fix/<n>-<name>` (and
  `docs/<n>-<name>` for a docs-first PR).
- **Write `Fixes #<n>` in the implementation pull request,** so merging it closes the issue (a
  docs-first PR says `Part of #<n>`).
- **Stopping partway:** comment where things stand (what's done, what's failing, what's next)
  and remove the `in-progress` label, so the next agent can pick it up.
- **Large designs ship in iterations, as GitHub sub-issues** of the design issue (e.g. #36 →
  #49–#52), each blocked by the one before. Separate issues are for work that is useful on its
  own (#46, #47); iterations are useless without each other.
  - the parent keeps the design and its approval: its `approved:` label covers every
    sub-issue, and design changes found while building go into the parent's description;
  - a sub-issue holds its scope and a "done when" check, is claimed with `in-progress`, gets
    its own branch (`feature/<sub-issue>-<name>`) and PR, and the PR says `Fixes #<sub-issue>`;
  - GitHub doesn't close the parent: close it by hand when its last sub-issue closes.
- **Labels:** `area: hot-reload`, `area: text-editing`, `area: view`, `area: rendering`, plus
  GitHub's `bug` and `enhancement`. Add an `area:` label when a new area appears. Workflow
  labels: `approved: implement`, `approved: docs-first` (set only by the owner) and `in-progress`.
- **The main checkout (`D:\Renderer`) stays on `main`.** Pull GitHub `main` into it before
  creating a code worktree: `git -C D:/Renderer pull --ff-only origin main` (forward slashes:
  in the Bash tool a backslash is an escape, so `D:\Renderer` becomes `D:Renderer`). Create each
  implementation or other code task in its own worktree under `.claude/worktrees/`, branching
  from that updated local `main` (`git -C D:/Renderer worktree add
  .claude/worktrees/<task-name> -b <branch> main`). Never switch branches in the main checkout.
  Before opening or updating a task PR, pull GitHub `main` into the main checkout again, merge
  that `main` into the task branch in its worktree, resolve conflicts, and rerun affected checks.
  Merge rather than rebase an already pushed task branch, so its history is not rewritten.
  Remove the task worktree after its PR is merged (`git worktree remove`). Docs-first PRs are
  made on GitHub directly, as described above.

## How to work

- **Build before saying a change is done,** and run `build.bat test` when `core/` or `ui/` changed.
  Report failures honestly, with the output.
- **Every new operation in `core/` gets tests first** (exact values or properties such as
  "closed mesh stays closed").
- **Ask before adding any dependency,** including another `vendor:` package.
- **End each change with a short explanation** of why it is built the way it is, aimed at someone
  learning these techniques. Design decisions (choices between alternatives) are written up in
  `docs/DESIGN.md` before the work, in a docs PR (see "Docs first" above), and corrected in
  the implementation PR.
- **Keep changes to one milestone at a time;** don't build ahead of what was asked.
- **Ideas outside the current branch's scope become GitHub issues,** not part of the branch:
  recommend them, file an issue (what, why, roughly how, an `area:` label), and keep the branch
  to its milestone. Creating issues is fine; working on them waits for the owner.
- **Prefer designs that hot-reload.** Avoid changing `src/host/`, `src/platform/` types, the
  exported `game_*` procedures or `Game_Memory`'s layout when a game-side design works; when
  one must change, say which reload level it needs (hot reload, F6 restart, full relaunch).
  A relaunch while building the editor is acceptable, just not preferred: when a host or
  layout change is the better design, make it and note the reload level once. Avoid only the
  interruptions users of the editor would hit (e.g. a setting that needs a restart to apply).
- **Settings are Editor Settings for now** (#32): preferences for how the editor looks and
  behaves. When a change adds a setting that isn't an editor preference (it would change the
  built game, the project's data, a simulation or an export), say so in the PR and its issue.
  Those are the evidence for when separate Project, Rendering, Game or Export settings are
  justified. Today's Rendering settings (VSync, MSAA, render scale, FSR) count as the editor
  viewport's preferences, but a game build will need its own copy.
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

- **Vulkan with `desiredMaximumFrameLatency = 1` ignores vsync on this hybrid-GPU laptop**
  (354 fps on a 60 Hz panel). The renderer prefers D3D12 on Windows and gives Vulkan two queued
  frames; see docs/DESIGN.md, "Input latency".

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
  enforces this). Editing `build.bat` with `sed` from the Bash tool can drop the CRs; check with
  `file build.bat` and restore them with `sed -i 's/\r*$/\r/' build.bat`.
- **Untyped float constants default to `f64`** when assigned with `:=`. Declare `f32`
  explicitly when the value is mixed with `[3]f32` math.
- **Appending to `#soa[dynamic]T` needs a typed literal:** `append(&ps, Particle{...})`.
- **Clay (Odin bindings, commit e6cc369):**
  - `_ConfigureOpenElement` is private: open with `clay._OpenElementWithId(id)` /
    `clay._OpenElement()`, configure with the public `clay.ConfigureOpenElement(...)`, close with
    `clay._CloseElement()`;
  - container widgets use `@(deferred_none = close_element)` so `if ui.panel(...) { }` closes
    itself. **The close runs at the end of the scope containing the call,** so always put the
    contents *inside* the `if` block. `if !ui.panel(...) { return }` closes the panel
    immediately, and its contents end up outside it;
  - **Clay is linked into the game DLL, so a hot reload gets fresh Clay globals.**
    `ui.on_hot_reload` must call `clay.SetCurrentContext` and re-register the text-measure
    callback; forgetting this crashes on the first reload;
  - Clay keeps a process-wide current context, so UI tests must not run in parallel (they're
    one test procedure);
  - Clay colors are 0–255 sRGB; text strings must live until `ui.end_frame` (temp allocator is
    fine).
- **Odin `fmt` pads widths with zeros** (`%6.2f` printed `013.86`). Don't use widths for
  alignment.
- **`os.args` is empty inside the game DLL;** only the executable's runtime parses the command
  line. The host passes `arguments` to `game_init`.
- **`dynamic` is an Odin keyword;** it can't be a field name.
- **No `math.exp2` or `strings.cut_prefix` in this Odin version.** Use `math.pow(2, x)` and
  `strings.has_prefix` plus slicing.
- **The PowerShell tool blocks `Remove-Item` with variables in the path.** Use
  `[System.IO.File]::Delete(path)`.
- **Odin only ships Windows binaries** for SDL3 and wgpu. macOS and Linux need SDL3 from the
  system package manager and wgpu-native v29.0.1.1 from GitHub.
