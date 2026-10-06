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

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/bmp"
import "core:math"
import "core:math/linalg"
import "engine:core"
import "engine:platform"
import "engine:render"
import "engine:ui"

Game_Memory :: struct {
	window:                platform.Native_Window,
	renderer:              render.Renderer,
	user_interface:        ui.Ui_State,
	camera:                Viewport_Camera,
	cube_mesh:             render.Mesh_Handle,
	elapsed_seconds:       f64,
	animation_seconds:     f64, // advances by rotation_speed, so the cubes can be paused

	// Editor settings
	show_grid:             bool,
	rotation_speed:        f32,
	view_section_open:     bool,
	camera_section_open:   bool,
	scene_section_open:    bool,
	stats_section_open:    bool,
	smoothed_frame_seconds: f32,
}

game_memory: ^Game_Memory

@(export)
game_init :: proc(window: platform.Native_Window, window_size: [2]i32) -> bool {
	game_memory = new(Game_Memory)
	game_memory.window = window
	if !render.init(&game_memory.renderer, window, window_size) {
		return false
	}
	if !ui.init(&game_memory.user_interface, window_size) {
		return false
	}

	game_memory.camera = default_viewport_camera()
	game_memory.show_grid = true
	game_memory.rotation_speed = 1
	game_memory.view_section_open = true
	game_memory.camera_section_open = true
	game_memory.scene_section_open = true
	game_memory.stats_section_open = true

	// Build the cube on the CPU in the engine's mesh format, triangulate it for flat shading,
	// and upload it. The CPU copies are temporary; only the GPU mesh is kept.
	cube := core.make_cube(1, context.temp_allocator)
	positions, normals, indices := core.flat_shaded_triangles(cube, context.temp_allocator)
	game_memory.cube_mesh = render.create_mesh(&game_memory.renderer, positions, normals, indices)
	return true
}

default_viewport_camera :: proc() -> Viewport_Camera {
	return {
		pivot        = {0, 0.5, 0},
		yaw          = math.to_radians(f32(35)),
		pitch        = math.to_radians(f32(25)),
		distance     = 7,
		vertical_fov = math.to_radians(f32(50)),
	}
}

// Runs one frame. Returns false when the game wants to quit.
@(export)
game_update :: proc(input: ^platform.Input) -> bool {
	renderer := &game_memory.renderer
	user_interface := &game_memory.user_interface

	render.begin_frame(renderer, input.window_size)
	ui.begin_frame(user_interface, input)
	draw_editor_ui(game_memory, input)

	// The viewport only gets the mouse and keyboard when the UI isn't using them.
	if input.quit || (input.keys[.Escape].pressed && !ui.wants_keyboard(user_interface)) {
		return false
	}
	viewport_input := input^
	if ui.wants_mouse(user_interface) {
		viewport_input.mouse = {}
		viewport_input.mouse_delta = {}
		viewport_input.wheel = 0
	}
	if ui.wants_keyboard(user_interface) {
		viewport_input.keys = {}
	}
	update_viewport_camera(&game_memory.camera, &viewport_input)

	game_memory.elapsed_seconds += f64(input.delta_seconds)
	game_memory.animation_seconds += f64(input.delta_seconds * game_memory.rotation_speed)
	// Exponential moving average of frame time, seeded with the first frame so it doesn't creep
	// up from zero.
	frame_seconds_blend :: 0.05
	if game_memory.smoothed_frame_seconds == 0 {
		game_memory.smoothed_frame_seconds = input.delta_seconds
	}
	game_memory.smoothed_frame_seconds = math.lerp(game_memory.smoothed_frame_seconds, input.delta_seconds, f32(frame_seconds_blend))

	// Test scene: three cubes using one mesh. The renderer sorts them together and submits them
	// as a single instanced draw call.
	seconds := f32(game_memory.animation_seconds)
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

	ui.end_frame(user_interface, renderer)

	// The 3D view fills the space the UI layout left for it.
	viewport_min, viewport_max, viewport_found := ui.area_rect(user_interface, VIEWPORT_AREA)
	if !viewport_found {
		viewport_min, viewport_max = {0, 0}, {f32(input.window_size.x), f32(input.window_size.y)}
	}
	viewport_size := viewport_max - viewport_min
	aspect_ratio := viewport_size.x / max(viewport_size.y, 1)
	eye := viewport_camera_eye(game_memory.camera)
	camera := render.Camera{
		view         = core.look_at(eye, game_memory.camera.pivot, core.WORLD_UP),
		projection   = core.perspective_reverse_z(game_memory.camera.vertical_fov, max(aspect_ratio, 0.01), 0.05),
		position     = eye,
		viewport_min = viewport_min,
		viewport_max = viewport_max,
	}

	captured_pixels := render.end_frame(renderer, camera, {
		clear_color = {0.1, 0.105, 0.12, 1},
		show_grid   = game_memory.show_grid,
		capture     = input.capture_requested,
	})
	if captured_pixels != nil {
		save_screenshot("screenshot.bmp", captured_pixels, renderer.surface_size)
	}
	return true
}

