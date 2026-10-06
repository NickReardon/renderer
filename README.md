# Renderer

A 3D modeler growing into a small game engine, written in [Odin](https://odin-lang.org) with
SDL3 and wgpu. It's also a study of data-oriented, procedural and immediate-mode design; see
`docs/` for the style guide, design decisions and reading list.

## Build and run (Windows)

Needs Odin (`dev-2026-09` or later) and Visual Studio's C++ build tools.

```
build.bat run      build everything and start the engine
build.bat game     rebuild only the game code; the running engine hot-reloads it
build.bat test     run the core and UI tests
```

## Viewport controls (Unity scene-view style)

| Input | Action |
|---|---|
| Alt + left drag | Orbit |
| Middle drag | Pan |
| Alt + right drag, wheel | Zoom |
| Right drag | Look around; hold it and use WASD to move, Q/E down/up, Shift faster |
| F6 | Restart the game state |
| Click / Shift+click / Ctrl+click | Select / add to selection / toggle |
| Delete, Ctrl+D | Delete, duplicate the selection |
| F | Frame the selection |
| Esc | Clear the selection (during a gizmo drag: cancel it) |
| Q / W / E / R | Hand (pan), Move, Rotate, Scale tools; drag a handle to transform, Ctrl to snap |
| Move tool squares | Drag in the plane of two axes |
| Rotate tool outer ring | Turn around the view direction |
| Z / X | Pivot or Center (where the gizmo sits and what it turns around) / Global or Local axes |
| Ctrl+Z / Ctrl+Y (or Ctrl+Shift+Z) | Undo / redo |

The Hierarchy panel on the left creates objects (cube, sphere, cylinder, plane) and lists the scene; the Inspector on the right edits the selected object, generated from its fields, plus view, camera and rendering settings. Number fields: drag sideways to change, click to type (Enter applies, Escape cancels).

Coordinates are right-handed: X right, Y up, Z toward the viewer.

## Render resolution

The Inspector's **Rendering** section sets the 3D view's resolution:
- **Fixed:** a render scale from 50% to 200%.
- **Dynamic:** a target frame rate, and the scale moves between a minimum and maximum to hold
  it, measured with GPU timestamps.

Below 100% the image is upscaled with AMD FSR 1 (or bilinear, to compare). Above 100% it is
supersampled: rendered larger, then filtered down. Statistics shows GPU time, the render size
and the current mode. **MSAA 4×** (on by default) smooths geometry edges, and gives FSR the
anti-aliased input it needs.
