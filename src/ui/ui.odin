// Immediate-mode UI: widgets are procedure calls made every frame; nothing is registered or
// kept by the caller. Layout is computed by Clay (src/third_party/clay), text by fontstash,
// and drawing goes through the renderer's 2D overlay. The rest of the engine uses only this
// package's procedures, never Clay or fontstash directly, so either can be replaced.
//
// A frame:
//     ui.begin_frame(&state, input)           pointer, scrolling, start Clay layout
//     if ui.panel(&state, "Inspector", 300) { widgets... }
//     ui.end_frame(&state, &renderer)         finish layout, emit overlay quads, upload glyphs
//
// What the UI remembers between frames is only interaction state: which widget holds the mouse
// (`active_id`), which field holds the keyboard (`edit_id`), and drag bookkeeping. Widgets are
// identified by Clay element ids hashed from their labels.
//
// Hit testing uses the previous frame's layout: positions are only known once the whole frame
// has been declared, so "is the mouse over this button" is answered from where it was drawn
// last frame. Every auto-layout immediate-mode UI works this way; it's invisible in practice.
package ui

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import fontstash "vendor:fontstash"
import "engine:platform"
import "engine:render"
import clay "engine:third_party/clay"

MAX_PANELS :: 16
MAX_EDIT_BYTES :: 64

Ui_State :: struct {
	clay_memory:         []u8,
	clay_context:        ^clay.Context,
	font_context:        fontstash.FontContext,
	font_indices:        [Font]int, // fontstash index for each Font
	uploaded_atlas_size: [2]i32,
	theme:               Theme,
	scale:               f32,       // display scale: points to pixels
	input:               platform.Input,
	callback_context:    runtime.Context, // used inside callbacks Clay makes into this package

	// Interaction state
	active_id:           u32, // widget that the mouse was pressed on and is still held
	edit_id:             u32, // number field receiving typed text
	editing_at_frame_start: bool,
	typed_value_applied: bool, // a number field applied typed text this frame (see typed_value_applied)
	edit_buffer:         [MAX_EDIT_BYTES]u8,
	edit_length:         int,
	edit_all_selected:   bool, // the whole text is selected: typing replaces it
	drag_start_mouse_x:  f32,
	drag_start_value:    f32,
	drag_moved:          bool,

	// Tab between number boxes. Boxes register themselves as they are drawn, so the order is the
	// drawing order and nothing has to be declared up front.
	focus_request:       Focus_Request,
	first_box_id:        u32, // first number box drawn this frame, and its value
	first_box_value:     f32,
	previous_box_id:     u32, // last number box drawn so far this frame, and its value
	previous_box_value:  f32,

	// Panels declared last frame, to tell whether the mouse is over the UI or the 3D viewport.
	panel_ids:           [MAX_PANELS]u32,
	panel_count:         int,
	mouse_over_panel:    bool,
}

// Where Tab sends the typing once the box that had it is done.
Focus_Request :: enum u8 {
	None,
	Next, // the next number box drawn this frame (Tab)
	Last, // the last number box drawn this frame (Shift+Tab from the first box)
}

init :: proc(state: ^Ui_State, window_size: [2]i32) -> bool {
	memory_size := clay.MinMemorySize()
	state.clay_memory = make([]u8, memory_size)
	arena := clay.CreateArenaWithCapacityAndMemory(uint(memory_size), raw_data(state.clay_memory))
	state.clay_context = clay.Initialize(arena, {f32(window_size.x), f32(window_size.y)}, {handler = on_clay_error})
	if state.clay_context == nil {
		fmt.eprintln("ui: Clay failed to initialize")
		return false
	}
	state.theme = DARK_THEME
	state.scale = 1
	load_fonts(state)
	register_callbacks(state)
	return true
}

shutdown :: proc(state: ^Ui_State) {
	fontstash.Destroy(&state.font_context)
	delete(state.clay_memory)
	state^ = {}
}

// After a hot reload the new DLL has its own copy of Clay's globals: point it back at our
// context, and re-register callbacks so they run the new code.
on_hot_reload :: proc(state: ^Ui_State) {
	register_callbacks(state)
}

begin_frame :: proc(state: ^Ui_State, input: ^platform.Input) {
	state.callback_context = context
	state.input = input^
	state.scale = input.display_scale if input.display_scale > 0 else 1
	state.editing_at_frame_start = state.edit_id != 0
	state.typed_value_applied = false
	state.first_box_id, state.first_box_value = 0, 0
	state.previous_box_id, state.previous_box_value = 0, 0

	// A widget only stays active while the mouse is held; this also frees the mouse if the
	// active widget stopped being drawn.
	left_mouse := input.mouse[.Left]
	if !left_mouse.down && !left_mouse.released {
		state.active_id = 0
	}

	clay.SetLayoutDimensions({f32(input.window_size.x), f32(input.window_size.y)})
	clay.SetPointerState(input.mouse_position, left_mouse.down)

	state.mouse_over_panel = false
	for panel_id in state.panel_ids[:state.panel_count] {
		if clay.PointerOver({id = panel_id}) {
			state.mouse_over_panel = true
			break
		}
	}
	state.panel_count = 0

	scroll_delta: [2]f32
	if state.mouse_over_panel {
		scroll_delta.y = input.wheel * points(state, SCROLL_POINTS_PER_WHEEL_STEP)
	}
	clay.UpdateScrollContainers(false, scroll_delta, input.delta_seconds)
	fontstash.BeginState(&state.font_context)
	clay.BeginLayout()
}

