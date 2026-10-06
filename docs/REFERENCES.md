# References

Reading list for this engine: data-oriented design, engine architecture, rendering (SDL3 + wgpu),
mesh modeling, and coding style. Each entry says why it matters here and roughly when it becomes
relevant (phases from the roadmap: **0** setup, **1** seeing things, **2** modeler core,
**3** engine basics, **4** renderer architecture).

## Start here (before writing code)

These eight shape the whole codebase. Together they are roughly a weekend.

1. **Mike Acton — *Data-Oriented Design and C++*** (CppCon 2014, talk).
   https://www.youtube.com/watch?v=rX0ItVEVjHc
   The core argument: the purpose of a program is to transform data; design around the data and
   the hardware, not around a model of the world.
2. **Andrew Kelley — *A Practical Guide to Applying Data-Oriented Design*** (Handmade Seattle 2021, talk).
   https://vimeo.com/649009599
   Concrete techniques (indices instead of pointers, struct-of-arrays, encoding "kinds" out of
   band) applied to a real codebase, the Zig compiler.
3. **Andre Weissflog — *Handles are the better pointers*** (blog).
   https://floooh.github.io/2018/06/17/handles-vs-pointers.html
   The handle + generation scheme every engine object here will use.
4. **Ryan Fleury — *Untangling Lifetimes: The Arena Allocator*** (blog).
   https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator
   Group allocations by lifetime (permanent / per level / per frame) instead of one at a time.
5. **Casey Muratori — *Semantic Compression*** (blog).
   https://caseymuratori.com/blog_0015
   Write the concrete code first; extract abstractions only after they repeat. The anti-UML.
6. **Casey Muratori — *Immediate-Mode Graphical User Interfaces*** (2005, video + notes).
   https://caseymuratori.com/blog_0001
   The origin of IMGUI. The editor UI and the debug-draw API will both work this way.
7. **Karl Zylinski — *Hot Reload Gameplay Code: What, why, limitations and examples*** (blog).
   https://zylinski.se/posts/hot-reload-gameplay-code/
   The host-exe + game-DLL setup we use, in Odin, including the pitfalls.
8. **Christer Ericson — *Order your graphics draw calls around!*** (blog).
   https://realtimecollisiondetection.net/blog/?p=86
   The draw-list-with-64-bit-sort-key design that `render/` is built around.

## Data-oriented design and programming philosophy

| Source | Why it matters here | Phase |
|---|---|---|
| Richard Fabian, *Data-Oriented Design* (free online book) — https://www.dataorienteddesign.com/dodbook/ | The most complete treatment; DOD framed as relational/table design. Read the chapters on existence-based processing and component-based objects. | 2–3 |
| Noel Llopis, *Data-Oriented Design (Or Why You Might Be Shooting Yourself in the Foot With OOP)* (2009) — https://gamesfromwithin.com/data-oriented-design | Short early article that popularized the term. | 0 |
| Casey Muratori, *"Clean" Code, Horrible Performance* — https://www.computerenhance.com/p/clean-code-horrible-performance | Measures virtual dispatch and "one class per shape" against switch statements and tables. | 0 |
| John Carmack, *On inlined code* (2007 email) — http://number-none.com/blow/john_carmack_on_inlined_code.html | Argues for long straight-line procedures over many tiny functions in frame-update code. | 0 |
| gingerBill, *Memory Allocation Strategies* (series) — https://www.gingerbill.org/series/memory-allocation-strategies/ | Linear/arena, stack, pool, free-list allocators, by Odin's author. Maps directly onto `core:mem`. | 0–2 |
| Chris Wellons, *Arena allocator tips and tricks* — https://nullprogram.com/blog/2023/09/27/ | Practical arena patterns (scratch arenas, growing arrays in arenas). | 1–2 |
| Robert Nystrom, *Game Programming Patterns* — https://gameprogrammingpatterns.com/data-locality.html | Free book. Read *Data Locality*, *Game Loop*, *Update Method*, *Component*. Mixed OOP/DOD; useful for vocabulary. | 3 |

