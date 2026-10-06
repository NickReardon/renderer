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
	scene:                 Scene,
	editor:                Editor_State,
	gizmo:                 Gizmo_State,
	undo_history:          Undo_History,
	elapsed_seconds:       f64,
	viewport_min:          [2]f32, // the 3D view's rectangle in the last frame's layout (pixels)
	viewport_max:          [2]f32,

	// Editor settings
	show_grid:             bool,
	view_section_open:     bool,
	camera_section_open:   bool,
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
	low_latency:           bool, // with vsync: read input just before the display is ready
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
	game_memory.stats_section_open = true
	game_memory.editor = {hierarchy_open = true, create_section_open = true, transform_section_open = true}
	game_memory.gizmo.tool = .Move // Unity starts with the Move tool
	game_memory.render_settings = {
		dynamic_enabled       = false,
		fixed_scale_percent   = 100,
		minimum_scale_percent = 50,
		maximum_scale_percent = 200,
		target_frame_rate     = 0,
		use_fsr               = true,
		sharpness             = 0.8,
		vsync                 = true,
		low_latency           = true,
		msaa                  = true,
	}
	apply_developer_flags(&game_memory.render_settings, arguments)
	game_memory.render_scale = game_memory.render_settings.fixed_scale_percent / 100

	// A starting scene: one of each solid primitive.
	scene := &game_memory.scene
	scene_init(scene, &game_memory.renderer)
	create_primitive_entity(scene, .Cube, {0, 0.5, 0}, {0.8, 0.8, 0.82})
	create_primitive_entity(scene, .Sphere, {2.2, 0.5, 0}, {0.85, 0.35, 0.2})
	create_primitive_entity(scene, .Cylinder, {-2.2, 1, 0}, {0.2, 0.55, 0.85})
	apply_scene_developer_flags(scene, arguments)
	reset_undo_history(&game_memory.undo_history, scene) // the starting scene isn't an undoable step
	for argument in arguments {
		switch argument {
		case "--tool=hand":
			game_memory.gizmo.tool = .Hand
		case "--tool=move":
			game_memory.gizmo.tool = .Move
		case "--tool=rotate":
			game_memory.gizmo.tool = .Rotate
		case "--tool=scale":
			game_memory.gizmo.tool = .Scale
		case "--local":
			game_memory.gizmo.local_orientation = true
		case "--center":
			game_memory.gizmo.handle_position = .Center
		}
	}
	return true
}