// Finishes the layout and turns Clay's render commands into renderer overlay quads.
end_frame :: proc(state: ^Ui_State, renderer: ^render.Renderer) {
	render_commands := finish_layout(state)
	Clip_Rect :: struct {
		minimum, maximum: [2]f32,
	}
	scissor_stack: [16]Clip_Rect
	scissor_depth := 0
	window_size := [2]f32{f32(state.input.window_size.x), f32(state.input.window_size.y)}
	for command_index in 0 ..< render_commands.length {
		command := clay.RenderCommandArray_Get(&render_commands, command_index)
		box := command.boundingBox
		box_min := [2]f32{box.x, box.y}
		box_max := [2]f32{box.x + box.width, box.y + box.height}

		switch command.commandType {
		case .Rectangle:
			rectangle := command.renderData.rectangle
			render.overlay_rect(renderer, box_min, box_max, color_from_clay(rectangle.backgroundColor), rectangle.cornerRadius.topLeft)
		case .Border:
			// The overlay draws uniform borders; per-side widths use the widest side.
			border := command.renderData.border
			width := max(border.width.left, border.width.right, border.width.top, border.width.bottom)
			render.overlay_rect(renderer, box_min, box_max, color_from_clay(border.color), border.cornerRadius.topLeft, f32(width))
		case .Text:
			draw_text(state, renderer, command.renderData.text, box)
		case .ScissorStart:
			// Clip regions nest (a scrolling panel holding clipped fields): each one is the
			// intersection with its parent, and ending it restores the parent.
			parent := scissor_stack[min(scissor_depth, len(scissor_stack)) - 1] if scissor_depth > 0 else Clip_Rect{{0, 0}, window_size}
			clipped := Clip_Rect{linalg.max(parent.minimum, box_min), linalg.min(parent.maximum, box_max)}
			if scissor_depth < len(scissor_stack) {
				scissor_stack[scissor_depth] = clipped
			}
			scissor_depth += 1
			render.overlay_set_scissor(renderer, clipped.minimum, clipped.maximum)
		case .ScissorEnd:
			scissor_depth = max(scissor_depth - 1, 0)
			if scissor_depth > 0 {
				parent := scissor_stack[min(scissor_depth, len(scissor_stack)) - 1]
				render.overlay_set_scissor(renderer, parent.minimum, parent.maximum)
			} else {
				render.overlay_clear_scissor(renderer)
			}
		case .None, .Image, .Custom, .OverlayColorStart, .OverlayColorEnd:
			// Not used yet.
		}
	}
	upload_glyph_atlas(state, renderer)
}

// True when the mouse belongs to the UI this frame: over a panel, or dragging a widget.
// The 3D viewport should ignore the mouse then.
wants_mouse :: proc(state: ^Ui_State) -> bool {
	return state.mouse_over_panel || state.active_id != 0
}

// True when a text field has the keyboard (or had it at the start of this frame, so the key
// that ended editing, such as Escape, isn't also seen by the game).
wants_keyboard :: proc(state: ^Ui_State) -> bool {
	return state.edit_id != 0 || state.editing_at_frame_start
}

// True on the frame a number field applied typed text (Enter, or a click elsewhere). That edit
// is finished even if the mouse is down: a click elsewhere applies it on the press, and the same
// press may go on to start a new action. Undo records the typed edit as its own step on this
// frame.
typed_value_applied :: proc(state: ^Ui_State) -> bool {
	return state.typed_value_applied
}

// Points to pixels.
points :: proc(state: ^Ui_State, value: f32) -> f32 {
	return value * state.scale
}

points_u16 :: proc(state: ^Ui_State, value: f32) -> u16 {
	return u16(value * state.scale + 0.5)
}

Interaction :: struct {
	hovered:  bool, // mouse over the widget, and no other widget holds the mouse
	pressed:  bool, // mouse went down on the widget this frame
	held:     bool, // widget holds the mouse and the button is down
	released: bool, // widget held the mouse and the button went up this frame
	clicked:  bool, // released while still over the widget
}

// Mouse interaction for the widget with this id, from the previous frame's layout.
interact :: proc(state: ^Ui_State, id: clay.ElementId) -> (result: Interaction) {
	left_mouse := state.input.mouse[.Left]
	pointer_over := clay.PointerOver(id)
	result.hovered = pointer_over && (state.active_id == 0 || state.active_id == id.id)
	if result.hovered && left_mouse.pressed {
		state.active_id = id.id
		result.pressed = true
	}
	if state.active_id == id.id {
		result.held = left_mouse.down
		if left_mouse.released {
			result.released = true
			result.clicked = pointer_over
		}
	}
	return
}

// Ends Clay's layout and returns its render commands. Separate from end_frame so tests can
// run frames without a renderer.
@(private)
finish_layout :: proc(state: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
	// Tab from the last box, or Shift+Tab from the first: no box came after, so wrap around.
	switch state.focus_request {
	case .Next:
		if state.first_box_id != 0 {
			start_editing(state, state.first_box_id, state.first_box_value)
		}
	case .Last:
		if state.previous_box_id != 0 {
			start_editing(state, state.previous_box_id, state.previous_box_value)
		}
	case .None:
	}
	state.focus_request = .None
	return clay.EndLayout(state.input.delta_seconds)
}

@(private)
register_callbacks :: proc(state: ^Ui_State) {
	clay.SetCurrentContext(state.clay_context)
	clay.SetMeasureTextFunction(measure_text, state)
}

@(private)
on_clay_error :: proc "c" (error_data: clay.ErrorData) {
	context = runtime.default_context()
	message := string(error_data.errorText.chars[:error_data.errorText.length])
	fmt.eprintfln("ui: Clay %v: %s", error_data.errorType, message)
}

@(private)
color_from_clay :: proc(color: clay.Color) -> [4]f32 {
	return color / 255
}

@(private)
close_element :: proc() {
	clay._CloseElement()
}
