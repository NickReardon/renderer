// UI tests: run real frames (Clay layout, fontstash measuring, widget logic) with simulated
// input, without a GPU. Widgets are found the way UI test tools do it: by the text they show.
//
// Clay keeps its current context in a process-wide global, so everything runs in one test
// procedure rather than several tests that the runner would execute in parallel.
package ui

import "core:math"
import "core:testing"
import fontstash "vendor:fontstash"
import "engine:platform"
import "engine:render"
import clay "engine:third_party/clay"

Test_Model :: struct {
	number:       f32,
	flag:         bool,
	button_count: int,
	vector:       [3]f32,
	row_clicks:   int,
	tool_clicks:  int,
	inspected:    Inspected_Data,
	name_bytes:   [TEST_NAME_BYTES]u8, // what the text box shows and edits
	name_length:  int,
	name_result:  Text_Box_Result,     // the text box's result in the last frame
	long_bytes:   [64]u8,              // a second text box, for text longer than the box
	long_length:  int,
	start_rename: bool,                // start typing into the text box without a click
}

TEST_NAME_BYTES :: 8

// For the reflection-driven inspector: tagged fields get widgets, the untagged one doesn't.
Inspected_Data :: struct {
	speed:   f32  `inspect:"Speed" step:"0.5" format:"%.1f"`,
	enabled: bool `inspect:"Enabled"`,
	hidden:  f32,
}

@(private = "file")
run_frame :: proc(state: ^Ui_State, input: ^platform.Input, model: ^Test_Model) -> clay.ClayArray(clay.RenderCommand) {
	begin_frame(state, input)
	if area(state, "Test viewport") {
		if toolbar(state, "Test toolbar") {
			if toggle_button(state, "Tool", model.tool_clicks % 2 == 1) {
				model.tool_clicks += 1
			}
		}
	}
	if panel(state, "Test panel", 300) {
		number_field(state, "Number", &model.number, 0.1, -100, 100, "%.3f")
		checkbox(state, "Flag", &model.flag)
		if button(state, "Press me") {
			model.button_count += 1
		}
		vector3_field(state, "Vector", &model.vector, 0.1, "%.1f")
		if selectable(state, "Row item", false).clicked {
			model.row_clicks += 1
		}
		inspect(state, &model.inspected, Inspected_Data)
		edited, result := text_box(state, "Name", string(model.name_bytes[:model.name_length]), TEST_NAME_BYTES, start_editing = model.start_rename, check = check_test_name)
		if result == .Applied {
			model.name_length = copy(model.name_bytes[:], edited)
		}
		model.name_result = result
		long_edited, long_result := text_box(state, "Long name", string(model.long_bytes[:model.long_length]), len(model.long_bytes))
		if long_result == .Applied {
			model.long_length = copy(model.long_bytes[:], long_edited)
		}
		model.start_rename = false
	}
	return finish_layout(state)
}

// The box of the text being edited: its custom element (it draws itself; see text_edit.odin).
@(private = "file")
find_edited_text :: proc(commands: clay.ClayArray(clay.RenderCommand)) -> (box_min, box_max: [2]f32, found: bool) {
	commands := commands
	for command_index in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(&commands, command_index)
		if command.commandType == .Custom {
			box := command.boundingBox
			return {box.x, box.y}, {box.x + box.width, box.y + box.height}, true
		}
	}
	return
}

// The box of the first text element showing exactly `content`.
@(private = "file")
find_text_box :: proc(commands: clay.ClayArray(clay.RenderCommand), content: string) -> (box_min, box_max: [2]f32, found: bool) {
	commands := commands
	for command_index in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(&commands, command_index)
		if command.commandType != .Text {
			continue
		}
		shown := command.renderData.text.stringContents
		if string(shown.chars[:shown.length]) == content {
			box := command.boundingBox
			return {box.x, box.y}, {box.x + box.width, box.y + box.height}, true
		}
	}
	return
}

// Centre of the first text element showing exactly `content`.
@(private = "file")
find_text :: proc(commands: clay.ClayArray(clay.RenderCommand), content: string) -> (center: [2]f32, found: bool) {
	commands := commands
	for command_index in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(&commands, command_index)
		if command.commandType != .Text {
			continue
		}
		shown := command.renderData.text.stringContents
		if string(shown.chars[:shown.length]) == content {
			box := command.boundingBox
			return {box.x + box.width * 0.5, box.y + box.height * 0.5}, true
		}
	}
	return
}

// The next frame's input: held buttons stay held, one-frame edges and deltas clear (as the
// host does).
@(private = "file")
next_input :: proc(input: ^platform.Input) {
	for &key in input.keys {
		key.pressed, key.released, key.repeated = false, false, false
	}
	for &button in input.mouse {
		button.pressed, button.released, button.repeated = false, false, false
	}
	input.mouse_delta = {}
	input.wheel = 0
	input.text_input_length = 0
	input.clipboard_text_length = 0
	input.delta_seconds = 1.0 / 60
}

