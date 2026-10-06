// Host executable: owns the OS window (SDL3), turns SDL events into platform.Input, and runs
// the game, which lives in a DLL that is hot-reloaded whenever `build.bat game` rebuilds it.
//
// How hot reload works (Handmade Hero days 21-25; Karl Zylinski, "Hot Reload Gameplay Code"):
//   - the game keeps all persistent state in one block (Game_Memory) that it allocates itself;
//   - when build/game.dll changes, the host copies it to a new name (so the build can keep
//     overwriting game.dll), loads the copy, and hands it the existing memory;
//   - if the size of Game_Memory changed, its layout changed, so the host restarts the game
//     instead (F6 forces a restart too);
//   - old DLLs stay loaded until exit, so anything still pointing into their code (callbacks
//     registered with wgpu, procedure pointers in data) stays valid.
//
// The game's procedures run with this file's `context`, so its allocators live here, in the
// executable that never reloads.
//
// This is the only package that touches SDL.
package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import "engine:platform"

// Procedures exported by the game DLL as `game_<field name>`.
Game_API :: struct {
	init:           proc(window: platform.Native_Window, window_size: [2]i32, arguments: []string) -> bool,
	update:         proc(input: ^platform.Input) -> bool,
	shutdown:       proc(),
	memory_pointer: proc() -> rawptr,
	memory_size:    proc() -> int,
	hot_reloaded:   proc(memory: rawptr),

	// Not looked up in the DLL (initialize_symbols only fills procedure and pointer fields).
	__handle:       dynlib.Library,
	modified_time:  time.Time,
	version:        int,
}

GAME_API_PROCEDURE_COUNT :: 6

