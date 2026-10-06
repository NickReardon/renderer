// Types shared by the host executable and the game DLL.
//
// Both sides compile this package separately, so every type here must be plain data with the
// same layout on both sides: no procedure values, no allocators, no pointers into either
// module's memory. Small helper procedures that only read the data are fine. The host fills these in from SDL; the game and renderer read them without ever
// knowing SDL exists. A web host would fill the same structs from browser events.
package platform

Key :: enum u8 {
	None,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Num_0, Num_1, Num_2, Num_3, Num_4, Num_5, Num_6, Num_7, Num_8, Num_9,
	Escape, Enter, Tab, Backspace, Delete, Space,
	Left, Right, Up, Down, Home, End,
	Left_Shift, Right_Shift, Left_Ctrl, Right_Ctrl, Left_Alt, Right_Alt,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

// State of one key or button for the current frame. `pressed` and `released` are edges: true
// for exactly one frame. A quick tap can set both in the same frame. `repeated` is true on
// frames where the OS sent a key-repeat while the key is held (for text editing).
Button :: struct {
	down:     bool,
	pressed:  bool,
	released: bool,
	repeated: bool,
}

MAX_TEXT_INPUT_BYTES :: 64

Input :: struct {
	keys:              [Key]Button,
	mouse:             [Mouse_Button]Button,
	mouse_position:    [2]f32, // pixels, origin at the top-left of the window
	mouse_delta:       [2]f32, // pixels moved since last frame
	wheel:             f32,    // scroll steps this frame; positive = away from the user
	window_size:       [2]i32, // drawable size in pixels (already scaled for high-DPI)
	display_scale:     f32,    // UI scale the OS asks for: 1 = 96 DPI, 1.5 = 150% scaling
	refresh_rate:      f32,    // the window's display, in Hz; 0 if unknown
	delta_seconds:     f32,    // time since the previous frame
	quit:              bool,   // the user asked to close the window
	capture_requested: bool,   // save this frame to screenshot.bmp (host flag --screenshot)

	// Text typed this frame, UTF-8, after keyboard layout and input method processing.
	// Use this for text fields; use `keys` for shortcuts.
	text_input:        [MAX_TEXT_INPUT_BYTES]u8,
	text_input_length: int,
}

input_text :: proc(input: ^Input) -> string {
	return string(input.text_input[:input.text_input_length])
}

// OS-level window handles, enough for the renderer to create a GPU surface. The host builds
// one of these from SDL's window properties; the renderer turns it into a wgpu surface. This
// keeps SDL out of the renderer and wgpu out of the host.
Native_Window_Win32 :: struct {
	instance_handle: rawptr, // HINSTANCE
	window_handle:   rawptr, // HWND
}

Native_Window_Metal :: struct {
	metal_layer: rawptr, // CAMetalLayer
}

Native_Window_Xlib :: struct {
	display: rawptr,
	window:  u64,
}

Native_Window_Wayland :: struct {
	display: rawptr,
	surface: rawptr,
}

Native_Window :: union {
	Native_Window_Win32,
	Native_Window_Metal,
	Native_Window_Xlib,
	Native_Window_Wayland,
}