@(private = "file")
// A press after a pause, as a person clicks; `quick` follows the last press at once (a double- or
// triple-click when it's in the same place).
press_mouse :: proc(input: ^platform.Input, position: [2]f32, quick := false) {
	next_input(input)
	if !quick {
		input.delta_seconds = 1
	}
	input.mouse_position = position
	input.mouse[.Left] = {down = true, pressed = true}
}

@(private = "file")
move_mouse :: proc(input: ^platform.Input, position: [2]f32) {
	next_input(input)
	input.mouse_delta = position - input.mouse_position
	input.mouse_position = position
}

@(private = "file")
release_mouse :: proc(input: ^platform.Input) {
	next_input(input)
	input.mouse[.Left] = {released = true}
}

@(private = "file")
type_text :: proc(input: ^platform.Input, typed: string) {
	next_input(input)
	input.text_input_length = copy(input.text_input[:], typed)
}

@(private = "file")
press_key :: proc(input: ^platform.Input, key: platform.Key) {
	next_input(input)
	input.keys[key] = {down = true, pressed = true}
}

@(test)
test_widget_interaction :: proc(test: ^testing.T) {
	state := new(Ui_State)
	defer free(state)
	testing.expect(test, init(state, {1200, 800}), "ui init")
	defer shutdown(state)

	model := Test_Model{number = 1}
	model.name_length = copy(model.name_bytes[:], "Alpha")
	input := platform.Input{window_size = {1200, 800}, display_scale = 1, delta_seconds = 1.0 / 60}

	// A first frame lays everything out; hit testing in later frames uses this layout.
	commands := run_frame(state, &input, &model)
	field_center, field_found := find_text(commands, "1.000")
	testing.expect(test, field_found, "the number field should show 1.000")
	free_all(context.temp_allocator)

	// --- Clicking a number field (press and release without moving) starts typing.
	press_mouse(&input, field_center)
	run_frame(state, &input, &model)
	testing.expect(test, wants_mouse(state), "the UI should own the mouse while a widget is pressed")
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect(test, state.edit_id != 0, "a click should start editing")
	testing.expect(test, all_text_selected(state), "editing should start with the whole value selected")
	testing.expect(test, wants_keyboard(state), "the UI should own the keyboard while editing")
	free_all(context.temp_allocator)

	// --- Typing replaces the selection; Enter applies the value.
	type_text(&input, "12.5")
	run_frame(state, &input, &model)
	press_key(&input, .Enter)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.number, 12.5)
	testing.expect(test, state.edit_id == 0, "Enter should stop editing")
	free_all(context.temp_allocator)

	// --- Escape cancels typing and leaves the value alone. The game must not also see Escape.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	field_center, field_found = find_text(commands, "12.500")
	testing.expect(test, field_found, "the number field should show 12.500")
	press_mouse(&input, field_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	type_text(&input, "99")
	run_frame(state, &input, &model)
	press_key(&input, .Escape)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.number, 12.5)
	testing.expect(test, state.edit_id == 0, "Escape should stop editing")
	testing.expect(test, wants_keyboard(state), "the frame that handled Escape should still claim the keyboard")
	free_all(context.temp_allocator)

	// --- Dragging sideways changes the value: 40 points * 0.1 per point = +4.
	press_mouse(&input, field_center)
	run_frame(state, &input, &model)
	move_mouse(&input, field_center + {40, 0})
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expectf(test, abs(model.number - 16.5) < 1e-4, "dragging should add 4, got %v", model.number)
	testing.expect(test, state.edit_id == 0, "a drag must not start typing")
	free_all(context.temp_allocator)

	// --- Clicking a checkbox's label toggles it.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	flag_center, flag_found := find_text(commands, "Flag")
	testing.expect(test, flag_found, "the checkbox label should be visible")
	press_mouse(&input, flag_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect(test, model.flag, "clicking the checkbox should turn it on")
	free_all(context.temp_allocator)

	// --- A button counts one click per press and release, and only if released over it.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	button_center, button_found := find_text(commands, "Press me")
	testing.expect(test, button_found, "the button label should be visible")
	press_mouse(&input, button_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.button_count, 1)
	press_mouse(&input, button_center)
	run_frame(state, &input, &model)
	move_mouse(&input, {10, 10}) // drag off the button before releasing: no click
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.button_count, 1)
	free_all(context.temp_allocator)

	// --- Typing a value, then clicking a button: the press applies the value and reports it
	// (undo records it then, as a step of its own); the button acts later, on release.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	field_center, field_found = find_text(commands, "16.500")
	testing.expect(test, field_found, "the number field should show 16.500")
	press_mouse(&input, field_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	type_text(&input, "3")
	run_frame(state, &input, &model)
	testing.expect(test, !typed_value_applied(state), "typing alone applies nothing")
	press_mouse(&input, button_center)
	run_frame(state, &input, &model)
	testing.expect(test, model.number == 3 && typed_value_applied(state), "pressing elsewhere applies the typed value and reports it")
	testing.expect_value(test, model.button_count, 1)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect(test, !typed_value_applied(state), "the report lasts one frame")
	testing.expect_value(test, model.button_count, 2)
	free_all(context.temp_allocator)

	// --- A vector field: dragging the Y box changes only Y (20 points * 0.1 = +2).
	next_input(&input)
	commands = run_frame(state, &input, &model)
	y_box_center, y_box_found := find_text(commands, "Y")
	testing.expect(test, y_box_found, "the vector field's Y marker should be visible")
	press_mouse(&input, y_box_center)
	run_frame(state, &input, &model)
	move_mouse(&input, y_box_center + {20, 0})
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expectf(test, abs(model.vector.y - 2) < 1e-4 && model.vector.x == 0 && model.vector.z == 0, "only Y should change, got %v", model.vector)
	free_all(context.temp_allocator)

	// --- A selectable row reports clicks.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	row_center, row_found := find_text(commands, "Row item")
	testing.expect(test, row_found, "the selectable row should be visible")
	press_mouse(&input, row_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.row_clicks, 1)
	free_all(context.temp_allocator)

	// --- The reflection inspector shows tagged fields, edits the real struct, hides the rest.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	_, speed_found := find_text(commands, "Speed")
	_, hidden_found := find_text(commands, "hidden")
	testing.expect(test, speed_found, "the tagged Speed field should have a widget")
	testing.expect(test, !hidden_found, "the untagged field should not appear")
	enabled_center, enabled_found := find_text(commands, "Enabled")
	testing.expect(test, enabled_found, "the tagged Enabled field should have a checkbox")
	press_mouse(&input, enabled_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect(test, model.inspected.enabled, "clicking the inspected checkbox should change the real struct")
	free_all(context.temp_allocator)

	// --- Long numbers must stay inside their boxes instead of pushing the row past the window.
	saved_vector := model.vector
	model.vector = {-123456.7, -123456.7, -123456.7}
	next_input(&input)
	commands = run_frame(state, &input, &model)
	// What's *visible* must stay inside the window: an element's right edge, cut by any clip
	// regions around it (Clay emits nested ScissorStart / ScissorEnd pairs).
	window_width := f32(input.window_size.x)
	clip_right_stack: [16]f32
	clip_depth := 0
	for command_index in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(&commands, command_index)
		right_edge := command.boundingBox.x + command.boundingBox.width
		current_clip := clip_right_stack[clip_depth - 1] if clip_depth > 0 else window_width
		#partial switch command.commandType {
		case .ScissorStart:
			clip_right_stack[clip_depth] = min(current_clip, right_edge)
			clip_depth += 1
		case .ScissorEnd:
			clip_depth -= 1
		case:
			visible_right_edge := min(right_edge, current_clip)
			if visible_right_edge > window_width + 0.5 {
				testing.expectf(test, false, "%v element is visible up to x = %v, past the window's right edge (%v)", command.commandType, visible_right_edge, window_width)
			}
		}
	}
	// Every box must also stay inside the panel: the Z field's box ends at or before the window edge.
	z_marker_center, z_marker_found := find_text(commands, "Z")
	testing.expect(test, z_marker_found && z_marker_center.x < window_width, "the Z field should be inside the window")
	model.vector = saved_vector
	free_all(context.temp_allocator)

	// --- A toolbar over the view: its button clicks, and it takes the mouse while the area
	// around it (the 3D view) doesn't.
	next_input(&input)
	commands = run_frame(state, &input, &model)
	tool_center, tool_found := find_text(commands, "Tool")
	testing.expect(test, tool_found, "the toolbar button should be visible")
	press_mouse(&input, tool_center)
	run_frame(state, &input, &model)
	testing.expect(test, wants_mouse(state), "the toolbar should take the mouse")
	release_mouse(&input)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.tool_clicks, 1)
	free_all(context.temp_allocator)

	// --- Tab applies the typed value and moves to the next number box, Shift+Tab to the previous
	// one, wrapping around at either end. The box being typed into shows its text, all selected.
	model.number, model.vector, model.inspected.speed = 5, {1, 2, 3}, 9
	next_input(&input)
	commands = run_frame(state, &input, &model)
	field_center, field_found = find_text(commands, "5.000")
	testing.expect(test, field_found, "the number field should show 5.000")
	press_mouse(&input, field_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	type_text(&input, "6")
	run_frame(state, &input, &model)
	press_key(&input, .Tab)
	run_frame(state, &input, &model)
	testing.expect_value(test, model.number, 6)
	testing.expect(test, typed_value_applied(state), "Tab applies the typed value (an undo step of its own)")
	testing.expect(test, wants_keyboard(state), "the UI keeps the keyboard while tabbing")
	expect_editing_text :: proc(test: ^testing.T, state: ^Ui_State, input: ^platform.Input, model: ^Test_Model, shown: string, message: string) {
		next_input(input)
		commands := run_frame(state, input, model)
		_, _, found := find_edited_text(commands)
		testing.expectf(test, found && edited_text(state) == shown, "%s: expected a box being typed into showing %s (found %v, showing %q)", message, shown, found, edited_text(state))
	}
	expect_editing_text(test, state, &input, &model, "1", "Tab from Number should edit Vector X")
	press_key(&input, .Tab)
	run_frame(state, &input, &model)
	expect_editing_text(test, state, &input, &model, "2", "Tab from X should edit Y")
	press_key(&input, .Tab)
	input.keys[.Left_Shift] = {down = true, pressed = true}
	run_frame(state, &input, &model)
	input.keys[.Left_Shift] = {}
	expect_editing_text(test, state, &input, &model, "1", "Shift+Tab from Y should edit X")
	testing.expect(test, model.vector == {1, 2, 3}, "tabbing through without typing keeps the values")
	press_key(&input, .Escape)
	run_frame(state, &input, &model)
	free_all(context.temp_allocator)

	next_input(&input)
	commands = run_frame(state, &input, &model)
	speed_center, speed_box_found := find_text(commands, "9.0")
	testing.expect(test, speed_box_found, "the inspected Speed field should show 9.0")
	press_mouse(&input, speed_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	press_key(&input, .Tab)
	run_frame(state, &input, &model)
	expect_editing_text(test, state, &input, &model, "6", "Tab from the last box should wrap to the first")
	press_key(&input, .Tab)
	input.keys[.Left_Shift] = {down = true, pressed = true}
	run_frame(state, &input, &model)
	input.keys[.Left_Shift] = {}
	expect_editing_text(test, state, &input, &model, "9", "Shift+Tab from the first box should wrap to the last")
	press_key(&input, .Escape)
	run_frame(state, &input, &model)
	testing.expect(test, state.edit_id == 0, "Escape should stop editing")
	free_all(context.temp_allocator)

	// --- In a window too short for the panel, tabbing to a box below the bottom edge scrolls
	// the panel to show it, and wrapping back to the first box scrolls back up.
	input.window_size.y = 140
	next_input(&input)
	commands = run_frame(state, &input, &model)
	field_center, field_found = find_text(commands, "6.000")
	testing.expect(test, field_found, "the number field should show at the top of the short panel")
	press_mouse(&input, field_center)
	run_frame(state, &input, &model)
	release_mouse(&input)
	run_frame(state, &input, &model)
	press_key(&input, .Tab)
	input.keys[.Left_Shift] = {down = true, pressed = true}
	run_frame(state, &input, &model)
	input.keys[.Left_Shift] = {}
	expect_box_in_window :: proc(test: ^testing.T, state: ^Ui_State, input: ^platform.Input, model: ^Test_Model, shown: string, message: string) {
		next_input(input)
		run_frame(state, input, model) // the scroll applies at the start of the frame after the move
		commands := run_frame(state, input, model)
		box_min, box_max, found := find_edited_text(commands)
		found = found && edited_text(state) == shown
		center := (box_min + box_max) * 0.5
		window_height := f32(input.window_size.y)
		testing.expectf(test, found && center.y > 0 && center.y < window_height, "%s: %s should be in the window (found %v, y %.1f)", message, shown, found, center.y)
	}
	expect_box_in_window(test, state, &input, &model, "9", "Shift+Tab wrapping to a box below the edge")
	press_key(&input, .Tab)
	run_frame(state, &input, &model)
	expect_box_in_window(test, state, &input, &model, "6", "Tab wrapping back to the top box")
	press_key(&input, .Escape)
	run_frame(state, &input, &model)
	input.window_size.y = 800
	free_all(context.temp_allocator)

	test_text_box(test, state, &input, &model)
	test_text_editing(test, state, &input, &model)

	// --- The mouse belongs to the viewport outside the panel, and to the UI over it.
	move_mouse(&input, {100, 400})
	run_frame(state, &input, &model)
	testing.expect(test, !wants_mouse(state), "the viewport area should keep the mouse")
	move_mouse(&input, button_center)
	run_frame(state, &input, &model)
	testing.expect(test, wants_mouse(state), "the panel should take the mouse")
	free_all(context.temp_allocator)
}

// The text box: typing, caret keys, limits, the mouse, and how typing ends.
@(private = "file")
test_text_box :: proc(test: ^testing.T, state: ^Ui_State, input: ^platform.Input, model: ^Test_Model) {
	model_name :: proc(model: ^Test_Model) -> string {
		return string(model.name_bytes[:model.name_length])
	}
	key :: proc(state: ^Ui_State, input: ^platform.Input, model: ^Test_Model, key: platform.Key, shift := false) {
		press_key(input, key)
		if shift {
			input.keys[.Left_Shift] = {down = true, pressed = true}
		}
		run_frame(state, input, model)
		input.keys[.Left_Shift] = {}
		input.keys[key] = {}
	}
	typed :: proc(state: ^Ui_State, input: ^platform.Input, model: ^Test_Model, text: string) {
		type_text(input, text)
		run_frame(state, input, model)
	}

	// --- A click starts typing with all of the text selected; typing replaces it, Enter applies.
	next_input(input)
	run_frame(state, input, model) // the window just grew back: let the panel's scroll settle
	commands := run_frame(state, input, model)
	name_center, name_found := find_text(commands, "Alpha")
	testing.expect(test, name_found, "the text box should show Alpha")
	press_mouse(input, name_center)
	run_frame(state, input, model)
	release_mouse(input)
	run_frame(state, input, model)
	testing.expect(test, model.name_result == .Editing && all_text_selected(state), "a click starts typing, all selected")
	typed(state, input, model, "Beta")
	testing.expect_value(test, edited_text(state), "Beta")
	testing.expect_value(test, model_name(model), "Alpha") // nothing applied while typing
	key(state, input, model, .Enter)
	testing.expect_value(test, model_name(model), "Beta")
	testing.expect(test, model.name_result == .Applied && typed_value_applied(state), "Enter applies and reports it")
	testing.expect(test, state.edit_id == 0, "Enter stops typing")
	free_all(context.temp_allocator)

	// --- Caret keys: Left collapses the selection to its start, typing inserts at the caret,
	// Delete and Backspace remove one character, Shift+End selects to the end. Escape cancels.
	model.start_rename = true // as F2 does
	next_input(input)
	run_frame(state, input, model)
	testing.expect(test, model.name_result == .Editing && all_text_selected(state), "start_editing starts typing, all selected")
	key(state, input, model, .Left)
	typed(state, input, model, "X")
	testing.expect_value(test, edited_text(state), "XBeta")
	key(state, input, model, .Right)
	key(state, input, model, .Delete) // XB|eta -> XB|ta
	key(state, input, model, .Backspace) // XB|ta -> X|ta
	testing.expect_value(test, edited_text(state), "Xta")
	testing.expect_value(test, edit_caret(state), 1)
	key(state, input, model, .End, shift = true)
	start, end := selection_range(state)
	testing.expect(test, start == 1 && end == 3, "Shift+End selects from the caret to the end")
	key(state, input, model, .Delete)
	testing.expect_value(test, edited_text(state), "X")
	key(state, input, model, .Escape)
	testing.expect(test, model.name_result == .Cancelled && model_name(model) == "Beta", "Escape keeps the old text")
	testing.expect(test, !typed_value_applied(state), "a cancelled edit applies nothing")
	free_all(context.temp_allocator)

	// --- The box's byte limit holds, and a multi-byte character is one step for the caret.
	model.start_rename = true
	next_input(input)
	run_frame(state, input, model)
	typed(state, input, model, "0123456789")
	testing.expect_value(test, edited_text(state), "01234567") // TEST_NAME_BYTES
	key(state, input, model, .Backspace)
	key(state, input, model, .Backspace)
	typed(state, input, model, "é") // two bytes: fits exactly
	testing.expect_value(test, edited_text(state), "012345é")
	typed(state, input, model, "é") // doesn't fit, and is never cut in half
	testing.expect_value(test, edited_text(state), "012345é")
	key(state, input, model, .Left)
	testing.expect_value(test, edit_caret(state), 6)
	key(state, input, model, .Backspace)
	key(state, input, model, .End)
	key(state, input, model, .Backspace)
	testing.expect_value(test, edited_text(state), "01234")
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)

	// --- One measurement places everything: the boundaries are the font's own advances (trailing
	// spaces included), and a press or a drag lands on the boundary under the pointer.
	model.name_length = copy(model.name_bytes[:], "ab cd")
	model.start_rename = true
	next_input(input)
	run_frame(state, input, model)
	next_input(input)
	commands = run_frame(state, input, model)
	text_min, text_max, text_found := find_edited_text(commands)
	testing.expect(test, text_found, "the edited text has its own element")
	set_font(state, .Regular, points(state, FONT_SIZE), 0)
	measured_width := fontstash.TextBounds(&state.font_context, "ab ")
	testing.expectf(test, abs(state.edit_caret_x[3] - measured_width) < 0.5, "the boundary after \"ab \" is where the font puts it (%v vs %v)", state.edit_caret_x[3], measured_width)
	middle_y := (text_min.y + text_max.y) * 0.5
	press_mouse(input, {text_min.x + state.edit_caret_x[0] + 1, middle_y})
	run_frame(state, input, model)
	testing.expect_value(test, edit_caret(state), 0)
	start, end = selection_range(state)
	testing.expect(test, start == end, "a press clears the selection")
	move_mouse(input, {text_min.x + state.edit_caret_x[3] + 1, middle_y})
	run_frame(state, input, model)
	start, end = selection_range(state)
	testing.expect(test, start == 0 && end == 3, "dragging selects from the press to the pointer")
	release_mouse(input)
	run_frame(state, input, model)
	testing.expect(test, model.name_result == .Editing, "pressing inside the box keeps typing going")

	// --- A press elsewhere applies the text.
	typed(state, input, model, "Z")
	press_mouse(input, {600, 400}) // the viewport area
	run_frame(state, input, model)
	testing.expect_value(test, model_name(model), "Zcd")
	testing.expect(test, model.name_result == .Applied, "a press elsewhere applies the text")
	release_mouse(input)
	run_frame(state, input, model)
	free_all(context.temp_allocator)

	// --- A check procedure: a blocking message keeps Enter from applying and is shown under the
	// box; a click elsewhere then cancels; a note (not blocking) is shown and lets typing apply.
	model.name_length = copy(model.name_bytes[:], "Old")
	model.start_rename = true
	next_input(input)
	run_frame(state, input, model)
	typed(state, input, model, "a/b")
	next_input(input)
	commands = run_frame(state, input, model)
	_, blocked_message_shown := find_text(commands, "No slashes.")
	testing.expect(test, blocked_message_shown, "a blocking message is shown under the box")
	key(state, input, model, .Enter)
	testing.expect(test, model.name_result == .Editing && model_name(model) == "Old", "Enter doesn't apply blocked text")
	key(state, input, model, .Tab)
	testing.expect(test, model.name_result == .Editing && model_name(model) == "Old", "Tab doesn't apply blocked text either")
	press_mouse(input, {600, 400}) // the viewport area
	run_frame(state, input, model)
	testing.expect(test, model.name_result == .Cancelled && model_name(model) == "Old", "a click elsewhere cancels blocked text")
	testing.expect(test, !typed_value_applied(state), "a cancelled edit applies nothing")
	release_mouse(input)
	run_frame(state, input, model)
	model.start_rename = true
	next_input(input)
	run_frame(state, input, model)
	typed(state, input, model, "note")
	next_input(input)
	commands = run_frame(state, input, model)
	_, note_shown := find_text(commands, "Just a note.")
	testing.expect(test, note_shown, "a note is shown under the box")
	key(state, input, model, .Enter)
	testing.expect(test, model.name_result == .Applied && model_name(model) == "note", "a note doesn't block applying")
	next_input(input)
	commands = run_frame(state, input, model)
	_, note_still_shown := find_text(commands, "Just a note.")
	testing.expect(test, !note_still_shown, "the message goes away with the typing")
	free_all(context.temp_allocator)

	// --- A box that stops being drawn while typed into gives the keyboard back.
	model.start_rename = true
	next_input(input)
	run_frame(state, input, model)
	testing.expect(test, wants_keyboard(state), "typing into the text box")
	next_input(input)
	begin_frame(state, input)
	finish_layout(state) // a frame without the box
	next_input(input)
	run_frame(state, input, model)
	testing.expect(test, state.edit_id == 0 && !wants_keyboard(state), "the keyboard is released when the box goes away")
	free_all(context.temp_allocator)
}