## Entities and engine architecture

| Source | Why it matters here | Phase |
|---|---|---|
| Mick West, *Evolve Your Hierarchy* (2007) — https://cowboyprogramming.com/2007/01/05/evolve-your-heirachy/ | The classic case for moving from deep inheritance to components. | 3 |
| Bitsquid (Niklas Gray), *Building a Data-Oriented Entity System* part 1 — https://bitsquid.blogspot.com/2014/08/building-data-oriented-entity-system.html (part 2: https://bitsquid.blogspot.com/2014/09/building-data-oriented-entity-system.html) | Entity = ID, components live in per-system arrays. The rest of the Bitsquid blog (resource system, profiling, decoupling) is also worth browsing. | 3 |
| Sander Mertens, *ECS FAQ* — https://github.com/SanderMertens/ecs-faq | What archetype ECS is, its trade-offs, and its terminology. Useful for understanding ECS even if you don't adopt one. | 3 |
| "Fat struct" / "megastruct" entities: Casey Muratori's term, advocated by Ryan Fleury; discussion at https://hero.handmade.network/forums/code-discussion/t/7896/p/26400 | The alternative to ECS we start with: one `Entity` struct with every field, flags for features, pooled behind handles. | 3 |
| Our Machinery blog (archive) — https://github.com/ruby0x1/machinery_blog_archive | Niklas Gray's later engine. The posts on "The Truth" (their editor data model with undo, prototypes and collaboration) are directly relevant to the modeler's undo and scene format. | 2–3 |
| Glenn Fiedler, *Fix Your Timestep!* — https://gafferongames.com/post/fix_your_timestep/ | Fixed simulation step with interpolated rendering. The game loop for phase 3. | 3 |
| Christian Gyrling, *Parallelizing the Naughty Dog Engine Using Fibers* (GDC 2015) — https://gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine | Job system plus a "frame-centric" design with per-frame memory. Read once the engine is single-threaded and working. | 4 |
| Jason Gregory, *Game Engine Architecture* (book, 3rd ed.) | Broad reference for every subsystem. Its code is OOP C++, so read it for *what* systems exist, not *how* to structure them. | all |
| Handmade Hero (Casey Muratori) — https://guide.handmadehero.org/ | A full game built from scratch on stream, with no libraries. Days ~21–25 cover hot-loading game code. Searchable episode guide. | all |

## Immediate-mode UI

| Source | Why it matters here | Phase |
|---|---|---|
| Ryan Fleury, *UI series* (starting with *The Interaction Medium*) — https://www.rfleury.com/p/ui-part-1-the-interaction-medium | The most thorough modern write-up of building an IMGUI with automatic layout. Blueprint for our own editor UI. | 1–2 |
| Omar Cornut, *About the IMGUI paradigm* (Dear ImGui wiki) — https://github.com/ocornut/imgui/wiki/About-the-IMGUI-paradigm | Clears up what "immediate mode" does and doesn't mean (it still retains state internally). | 1 |
| `vendor:microui` (ships with Odin) | ~1000-line IMGUI; read the source before writing ours. | 1 |

## Rendering: GPU APIs, wgpu, WGSL