// Writes an RGBA8 frame to a BMP file (Odin's core library writes BMP; no extra dependency).
save_screenshot :: proc(path: string, rgba_pixels: []u8, size: [2]i32) {
	screenshot := image.Image{width = int(size.x), height = int(size.y), channels = 4, depth = 8}
	bytes.buffer_init(&screenshot.pixels, rgba_pixels)
	defer bytes.buffer_destroy(&screenshot.pixels)
	if save_error := bmp.save_to_file(path, &screenshot, allocator = context.temp_allocator); save_error != nil {
		fmt.eprintfln("game: saving %s failed: %v", path, save_error)
		return
	}
	fmt.printfln("game: saved %s (%d x %d)", path, size.x, size.y)
}

// The editor's panels, declared every frame (immediate mode). Values edited here take effect in
// this same frame.
VIEWPORT_AREA :: "Viewport"

draw_editor_ui :: proc(memory: ^Game_Memory, input: ^platform.Input) {
	user_interface := &memory.user_interface
	ui.flexible_space(user_interface, VIEWPORT_AREA) // the 3D view's share of the window
	if ui.panel(user_interface, "Inspector", 300) {
		if ui.section(user_interface, "View", &memory.view_section_open) {
			ui.checkbox(user_interface, "Show grid", &memory.show_grid)
			field_of_view_degrees := math.to_degrees(memory.camera.vertical_fov)
			if ui.number_field(user_interface, "Field of view", &field_of_view_degrees, 0.2, 10, 120, "%.1f°") {
				memory.camera.vertical_fov = math.to_radians(field_of_view_degrees)
			}
		}

		if ui.section(user_interface, "Camera", &memory.camera_section_open) {
			yaw_degrees := math.to_degrees(memory.camera.yaw)
			if ui.number_field(user_interface, "Yaw", &yaw_degrees, 0.5, display_format = "%.1f°") {
				memory.camera.yaw = math.to_radians(yaw_degrees)
			}
			pitch_degrees := math.to_degrees(memory.camera.pitch)
			if ui.number_field(user_interface, "Pitch", &pitch_degrees, 0.5, -89, 89, "%.1f°") {
				memory.camera.pitch = math.to_radians(pitch_degrees)
			}
			ui.number_field(user_interface, "Distance", &memory.camera.distance, 0.05, 0.1, 1000, "%.2f")
			ui.number_field(user_interface, "Pivot X", &memory.camera.pivot.x, 0.02, display_format = "%.2f")
			ui.number_field(user_interface, "Pivot Y", &memory.camera.pivot.y, 0.02, display_format = "%.2f")
			ui.number_field(user_interface, "Pivot Z", &memory.camera.pivot.z, 0.02, display_format = "%.2f")
			if ui.button(user_interface, "Reset camera") {
				memory.camera = default_viewport_camera()
			}
		}

		if ui.section(user_interface, "Scene", &memory.scene_section_open) {
			ui.number_field(user_interface, "Rotation speed", &memory.rotation_speed, 0.01, -10, 10, "%.2f")
		}

		if ui.section(user_interface, "Statistics", &memory.stats_section_open) {
			frame_milliseconds := memory.smoothed_frame_seconds * 1000
			frames_per_second := 1 / max(memory.smoothed_frame_seconds, 0.0001)
			ui.label(user_interface, fmt.tprintf("frame   %.2f ms", frame_milliseconds), .Monospace)
			ui.label(user_interface, fmt.tprintf("fps     %.0f", frames_per_second), .Monospace)
			ui.label(user_interface, fmt.tprintf("window  %d × %d", input.window_size.x, input.window_size.y), .Monospace)
			ui.label(user_interface, fmt.tprintf("scale   %.2f", input.display_scale), .Monospace)
		}
	}
}

@(export)
game_shutdown :: proc() {
	ui.shutdown(&game_memory.user_interface)
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
// rebuild anything that was compiled into the DLL (shaders are embedded with #load) and
// reconnect libraries whose globals live in the DLL (Clay).
@(export)
game_hot_reloaded :: proc(memory: rawptr) {
	game_memory = (^Game_Memory)(memory)
	render.reload_shaders(&game_memory.renderer)
	ui.on_hot_reload(&game_memory.user_interface)
	fmt.println("game: hot reloaded")
}