main :: proc() {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window_flags: sdl.WindowFlags = {.RESIZABLE, .HIGH_PIXEL_DENSITY}
	when ODIN_OS == .Darwin {
		window_flags += {.METAL}
	}
	// Size the window in points: 1440 x 860 at 100% scaling, scaled up on high-DPI displays (on
	// Windows, window coordinates are pixels and the content scale carries the DPI; on macOS
	// they're points and the content scale is 1), but never more than 85% of the usable screen.
	DESIRED_WINDOW_POINTS :: [2]f32{1440, 860}
	primary_display := sdl.GetPrimaryDisplay()
	content_scale := sdl.GetDisplayContentScale(primary_display)
	window_size := DESIRED_WINDOW_POINTS * max(content_scale, 1)
	usable_bounds: sdl.Rect
	if sdl.GetDisplayUsableBounds(primary_display, &usable_bounds) {
		window_size.x = min(window_size.x, f32(usable_bounds.w) * 0.85)
		window_size.y = min(window_size.y, f32(usable_bounds.h) * 0.85)
	}
	window := sdl.CreateWindow("Renderer", i32(window_size.x), i32(window_size.y), window_flags)
	if window == nil {
		fmt.eprintln("SDL_CreateWindow failed:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// Deliver typed text (TEXT_INPUT events) for UI text fields. This also enables the OS input
	// method editor for languages typed through one.
	if !sdl.StartTextInput(window) {
		fmt.eprintln("host: SDL_StartTextInput failed:", sdl.GetError())
	}

	native, native_found := native_window(window)
	if !native_found {
		fmt.eprintln("host: can't get native handles for this window system")
		return
	}

	// The game DLL is built next to the executable.
	executable_directory := string(sdl.GetBasePath())
	game_library_path := fmt.aprintf("%sgame.%s", executable_directory, dynlib.LIBRARY_FILE_EXTENSION)

	game, game_loaded, _ := load_game_api(executable_directory, game_library_path, 0)
	if !game_loaded {
		return
	}
	initial_size := window_pixel_size(window)
	fmt.printfln("host: window %dx%d pixels (pixel density %.2f)", initial_size.x, initial_size.y, sdl.GetWindowPixelDensity(window))
	if !game.init(native, initial_size, os.args[1:]) {
		fmt.eprintln("host: game failed to initialize")
		return
	}
	next_version := 1
	rejected_modified_time: time.Time // a game.dll that failed to load; skipped until it changes
	previous_games: [dynamic]Game_API

	// Frame capture for checking rendering from scripts without capturing the desktop. The game
	// saves the frame to screenshot.bmp, then the host exits.
	//   --screenshot                 capture 30 frames after start
	//   --screenshot-after-reload    capture 30 frames after the first hot reload
	//   --screenshot-frame=N         capture N frames after the trigger instead of 30
	frames_before_screenshot := 30
	Screenshot_Mode :: enum {
		None,
		After_Start,
		After_Reload,
	}
	screenshot_mode := Screenshot_Mode.None
	for argument in os.args[1:] {
		switch {
		case argument == "--screenshot":
			screenshot_mode = .After_Start
		case argument == "--screenshot-after-reload":
			screenshot_mode = .After_Reload
		case strings.has_prefix(argument, "--screenshot-frame="):
			if frame_count, parsed := strconv.parse_int(argument[len("--screenshot-frame="):]); parsed && frame_count > 0 {
				frames_before_screenshot = frame_count
			}
		}
	}
	frames_since_trigger := 0
	screenshot_triggered := screenshot_mode == .After_Start

	input: platform.Input
	last_tick := time.tick_now()

	main_loop: for {
		if screenshot_triggered {
			frames_since_trigger += 1
		}
		input.capture_requested = screenshot_triggered && frames_since_trigger == frames_before_screenshot
		// Edges and per-frame deltas only last one frame.
		for &key in input.keys {
			key.pressed, key.released, key.repeated = false, false, false
		}
		for &button in input.mouse {
			button.pressed, button.released, button.repeated = false, false, false
		}
		input.mouse_delta = {}
		input.wheel = 0
		input.text_input_length = 0
		input.display_scale = sdl.GetWindowDisplayScale(window)
		input.refresh_rate = 0
		if display_mode := sdl.GetCurrentDisplayMode(sdl.GetDisplayForWindow(window)); display_mode != nil {
			input.refresh_rate = display_mode.refresh_rate
		}

		pixel_density := sdl.GetWindowPixelDensity(window)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			handle_event(&input, event, pixel_density)
		}
		input.window_size = window_pixel_size(window)
		if screenshot_mode != .None {
			// Scripted captures must be reproducible: ignore whatever the person at the computer
			// does with the mouse and keyboard while the window is open.
			input.keys = {}
			input.mouse = {}
			input.mouse_position = {-1, -1}
			input.mouse_delta = {}
			input.wheel = 0
			input.text_input_length = 0
		}

		now := time.tick_now()
		input.delta_seconds = f32(time.duration_seconds(time.tick_diff(last_tick, now)))
		last_tick = now

		if !game.update(&input) {
			break main_loop
		}
		free_all(context.temp_allocator)
		if input.capture_requested {
			break main_loop
		}

		// Hot reload: has the build replaced game.dll since we loaded it?
		modified_time, stat_error := os.modification_time_by_path(game_library_path)
		force_restart := input.keys[.F6].pressed
		changed_since_load := stat_error == nil && modified_time != game.modified_time && modified_time != rejected_modified_time
		if changed_since_load || force_restart {
			new_game, new_game_loaded, new_game_rejected := load_game_api(executable_directory, game_library_path, next_version)
			if !new_game_loaded {
				if new_game_rejected {
					rejected_modified_time = modified_time
					next_version += 1 // never reuse a name that might still be locked
				}
				continue
			}
			next_version += 1
			if force_restart || new_game.memory_size() != game.memory_size() {
				// Game_Memory's layout changed (or F6): start the game over with fresh state.
				fmt.println("host: restarting game")
				game.shutdown()
				append(&previous_games, game)
				game = new_game
				if !game.init(native, window_pixel_size(window), os.args[1:]) {
					fmt.eprintln("host: game failed to initialize after restart")
					break main_loop
				}
			} else {
				memory := game.memory_pointer()
				append(&previous_games, game)
				game = new_game
				game.hot_reloaded(memory)
			}
			if screenshot_mode == .After_Reload {
				screenshot_triggered = true
			}
		}
	}

	game.shutdown()
	unload_game_api(executable_directory, game)
	for previous_game in previous_games {
		unload_game_api(executable_directory, previous_game)
	}
}

// Copies game.dll to game_<version>.dll and loads the copy. Loading a copy leaves game.dll
// itself unlocked, so the next build can replace it while this one is running.
// `rejected` means the file was read but isn't a usable game library (missing exports): don't
// retry it until it changes. Other failures (e.g. the build still writing) are worth retrying.
load_game_api :: proc(executable_directory, game_library_path: string, version: int) -> (api: Game_API, loaded: bool, rejected: bool) {
	modified_time, stat_error := os.modification_time_by_path(game_library_path)
	if stat_error != nil {
		fmt.eprintfln("host: can't find %s: %v", game_library_path, stat_error)
		return
	}
	copy_path := versioned_game_path(executable_directory, version)
	if copy_error := os.copy_file(copy_path, game_library_path); copy_error != nil {
		// Usually means the build is still writing; the next frame will try again.
		fmt.eprintfln("host: can't copy %s: %v", game_library_path, copy_error)
		return
	}
	symbol_count, symbols_loaded := dynlib.initialize_symbols(&api, copy_path, "game_", "__handle")
	if !symbols_loaded || symbol_count != GAME_API_PROCEDURE_COUNT {
		fmt.eprintfln(
			"host: loading %s found %d of %d procedures: %s",
			copy_path,
			max(symbol_count, 0),
			GAME_API_PROCEDURE_COUNT,
			dynlib.last_error(),
		)
		// Unload the rejected library and delete its copy: a loaded DLL keeps its file locked,
		// which would make every later attempt to copy to this name fail.
		if api.__handle != nil {
			dynlib.unload_library(api.__handle)
		}
		os.remove(copy_path)
		return {}, false, true
	}
	api.modified_time = modified_time
	api.version = version
	fmt.printfln("host: loaded game version %d", version)
	return api, true, false
}

unload_game_api :: proc(executable_directory: string, api: Game_API) {
	if api.__handle != nil {
		dynlib.unload_library(api.__handle)
	}
	os.remove(versioned_game_path(executable_directory, api.version))
}

versioned_game_path :: proc(executable_directory: string, version: int) -> string {
	return fmt.tprintf("%sgame_%d.%s", executable_directory, version, dynlib.LIBRARY_FILE_EXTENSION)
}

window_pixel_size :: proc(window: ^sdl.Window) -> [2]i32 {
	width, height: i32
	sdl.GetWindowSizeInPixels(window, &width, &height)
	return {width, height}
}

// OS window handles for the renderer to create its GPU surface from.
native_window :: proc(window: ^sdl.Window) -> (platform.Native_Window, bool) {
	properties := sdl.GetWindowProperties(window)
	when ODIN_OS == .Windows {
		return platform.Native_Window_Win32{
			instance_handle = sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_WIN32_INSTANCE_POINTER, nil),
			window_handle   = sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil),
		}, true
	} else when ODIN_OS == .Darwin {
		metal_view := sdl.Metal_CreateView(window)
		return platform.Native_Window_Metal{metal_layer = sdl.Metal_GetLayer(metal_view)}, true
	} else when ODIN_OS == .Linux {
		switch sdl.GetCurrentVideoDriver() {
		case "wayland":
			return platform.Native_Window_Wayland{
				display = sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil),
				surface = sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_WAYLAND_SURFACE_POINTER, nil),
			}, true
		case "x11":
			return platform.Native_Window_Xlib{
				display = sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_X11_DISPLAY_POINTER, nil),
				window  = u64(sdl.GetNumberProperty(properties, sdl.PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
			}, true
		}
		return nil, false
	} else {
		return nil, false
	}
}

