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
import "core:time"
import sdl "vendor:sdl3"
import "engine:platform"

// Procedures exported by the game DLL as `game_<field name>`.
Game_API :: struct {
	init:           proc(window: platform.Native_Window, window_size: [2]i32) -> bool,
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
	window := sdl.CreateWindow("Renderer", 1600, 900, window_flags)
	if window == nil {
		fmt.eprintln("SDL_CreateWindow failed:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	native, native_found := native_window(window)
	if !native_found {
		fmt.eprintln("host: can't get native handles for this window system")
		return
	}

	// The game DLL is built next to the executable.
	executable_directory := string(sdl.GetBasePath())
	game_library_path := fmt.aprintf("%sgame.%s", executable_directory, dynlib.LIBRARY_FILE_EXTENSION)

	game, game_loaded := load_game_api(executable_directory, game_library_path, 0)
	if !game_loaded {
		return
	}
	initial_size := window_pixel_size(window)
	fmt.printfln("host: window %dx%d pixels (pixel density %.2f)", initial_size.x, initial_size.y, sdl.GetWindowPixelDensity(window))
	if !game.init(native, initial_size) {
		fmt.eprintln("host: game failed to initialize")
		return
	}
	next_version := 1
	previous_games: [dynamic]Game_API

	input: platform.Input
	last_tick := time.tick_now()

	main_loop: for {
		// Edges and per-frame deltas only last one frame.
		for &key in input.keys {
			key.pressed, key.released = false, false
		}
		for &button in input.mouse {
			button.pressed, button.released = false, false
		}
		input.mouse_delta = {}
		input.wheel = 0

		pixel_density := sdl.GetWindowPixelDensity(window)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			handle_event(&input, event, pixel_density)
		}
		input.window_size = window_pixel_size(window)

		now := time.tick_now()
		input.delta_seconds = f32(time.duration_seconds(time.tick_diff(last_tick, now)))
		last_tick = now

		if !game.update(&input) {
			break main_loop
		}
		free_all(context.temp_allocator)

		// Hot reload: has the build replaced game.dll since we loaded it?
		modified_time, stat_error := os.modification_time_by_path(game_library_path)
		force_restart := input.keys[.F6].pressed
		if (stat_error == nil && modified_time != game.modified_time) || force_restart {
			new_game, new_game_loaded := load_game_api(executable_directory, game_library_path, next_version)
			if !new_game_loaded {
				continue
			}
			next_version += 1
			if force_restart || new_game.memory_size() != game.memory_size() {
				// Game_Memory's layout changed (or F6): start the game over with fresh state.
				fmt.println("host: restarting game")
				game.shutdown()
				append(&previous_games, game)
				game = new_game
				if !game.init(native, window_pixel_size(window)) {
					fmt.eprintln("host: game failed to initialize after restart")
					break main_loop
				}
			} else {
				memory := game.memory_pointer()
				append(&previous_games, game)
				game = new_game
				game.hot_reloaded(memory)
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
load_game_api :: proc(executable_directory, game_library_path: string, version: int) -> (api: Game_API, loaded: bool) {
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
		return
	}
	api.modified_time = modified_time
	api.version = version
	fmt.printfln("host: loaded game version %d", version)
	return api, true
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
		if event.key.repeat {
			return
		}
		key := translate_scancode(event.key.scancode)
		if key != .None {
			set_button(&input.keys[key], event.key.down)
		}

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
