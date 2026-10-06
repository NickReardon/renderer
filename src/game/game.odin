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
import "core:strconv"
import "core:strings"
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
	rendering_section_open: bool,
	stats_section_open:    bool,
	smoothed_frame_seconds: f32,

	// Rendering settings; the render scale comes from update_render_scale
	render_settings:       Render_Settings,
	render_scale:          f32, // the scale used this frame
	smoothed_gpu_milliseconds: f32,
	frames_since_scale_change: int,
}

// Render resolution: fixed mode renders at `fixed_scale_percent`; dynamic mode moves the scale
// between the minimum and maximum to keep GPU time within the target frame rate's budget. Below
// 100% the scene is upscaled (FSR 1 or bilinear); above 100% it is supersampled (rendered
// larger, filtered down). Anti-aliasing: 4x MSAA smooths geometry edges, and gives FSR the
// anti-aliased input it expects.
Render_Settings :: struct {
	dynamic_enabled:       bool,
	fixed_scale_percent:   f32,
	minimum_scale_percent: f32,
	maximum_scale_percent: f32,
	target_frame_rate:     f32, // 0 = match the display's refresh rate
	use_fsr:               bool, // off: bilinear upscaling
	sharpness:             f32,  // 0..1, mapped to FSR RCAS stops (1 = strongest)
	vsync:                 bool,
	msaa:                  bool, // 4x multisample anti-aliasing
}

SCALE_ADJUST_INTERVAL_FRAMES :: 8 // let a few new GPU measurements arrive between adjustments

game_memory: ^Game_Memory

@(export)
game_init :: proc(window: platform.Native_Window, window_size: [2]i32, arguments: []string) -> bool {
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
	game_memory.rendering_section_open = true
	game_memory.stats_section_open = true
	game_memory.render_settings = {
		dynamic_enabled       = false,
		fixed_scale_percent   = 100,
		minimum_scale_percent = 50,
		maximum_scale_percent = 200,
		target_frame_rate     = 0,
		use_fsr               = true,
		sharpness             = 0.8,
		vsync                 = true,
		msaa                  = true,
	}
	apply_developer_flags(&game_memory.render_settings, arguments)
	game_memory.render_scale = game_memory.render_settings.fixed_scale_percent / 100

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

	update_render_scale(game_memory, input)
	render_settings := game_memory.render_settings
	captured_pixels := render.end_frame(renderer, camera, {
		clear_color     = {0.1, 0.105, 0.12, 1},
		show_grid       = game_memory.show_grid,
		capture         = input.capture_requested,
		render_scale    = game_memory.render_scale,
		upscaler        = .Fsr if render_settings.use_fsr else .Bilinear,
		sharpness_stops = (1 - clamp(render_settings.sharpness, 0, 1)) * 2, // 1 -> 0 stops (strongest), 0 -> 2 stops
		vsync           = render_settings.vsync,
		msaa_samples    = 4 if render_settings.msaa else 1,
	})
	if captured_pixels != nil {
		save_screenshot("screenshot.bmp", captured_pixels, renderer.surface_size)
	}
	return true
}

// Picks this frame's render scale: the fixed setting, or the dynamic controller's choice based on
// recent GPU frame time and the target frame rate.
update_render_scale :: proc(memory: ^Game_Memory, input: ^platform.Input) {
	settings := &memory.render_settings
	if !settings.dynamic_enabled {
		memory.render_scale = settings.fixed_scale_percent / 100
		memory.frames_since_scale_change = 0
		return
	}

	gpu_milliseconds := memory.renderer.gpu_frame_milliseconds
	if gpu_milliseconds <= 0 {
		return // no measurement yet (or this GPU can't measure): keep the current scale
	}
	if memory.smoothed_gpu_milliseconds == 0 {
		memory.smoothed_gpu_milliseconds = gpu_milliseconds
	}
	memory.smoothed_gpu_milliseconds = math.lerp(memory.smoothed_gpu_milliseconds, gpu_milliseconds, f32(0.2))

	memory.frames_since_scale_change += 1
	if memory.frames_since_scale_change < SCALE_ADJUST_INTERVAL_FRAMES {
		return
	}
	memory.frames_since_scale_change = 0
	frame_budget_milliseconds := 1000 / effective_target_frame_rate(settings^, input)
	minimum_scale := min(settings.minimum_scale_percent, settings.maximum_scale_percent) / 100
	maximum_scale := max(settings.minimum_scale_percent, settings.maximum_scale_percent) / 100
	memory.render_scale = core.next_render_scale(memory.render_scale, memory.smoothed_gpu_milliseconds, frame_budget_milliseconds, minimum_scale, maximum_scale)
}