// The test text box's check: a slash blocks, the text "note" gets a note that doesn't.
@(private = "file")
check_test_name :: proc(text: string, data: rawptr) -> Text_Check {
	for character in text {
		if character == '/' {
			return {message = "No slashes.", blocks = true}
		}
	}
	if text == "note" {
		return {message = "Just a note."}
	}
	return {}
}

// Editing commands (core:text/edit), the clipboard, double- and triple-clicks, long text that
// scrolls, the mouse cursor, and drawing.
@(private = "file")
test_text_editing :: proc(test: ^testing.T, state: ^Ui_State, input: ^platform.Input, model: ^Test_Model) {
	key :: proc(state: ^Ui_State, input: ^platform.Input, model: ^Test_Model, key: platform.Key, shift := false, ctrl := false) {
		press_key(input, key)
		if shift {
			input.keys[.Left_Shift] = {down = true, pressed = true}
		}
		if ctrl {
			input.keys[.Left_Ctrl] = {down = true, pressed = true}
		}
		run_frame(state, input, model)
		input.keys[.Left_Shift] = {}
		input.keys[.Left_Ctrl] = {}
		input.keys[key] = {}
	}
	start_typing :: proc(state: ^Ui_State, input: ^platform.Input, model: ^Test_Model, text: string) {
		model.name_length = copy(model.name_bytes[:], text)
		model.start_rename = true // as F2 does: typing starts with everything selected
		next_input(input)
		run_frame(state, input, model)
	}
	output_after_frame :: proc(state: ^Ui_State) -> (output: platform.Output) {
		write_output(state, &output)
		return
	}

	// --- Words: Ctrl+arrows jump by word, with Shift they select, Ctrl+Backspace deletes one.
	start_typing(state, input, model, "ab cd")
	key(state, input, model, .End)
	key(state, input, model, .Left, ctrl = true)
	testing.expect_value(test, edit_caret(state), 3)
	key(state, input, model, .Left, shift = true, ctrl = true)
	start, end := selection_range(state)
	testing.expect(test, start == 0 && end == 3, "Ctrl+Shift+Left selects the word before")
	key(state, input, model, .End)
	key(state, input, model, .Backspace, ctrl = true)
	testing.expect_value(test, edited_text(state), "ab ")
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)

	// --- Undo and redo inside the box: quick typing is one step.
	start_typing(state, input, model, "ab")
	key(state, input, model, .End)
	type_text(input, "c")
	run_frame(state, input, model)
	type_text(input, "d")
	run_frame(state, input, model)
	testing.expect_value(test, edited_text(state), "abcd")
	key(state, input, model, .Z, ctrl = true)
	testing.expect_value(test, edited_text(state), "ab")
	key(state, input, model, .Y, ctrl = true)
	testing.expect_value(test, edited_text(state), "abcd")
	// Typing right after an undo or a redo is a step of its own, however quickly it follows:
	// Ctrl+Z then takes back just that typing (found in review of #9).
	key(state, input, model, .Z, ctrl = true)
	type_text(input, "e")
	run_frame(state, input, model)
	testing.expect_value(test, edited_text(state), "abe")
	key(state, input, model, .Z, ctrl = true)
	testing.expect_value(test, edited_text(state), "ab")
	key(state, input, model, .Y, ctrl = true)
	type_text(input, "f")
	run_frame(state, input, model)
	testing.expect_value(test, edited_text(state), "abef")
	key(state, input, model, .Z, ctrl = true)
	testing.expect_value(test, edited_text(state), "abe")
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)

	// --- Copy and cut ask the host to set the clipboard; paste takes one line of the host's.
	start_typing(state, input, model, "ab cd")
	key(state, input, model, .End)
	key(state, input, model, .Left, shift = true, ctrl = true) // "cd"
	key(state, input, model, .C, ctrl = true)
	output := output_after_frame(state)
	testing.expect(test, output.set_clipboard && string(output.clipboard_text[:output.clipboard_text_length]) == "cd", "Ctrl+C copies the selection")
	testing.expect_value(test, edited_text(state), "ab cd")
	key(state, input, model, .X, ctrl = true)
	output = output_after_frame(state)
	testing.expect(test, output.set_clipboard && edited_text(state) == "ab ", "Ctrl+X copies and removes the selection")
	next_input(input)
	run_frame(state, input, model)
	output = output_after_frame(state)
	testing.expect(test, !output.set_clipboard, "the clipboard request lasts one frame")
	press_key(input, .V)
	input.keys[.Left_Ctrl] = {down = true, pressed = true}
	input.clipboard_text_length = copy(input.clipboard_text[:], "xy\nsecond line")
	run_frame(state, input, model)
	input.keys[.Left_Ctrl] = {}
	testing.expect_value(test, edited_text(state), "ab xy")
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)

	// --- Double-click selects a word and dragging extends by words; triple-click selects all.
	start_typing(state, input, model, "ab cd ef")
	next_input(input)
	commands := run_frame(state, input, model)
	text_min, text_max, _ := find_edited_text(commands)
	middle_y := (text_min.y + text_max.y) * 0.5
	// The middle of the character at `offset`, on screen.
	character_middle :: proc(state: ^Ui_State, text_min_x: f32, offset: int, y: f32) -> [2]f32 {
		return {text_min_x - state.edit_scroll_x + (state.edit_caret_x[offset] + state.edit_caret_x[offset + 1]) * 0.5, y}
	}
	press_mouse(input, character_middle(state, text_min.x, 4, middle_y)) // in "cd"
	run_frame(state, input, model)
	release_mouse(input)
	run_frame(state, input, model)
	press_mouse(input, character_middle(state, text_min.x, 4, middle_y), quick = true)
	run_frame(state, input, model)
	start, end = selection_range(state)
	testing.expect(test, start == 3 && end == 5, "a double-click selects the word")
	move_mouse(input, character_middle(state, text_min.x, 7, middle_y)) // into "ef"
	run_frame(state, input, model)
	start, end = selection_range(state)
	testing.expect(test, start == 3 && end == 8, "dragging after a double-click extends by whole words")
	release_mouse(input)
	run_frame(state, input, model)
	for click in 0 ..< 3 {
		press_mouse(input, character_middle(state, text_min.x, 1, middle_y), quick = click > 0)
		run_frame(state, input, model)
		release_mouse(input)
		run_frame(state, input, model)
	}
	testing.expect(test, all_text_selected(state), "a triple-click selects everything")
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)

	// --- Text longer than its box scrolls sideways to keep the caret in view.
	LONG_TEXT :: "The quick brown fox jumps over the lazy dog, again and again"
	model.long_length = copy(model.long_bytes[:], LONG_TEXT)
	next_input(input)
	commands = run_frame(state, input, model)
	long_min, long_max, long_found := find_text_box(commands, LONG_TEXT)
	testing.expect(test, long_found, "the long text box shows its text")
	long_middle := [2]f32{long_min.x + 10, (long_min.y + long_max.y) * 0.5}
	move_mouse(input, long_middle)
	run_frame(state, input, model)
	testing.expect_value(test, output_after_frame(state).cursor, platform.Cursor.Text)
	press_mouse(input, long_middle)
	run_frame(state, input, model)
	release_mouse(input)
	run_frame(state, input, model) // typing starts with everything selected, the caret at the end
	next_input(input)
	commands = run_frame(state, input, model)
	text_min, text_max, _ = find_edited_text(commands)
	visible_width := text_max.x - text_min.x
	caret_on_screen := state.edit_caret_x[len(LONG_TEXT)] - state.edit_scroll_x
	testing.expectf(test, state.edit_scroll_x > 0 && caret_on_screen >= 0 && caret_on_screen <= visible_width, "the end of the text scrolls into view (scroll %v, caret at %v of %v)", state.edit_scroll_x, caret_on_screen, visible_width)
	key(state, input, model, .Home)
	testing.expect_value(test, state.edit_scroll_x, f32(0))
	key(state, input, model, .Escape)
	move_mouse(input, {600, 400})
	run_frame(state, input, model)
	testing.expect_value(test, output_after_frame(state).cursor, platform.Cursor.Default)
	free_all(context.temp_allocator)

	// --- Drawing: the selection, the glyphs and the caret all sit on the measured positions, and
	// the caret blinks. (The renderer's 2D overlay only collects quads on the CPU.)
	start_typing(state, input, model, "ab cd")
	key(state, input, model, .End)
	key(state, input, model, .Left, shift = true, ctrl = true) // "cd" selected, the caret at 3
	next_input(input)
	commands = run_frame(state, input, model)
	text_min, text_max, _ = find_edited_text(commands)
	renderer := new(render.Renderer)
	defer free(renderer)
	renderer.surface_size = input.window_size
	render.begin_frame(renderer, input.window_size)
	state.edit_blink_seconds = 0
	draw_edited_text(state, renderer, text_min, text_max, {0, 0}, {1200, 800})
	origin_x := math.round(text_min.x - state.edit_scroll_x)
	shapes, glyphs: [dynamic]render.Overlay_Quad
	defer delete(shapes)
	defer delete(glyphs)
	for quad in renderer.overlay_quads[:renderer.overlay_quad_count] {
		append(&glyphs if quad.mode == .Glyph else &shapes, quad)
	}
	testing.expect_value(test, len(shapes), 2) // the selection, then the caret
	if len(shapes) == 2 {
		selection, caret := shapes[0], shapes[1]
		testing.expect(test, abs(selection.rect_min.x - (origin_x + state.edit_caret_x[3])) < 0.01 && abs(selection.rect_max.x - (origin_x + state.edit_caret_x[5])) < 0.01, "the highlight spans the selected characters' boundaries")
		testing.expect(test, abs(caret.rect_min.x - math.round(origin_x + state.edit_caret_x[3])) < 0.01, "the caret is drawn at its boundary")
	}
	if len(glyphs) >= 4 {
		letter_c := glyphs[3]
		testing.expectf(test, letter_c.rect_min.x >= origin_x + state.edit_caret_x[3] - 1 && letter_c.rect_max.x <= origin_x + state.edit_caret_x[4] + 1, "the glyph c sits between its boundaries (%v..%v vs %v..%v)", letter_c.rect_min.x, letter_c.rect_max.x, origin_x + state.edit_caret_x[3], origin_x + state.edit_caret_x[4])
	}
	render.begin_frame(renderer, input.window_size)
	state.edit_blink_seconds = CARET_BLINK_SECONDS + 0.01 // the off half of the blink
	draw_edited_text(state, renderer, text_min, text_max, {0, 0}, {1200, 800})
	shape_count := 0
	for quad in renderer.overlay_quads[:renderer.overlay_quad_count] {
		if quad.mode != .Glyph {
			shape_count += 1
		}
	}
	testing.expect_value(test, shape_count, 1) // only the selection
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)
}