handle_event :: proc(input: ^platform.Input, event: sdl.Event, pixel_density: f32) {
	#partial switch event.type {
	case .QUIT:
		input.quit = true

	case .KEY_DOWN, .KEY_UP:
		key := translate_scancode(event.key.scancode)
		if key == .None {
			return
		}
		if event.key.repeat {
			input.keys[key].repeated = true
			return
		}
		set_button(&input.keys[key], event.key.down)

	case .TEXT_INPUT:
		// Append as many whole bytes as fit; text past the per-frame buffer is dropped.
		typed := string(event.text.text)
		space_left := len(input.text_input) - input.text_input_length
		copied_length := copy(input.text_input[input.text_input_length:], typed[:min(len(typed), space_left)])
		input.text_input_length += copied_length

	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		mouse_button: platform.Mouse_Button
		switch event.button.button {
		case sdl.BUTTON_LEFT:
			mouse_button = .Left
		case sdl.BUTTON_MIDDLE:
			mouse_button = .Middle
		case sdl.BUTTON_RIGHT:
			mouse_button = .Right
		case:
			return
		}
		set_button(&input.mouse[mouse_button], event.button.down)

	case .MOUSE_MOTION:
		// SDL reports window coordinates; scale to pixels to match window_size on high-DPI screens.
		input.mouse_position = {event.motion.x, event.motion.y} * pixel_density
		input.mouse_delta += {event.motion.xrel, event.motion.yrel} * pixel_density

	case .MOUSE_WHEEL:
		input.wheel += event.wheel.y

	case .WINDOW_FOCUS_LOST:
		// Keys released while another window has focus never send KEY_UP to us; drop them all.
		for &key in input.keys {
			key.down = false
		}
		for &button in input.mouse {
			button.down = false
		}
	}
}

set_button :: proc(button: ^platform.Button, down: bool) {
	if down && !button.down {
		button.pressed = true
	}
	if !down && button.down {
		button.released = true
	}
	button.down = down
}

translate_scancode :: proc(scancode: sdl.Scancode) -> platform.Key {
	#partial switch scancode {
	case .A ..= .Z:
		return platform.Key(int(platform.Key.A) + int(scancode) - int(sdl.Scancode.A))
	case ._1 ..= ._9:
		return platform.Key(int(platform.Key.Num_1) + int(scancode) - int(sdl.Scancode._1))
	case ._0:
		return .Num_0
	case .F1 ..= .F12:
		return platform.Key(int(platform.Key.F1) + int(scancode) - int(sdl.Scancode.F1))
	case .ESCAPE:
		return .Escape
	case .RETURN:
		return .Enter
	case .TAB:
		return .Tab
	case .BACKSPACE:
		return .Backspace
	case .DELETE:
		return .Delete
	case .SPACE:
		return .Space
	case .LEFT:
		return .Left
	case .RIGHT:
		return .Right
	case .UP:
		return .Up
	case .DOWN:
		return .Down
	case .HOME:
		return .Home
	case .END:
		return .End
	case .LSHIFT:
		return .Left_Shift
	case .RSHIFT:
		return .Right_Shift
	case .LCTRL:
		return .Left_Ctrl
	case .RCTRL:
		return .Right_Ctrl
	case .LALT:
		return .Left_Alt
	case .RALT:
		return .Right_Alt
	}
	return .None
}