// Developer flags that change the starting scene, for checking edge cases with --screenshot:
//   --mirror=Cube    scale X = -1 (a mirrored transform must still show its outside)
//   --flatten=Cube   scale Y = 0 (a zero scale must not break normals or picking)
apply_scene_developer_flags :: proc(scene: ^Scene, arguments: []string) {
	for argument in arguments {
		target_name: string
		mirror := false
		if strings.has_prefix(argument, "--mirror=") {
			target_name, mirror = argument[len("--mirror="):], true
		} else if strings.has_prefix(argument, "--flatten=") {
			target_name = argument[len("--flatten="):]
		} else {
			continue
		}
		for slot_index in 1 ..= scene.highest_entity_slot {
			entity := &scene.entities[slot_index]
			if .Alive in entity.flags && entity_name(entity) == target_name {
				if mirror {
					entity.scale.x = -entity.scale.x
				} else {
					entity.scale.y = 0
				}
			}
		}
	}
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
	if input.quit {
		return false
	}
	renderer := &game_memory.renderer
	user_interface := &game_memory.user_interface

	render.begin_frame(renderer, input.window_size)
	ui.begin_frame(user_interface, input)
	draw_editor_ui(game_memory, input)
	// A typed Inspector value is a finished edit, even when it was applied by pressing the mouse
	// on something else. Record it now, before that press starts its own action (a button's
	// click, a drag), or the two would share one undo step.
	if ui.typed_value_applied(user_interface) {
		commit_undo_step(&game_memory.undo_history, &game_memory.scene)
	}

	// The 3D view only gets the mouse and keyboard when the UI isn't using them.
	viewport_has_mouse := !ui.wants_mouse(user_interface)
	viewport_has_keyboard := !ui.wants_keyboard(user_interface)
	viewport_input := input^
	if !viewport_has_mouse {
		viewport_input.mouse = {}
		viewport_input.mouse_delta = {}
		viewport_input.wheel = 0
	}
	if !viewport_has_keyboard {
		viewport_input.keys = {}
	}
	// Hand tool (Q): the left button pans like the middle one, and doesn't select (as in Unity).
	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down
	if game_memory.gizmo.tool == .Hand && !alt_held {
		viewport_input.mouse[.Middle] = viewport_input.mouse[.Left]
		viewport_input.mouse[.Left] = {}
	}
	update_editor(game_memory, input, &viewport_input, viewport_has_mouse, viewport_has_keyboard)
	update_viewport_camera(&game_memory.camera, &viewport_input)
	// Record this frame's edits as an undo step, unless one is still in progress: a drag (gizmo
	// or number field) or typing in a field. Those are recorded once they finish.
	if !edit_in_progress(game_memory, input) {
		commit_undo_step(&game_memory.undo_history, &game_memory.scene)
	}

	game_memory.elapsed_seconds += f64(input.delta_seconds)
	// Exponential moving average of frame time, seeded with the first frame so it doesn't creep
	// up from zero.
	frame_seconds_blend :: 0.05
	if game_memory.smoothed_frame_seconds == 0 {
		game_memory.smoothed_frame_seconds = input.delta_seconds
	}
	game_memory.smoothed_frame_seconds = math.lerp(game_memory.smoothed_frame_seconds, input.delta_seconds, f32(frame_seconds_blend))

	// Draw every entity with a mesh. Entities sharing a mesh are batched into instanced draws by
	// the renderer.
	scene := &game_memory.scene
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if !(.Alive in entity.flags) || !(.Has_Mesh in entity.flags) {
			continue
		}
		if asset, found := get_mesh_asset(scene, entity.mesh); found {
			render.draw_mesh(renderer, asset.gpu_mesh, entity_world_matrix(entity), {entity.color.r, entity.color.g, entity.color.b, 1})
		}
	}
	draw_selection_outlines(game_memory, renderer)
	draw_gizmo(game_memory, renderer) // before ui.end_frame, so panels draw over it

	// The grid shows the X (red) and Z (blue) axes; add the vertical Y axis in green.
	render.debug_line(renderer, {0, 0, 0}, {0, 2, 0}, {0.3, 0.85, 0.3, 1})

	ui.end_frame(user_interface, renderer)

	// The 3D view fills the space the UI layout left for it. Picking uses this rectangle next
	// frame, matching what was on screen when the user clicked.
	viewport_min, viewport_max, viewport_found := ui.area_rect(user_interface, VIEWPORT_AREA)
	if !viewport_found {
		viewport_min, viewport_max = {0, 0}, {f32(input.window_size.x), f32(input.window_size.y)}
	}
	game_memory.viewport_min, game_memory.viewport_max = viewport_min, viewport_max
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
		low_latency     = render_settings.low_latency,
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
//   --pick-center-of=Sphere  click the named object's centre once the view is laid out
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
		} else if strings.has_prefix(argument, "--pick-center-of=") {
			editor := &game_memory.editor
			editor.developer_pick_name_length = copy(editor.developer_pick_name_bytes[:], argument[len("--pick-center-of="):])
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

// The editor's panels, declared every frame (immediate mode): Hierarchy on the left, the 3D view
// in the middle, Inspector on the right (Unity's default layout). Values edited here take
// effect in this same frame.
VIEWPORT_AREA :: "Viewport"

draw_editor_ui :: proc(memory: ^Game_Memory, input: ^platform.Input) {
	user_interface := &memory.user_interface
	draw_hierarchy_panel(memory, input)
	// The 3D view's share of the window, with Unity-style toolbars laid over its top edge.
	if ui.area(user_interface, VIEWPORT_AREA) {
		if ui.row(user_interface, "toolbars") {
			if ui.toolbar(user_interface, "tools") {
				tool_labels := TRANSFORM_TOOL_LABELS
				for tool in Transform_Tool {
					if ui.toggle_button(user_interface, tool_labels[tool], memory.gizmo.tool == tool) {
						memory.gizmo.tool = tool
					}
				}
			}
			if ui.toolbar(user_interface, "handle settings") {
				// Each button shows the current setting and switches it, as in Unity (Z, X).
				handle_position_labels := HANDLE_POSITION_LABELS
				if ui.toggle_button(user_interface, handle_position_labels[memory.gizmo.handle_position], false) {
					toggle_handle_position(&memory.gizmo)
				}
				// Scale always works in the object's own axes, so this only matters for Move and
				// Rotate.
				orientation_label := "Local" if memory.gizmo.local_orientation else "Global"
				if ui.toggle_button(user_interface, orientation_label, false) {
					memory.gizmo.local_orientation = !memory.gizmo.local_orientation
				}
			}
		}
	}
	if ui.panel(user_interface, "Inspector", 320) {
		draw_selection_inspector(memory)

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
			ui.vector3_field(user_interface, "Pivot", &memory.camera.pivot, 0.02, "%.2f")
			if ui.button(user_interface, "Reset camera") {
				memory.camera = default_viewport_camera()
			}
		}

		if ui.section(user_interface, "Rendering", &memory.rendering_section_open) {
			settings := &memory.render_settings
			ui.checkbox(user_interface, "VSync", &settings.vsync)
			if settings.vsync {
				ui.checkbox(user_interface, "Low latency", &settings.low_latency)
			}
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
			// Low-latency vsync: how long each frame sleeps before reading input, and how long it
			// still waits for the display afterwards (settles near 2 ms).
			ui.label(user_interface, fmt.tprintf("sleep   %.1f ms", render.frame_delay_milliseconds(&memory.renderer)), .Monospace)
			ui.label(user_interface, fmt.tprintf("wait    %.1f ms", memory.renderer.acquire_wait_milliseconds), .Monospace)
			object_count := 0
			for slot_index in 1 ..= memory.scene.highest_entity_slot {
				if .Alive in memory.scene.entities[slot_index].flags {
					object_count += 1
				}
			}
			ui.label(user_interface, fmt.tprintf("objects %d", object_count), .Monospace)
			undoable, redoable := undo_counts(&memory.undo_history)
			ui.label(user_interface, fmt.tprintf("undo    %d (redo %d)", undoable, redoable), .Monospace)
			ui.label(user_interface, fmt.tprintf("window  %d × %d", input.window_size.x, input.window_size.y), .Monospace)
		}
	}
}

@(export)
game_shutdown :: proc() {
	scene_shutdown(&game_memory.scene)
	ui.shutdown(&game_memory.user_interface)
	render.shutdown(&game_memory.renderer)
	free(game_memory)
	game_memory = nil
}

// Called by the host after each frame, before it reads input for the next: how long to sleep
// first (low-latency vsync, see core/frame_pacing.odin). The host does the sleeping because
// it has SDL's precise timer.
@(export)
game_frame_delay_milliseconds :: proc() -> f32 {
	return render.frame_delay_milliseconds(&game_memory.renderer)
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