effective_target_frame_rate :: proc(settings: Render_Settings, input: ^platform.Input) -> f32 {
	if settings.target_frame_rate > 0 {
		return settings.target_frame_rate
	}
	return input.refresh_rate if input.refresh_rate > 0 else 60
}

// Developer flags for scripted checks (e.g. with --screenshot):
//   --render-scale=50    fixed render scale in percent
//   --target-fps=120     dynamic resolution's target frame rate
//   --upscaler=bilinear  bilinear instead of FSR
//   --dynamic            dynamic resolution on
//   --msaa=off           no multisample anti-aliasing
apply_developer_flags :: proc(settings: ^Render_Settings, arguments: []string) {
	for argument in arguments {
		if strings.has_prefix(argument, "--render-scale=") {
			value := argument[len("--render-scale="):]
			if percent, parsed := strconv.parse_f32(value); parsed {
				settings.fixed_scale_percent = clamp(percent, 50, 200)
			}
		} else if strings.has_prefix(argument, "--target-fps=") {
			if frame_rate, parsed := strconv.parse_f32(argument[len("--target-fps="):]); parsed {
				settings.target_frame_rate = clamp(frame_rate, 20, 10000)
			}
		} else if argument == "--msaa=off" {
			settings.msaa = false
		} else if argument == "--upscaler=bilinear" {
			settings.use_fsr = false
		} else if argument == "--dynamic" {
			settings.dynamic_enabled = true
		}
	}
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

		if ui.section(user_interface, "Rendering", &memory.rendering_section_open) {
			settings := &memory.render_settings
			ui.checkbox(user_interface, "VSync", &settings.vsync)
			ui.checkbox(user_interface, "MSAA 4×", &settings.msaa)
			ui.checkbox(user_interface, "Dynamic resolution", &settings.dynamic_enabled)
			if settings.dynamic_enabled {
				target := effective_target_frame_rate(settings^, input)
				if ui.number_field(user_interface, "Target fps", &target, 0.5, 20, 500, "%.0f") {
					settings.target_frame_rate = target
				}
				ui.number_field(user_interface, "Minimum scale", &settings.minimum_scale_percent, 0.5, 50, 200, "%.0f%%")
				ui.number_field(user_interface, "Maximum scale", &settings.maximum_scale_percent, 0.5, 50, 200, "%.0f%%")
			} else {
				ui.number_field(user_interface, "Render scale", &settings.fixed_scale_percent, 0.5, 50, 200, "%.0f%%")
			}
			ui.checkbox(user_interface, "FSR upscaling (off: bilinear)", &settings.use_fsr)
			if settings.use_fsr {
				ui.number_field(user_interface, "Sharpness", &settings.sharpness, 0.005, 0, 1, "%.2f")
			}
		}

		if ui.section(user_interface, "Statistics", &memory.stats_section_open) {
			frame_milliseconds := memory.smoothed_frame_seconds * 1000
			frames_per_second := 1 / max(memory.smoothed_frame_seconds, 0.0001)
			ui.label(user_interface, fmt.tprintf("frame   %.2f ms", frame_milliseconds), .Monospace)
			ui.label(user_interface, fmt.tprintf("fps     %.0f", frames_per_second), .Monospace)
			if memory.renderer.gpu_frame_milliseconds > 0 {
				ui.label(user_interface, fmt.tprintf("gpu     %.2f ms", memory.renderer.gpu_frame_milliseconds), .Monospace)
			} else {
				ui.label(user_interface, "gpu     n/a", .Monospace)
			}
			render_size := memory.renderer.render_size
			ui.label(user_interface, fmt.tprintf("render  %d × %d (%.0f%%)", render_size.x, render_size.y, memory.render_scale * 100), .Monospace)
			mode_text := "native"
			if memory.render_scale < 0.999 {
				mode_text = "FSR 1 upscale" if memory.render_settings.use_fsr else "bilinear upscale"
			} else if memory.render_scale > 1.001 {
				mode_text = "supersampling"
			}
			ui.label(user_interface, fmt.tprintf("mode    %s", mode_text), .Monospace)
			ui.label(user_interface, fmt.tprintf("aa      %s", "MSAA 4×" if memory.render_settings.msaa else "off"), .Monospace)
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
