// The game: everything that hot-reloads. Built as a DLL and driven by the host (src/host).
//
// All state that must survive a reload lives in Game_Memory, which the game allocates once and
// the host hands back to each newly loaded DLL. `game_memory` is the only global, and it's just
// a pointer to that block.
//
// Exported procedures are called with the host's `context`, so allocations made here use the
// host's allocators, which never unload. The host frees context.temp_allocator after every
// frame.
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "engine:core"
import "engine:platform"
import "engine:render"

Game_Memory :: struct {
	window:         platform.Native_Window,
	renderer:       render.Renderer,
	camera:         Viewport_Camera,
	cube_mesh:      render.Mesh_Handle,
	elapsed_seconds: f64,
}

game_memory: ^Game_Memory

@(export)
game_init :: proc(window: platform.Native_Window, window_size: [2]i32) -> bool {
	game_memory = new(Game_Memory)
	game_memory.window = window
	if !render.init(&game_memory.renderer, window, window_size) {
		return false
	}

	game_memory.camera = {
		pivot        = {0, 0.5, 0},
		yaw          = math.to_radians(f32(35)),
		pitch        = math.to_radians(f32(25)),
		distance     = 7,
		vertical_fov = math.to_radians(f32(50)),
	}

	// Build the cube on the CPU in the engine's mesh format, triangulate it for flat shading,
	// and upload it. The CPU copies are temporary; only the GPU mesh is kept.
	cube := core.make_cube(1, context.temp_allocator)
	positions, normals, indices := core.flat_shaded_triangles(cube, context.temp_allocator)
	game_memory.cube_mesh = render.create_mesh(&game_memory.renderer, positions, normals, indices)
	return true
}

// Runs one frame. Returns false when the game wants to quit.
@(export)
game_update :: proc(input: ^platform.Input) -> bool {
	if input.quit || input.keys[.Escape].pressed {
		return false
	}
	game_memory.elapsed_seconds += f64(input.delta_seconds)
	update_viewport_camera(&game_memory.camera, input)

	renderer := &game_memory.renderer
	render.begin_frame(renderer, input.window_size)

	// Test scene: three cubes using one mesh. The renderer sorts them together and submits them
	// as a single instanced draw call.
	seconds := f32(game_memory.elapsed_seconds)
	render.draw_mesh(
		renderer,
		game_memory.cube_mesh,
		linalg.matrix4_translate_f32({0, 0.5, 0}),
		{0.8, 0.8, 0.82, 1},
	)
	render.draw_mesh(
		renderer,
		game_memory.cube_mesh,
		linalg.matrix4_translate_f32({2.5, 0.75, 0}) *
		linalg.matrix4_rotate_f32(seconds, core.WORLD_UP) *
		linalg.matrix4_scale_f32({1.5, 1.5, 1.5}),
		{0.85, 0.35, 0.2, 1},
	)
	render.draw_mesh(
		renderer,
		game_memory.cube_mesh,
		linalg.matrix4_translate_f32({-2.5, 1, 0}) *
		linalg.matrix4_rotate_f32(seconds * 0.7, linalg.normalize([3]f32{1, 1, 0})) *
		linalg.matrix4_scale_f32({0.5, 2, 0.5}),
		{0.2, 0.55, 0.85, 1},
	)

	// The grid shows the X (red) and Z (blue) axes; add the vertical Y axis in green.
	render.debug_line(renderer, {0, 0, 0}, {0, 2, 0}, {0.3, 0.85, 0.3, 1})

	eye := viewport_camera_eye(game_memory.camera)
	aspect_ratio := f32(input.window_size.x) / f32(max(input.window_size.y, 1))
	camera := render.Camera{
		view       = core.look_at(eye, game_memory.camera.pivot, core.WORLD_UP),
		projection = core.perspective_reverse_z(game_memory.camera.vertical_fov, aspect_ratio, 0.05),
		position   = eye,
	}
	render.end_frame(renderer, camera, {clear_color = {0.1, 0.105, 0.12, 1}, show_grid = true})
	return true
}

@(export)
game_shutdown :: proc() {
	render.shutdown(&game_memory.renderer)
	free(game_memory)
	game_memory = nil
}

@(export)
game_memory_pointer :: proc() -> rawptr {
	return game_memory
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(Game_Memory)
}

// Called on the newly loaded DLL instead of game_init: adopt the existing memory, then
// rebuild anything that was compiled into the DLL (shaders are embedded with #load).
@(export)
game_hot_reloaded :: proc(memory: rawptr) {
	game_memory = (^Game_Memory)(memory)
	render.reload_shaders(&game_memory.renderer)
	fmt.println("game: hot reloaded")
}