| Source | Why it matters here | Phase |
|---|---|---|
| *WebGPU Fundamentals* — https://webgpufundamentals.org/ | Best tutorial series for the API we use. Written for JS, but the calls map one-to-one onto `vendor:wgpu`. | 1 |
| *Learn Wgpu* — https://sotrh.github.io/learn-wgpu/ | Same API through Rust's wgpu; good for depth buffers, cameras, instancing, lighting. | 1 |
| WebGPU spec — https://www.w3.org/TR/webgpu/ and WGSL spec — https://www.w3.org/TR/WGSL/ | Authoritative answers on validation rules, limits, binding layouts. | 1+ |
| Odin examples, `wgpu/` (sdl3-triangle, microui) — https://github.com/odin-lang/examples/tree/master/wgpu | Known-good v29 API usage in Odin, including the web build. | 1 |
| Fabian Giesen, *A trip through the Graphics Pipeline 2011* — https://fgiesen.wordpress.com/2011/07/09/a-trip-through-the-graphics-pipeline-2011-index/ | What actually happens between a draw call and pixels. | 1 |
| Nathan Reed, *Depth Precision Visualized* — https://www.reedbeta.com/blog/depth-precision-visualized/ | Why we use reverse-Z with a 32-bit float depth buffer. | 1 |
| Ben Golus, *The Best Darn Grid Shader (Yet)* — https://bgolus.medium.com/the-best-darn-grid-shader-yet-727f9278b9d8 | Anti-aliased infinite ground grid for the editor viewport. | 1 |
| Dmitry Sokolov, *tinyrenderer* — https://github.com/ssloy/tinyrenderer/wiki | Software rasterizer in ~500 lines. Optional side project to demystify the GPU. | 1 |
| Stefan Reinalter, *Stateless, layered, multi-threaded rendering* — https://blog.molecular-matters.com/2014/11/06/stateless-layered-multi-threaded-rendering-part-1/ | Draw commands as plain data plus sort keys; extends Ericson's article. | 4 |
| Yuriy O'Donnell, *FrameGraph: Extensible Rendering Architecture in Frostbite* (GDC 2017) — https://www.slideshare.net/DICEStudio/framegraph-extensible-rendering-architecture-in-frostbite | Render passes and resources as a graph. Phase 4, once there are shadows and post-processing. | 4 |
| AMD, *FidelityFX Super Resolution 1* (source and docs) — https://github.com/GPUOpen-Effects/FidelityFX-FSR | EASU + RCAS, ported in `shaders/post.wgsl`. The header comments in `ffx_fsr1.h` explain input requirements (anti-aliased, perceptual color) and the algorithm. | 4 |
| Google, *Filament* PBR documentation — https://google.github.io/filament/Filament.html | Clearest practical PBR derivation; drop-in BRDF code. | 4 |
| Akenine-Möller et al., *Real-Time Rendering* (book, 4th ed.) — https://www.realtimerendering.com/ | The reference for real-time graphics. | all |
| Pharr, Jakob, Humphreys, *Physically Based Rendering* (free online) — https://pbr-book.org/ | Path tracing and light transport, if the path-tracer route appeals. | later |

## Meshes and geometry (the modeler)

| Source | Why it matters here | Phase |
|---|---|---|
| Blender, *Mesh Struct of Arrays Refactor* — https://projects.blender.org/blender/blender/issues/95965 (faces: #95967, corners: #102359) | A production modeler's move from array-of-structs to SoA: face offsets plus `corner_verts` / `corner_edges`. Our mesh layout follows it. | 2 |
| Botsch, Kobbelt, Pauly, Alliez, Lévy, *Polygon Mesh Processing* (book) — http://www.pmp-book.org/ | Mesh data structures (half-edge and others), smoothing, remeshing, simplification. | 2 |
| Catmull & Clark, *Recursively generated B-spline surfaces on arbitrary topological meshes* (1978, paper) | The subdivision scheme every modeler ships. | 2 |
| Möller & Trumbore, *Fast, Minimum Storage Ray/Triangle Intersection* (1997, paper) | The ray-triangle test used for picking. | 2 |
| Jacco Bikker, *How to build a BVH* (series) — https://jacco.ompf2.com/2022/04/13/how-to-build-a-bvh-part-1-basics/ | Fast picking and ray casts on dense meshes; written in a data-oriented style. | 2 |
| Christer Ericson, *Real-Time Collision Detection* (book) | Every intersection test, plus spatial structures. Also the physics groundwork for phase 3. | 2–3 |
| Garland & Heckbert, *Surface Simplification Using Quadric Error Metrics* (1997, paper) | Decimation / LOD generation. | later |
| **Booleans:** Thibault & Naylor, *Set Operations on Polyhedra Using BSP Trees* (SIGGRAPH 1987, paper) | The BSP approach your friend's C++ repo uses: simple but fragile with floats. | 2 |
| **Booleans:** Shewchuk, *Robust Adaptive Floating-Point Geometric Predicates* — https://www.cs.cmu.edu/~quake/robust.html | Exact orientation tests; the foundation of every robust boolean. | 2 |
| **Booleans:** Zhou, Grinspun, Zorin, Jacobson, *Mesh Arrangements for Solid Geometry* (SIGGRAPH 2016) — https://www.cs.columbia.edu/cg/mesh-arrangements/ | Robust booleans via mesh arrangements (exact arithmetic). | 2 |
| **Booleans:** Cherchi, Pellacini, Attene, Livesu, *Interactive and Robust Mesh Booleans* (ACM TOG 2022) — https://arxiv.org/abs/2205.14151 | First robust boolean method fast enough for interactive use (up to ~200K triangles). The target if we do booleans properly. | 2 |
| **Booleans:** Manifold (Emmett Lalish) — https://github.com/elalish/manifold | Production robust-boolean library (now a Blender solver). A reference implementation and a source of test cases. | 2 |

