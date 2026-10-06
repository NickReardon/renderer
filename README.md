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
| F | Frame |
| F6 | Restart the game state |

The Inspector panel on the right edits the view, camera and scene. Number fields: drag sideways to change, click to type (Enter applies, Escape cancels).
| Esc | Quit |

Coordinates are right-handed: X right, Y up, Z toward the viewer.