## Style guides and coding rules

There is no official Odin style guide. The conventions below come from the core library itself
(`Allocator_Error`, `Raw_Dynamic_Array`, `.Out_Of_Memory`, `WHOLE_SIZE`, `append_soa_elem`).

| Source | What we'd take from it |
|---|---|
| Odin core library conventions; *Odin Overview* — https://odin-lang.org/docs/overview/ | `Ada_Case` types and enum members, `snake_case` procedures and variables, `SCREAMING_SNAKE_CASE` constants, one package per directory. |
| Karl Zylinski, *Understanding the Odin Programming Language* (book) — https://odinbook.com | Idiomatic Odin: allocators, `context`, `#soa`, tagged unions, error handling with multiple returns. |
| TigerBeetle, *TIGER_STYLE* — https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md | Assertions as documentation (assert pre/postconditions), put a limit on everything (fixed capacities, bounded loops), no allocation after startup in hot paths, back-of-envelope performance sketches before coding. |
| Gerard Holzmann, *The Power of 10: Rules for Developing Safety-Critical Code* (NASA JPL) — https://spinroot.com/gerard/pdf/P10.pdf | The origin of several TigerStyle rules: simple control flow, bounded loops, no dynamic allocation after initialization, high assertion density. Too strict to adopt wholesale, but a useful influence. |
| Casey Muratori, *Semantic Compression* (above) and John Carmack, *On inlined code* (above) | Prefer long, straight procedures over tiny helpers; abstract only after repetition. |

## Reference codebases

Read these alongside the articles to see the ideas at full scale.

| Codebase | What to look at |
|---|---|
| Odin core library (in your install: `%LOCALAPPDATA%\Programs\odin\core`) | Idiomatic Odin; `core:mem` allocators, `core:container`. |
| RAD Debugger (Epic Games, C) — https://github.com/EpicGamesExt/raddebugger | Ryan Fleury's codebase: arenas everywhere, IMGUI, a large application with no OOP. |
| sokol (Andre Weissflog, C) — https://github.com/floooh/sokol | Handle-based resource pools in `sokol_gfx.h`. |
| Dear ImGui (C++) — https://github.com/ocornut/imgui | The most widely used IMGUI. |
| Blender mesh code (`source/blender/blenkernel`, `BKE_mesh*`) | The SoA mesh after the refactor above. |
| Your friend's Modeler3D (C++) — https://github.com/EmilianoManaloIV/3D-Modeling-Engine-Clause-Project- | Feature reference and test cases (exact volumes, closed-mesh checks) for porting modeling operations. |
| Odin examples — https://github.com/odin-lang/examples | Small working programs for SDL3, wgpu, Vulkan, Metal, D3D. |

---

*Links checked October 2026. The GDC Vault and Medium links may need an account or may move.*
