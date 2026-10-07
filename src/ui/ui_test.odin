// UI tests: run real frames (Clay layout, fontstash measuring, widget logic) with simulated
// input, without a GPU. Widgets are found the way UI test tools do it: by the text they show.
//
// Clay keeps its current context in a process-wide global, so everything runs in one test
// procedure rather than several tests that the runner would execute in parallel.
package ui

import "core:testing"
import fontstash "vendor:fontstash"
import "engine:platform"
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
		edited, result := text_box(state, "Name", string(model.name_bytes[:model.name_length]), TEST_NAME_BYTES, start_editing = model.start_rename)
		if result == .Applied {
			model.name_length = copy(model.name_bytes[:], edited)
		}
		model.name_result = result
		model.start_rename = false
	}
	return finish_layout(state)
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
}

@(private = "file")
press_mouse :: proc(input: ^platform.Input, position: [2]f32) {
	next_input(input)
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
		_, found := find_text(commands, shown)
		testing.expectf(test, found, "%s: expected a box showing %s", message, shown)
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
		center, found := find_text(commands, shown)
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
	testing.expect_value(test, state.edit_caret, 1)
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
	testing.expect_value(test, state.edit_caret, 6)
	key(state, input, model, .Backspace)
	key(state, input, model, .End)
	key(state, input, model, .Backspace)
	testing.expect_value(test, edited_text(state), "01234")
	key(state, input, model, .Escape)
	free_all(context.temp_allocator)

	// --- The text is drawn in pieces (before the selection, the selection, after it). They must
	// line up the way the caret is measured, trailing spaces included.
	model.name_length = copy(model.name_bytes[:], "ab cd")
	model.start_rename = true
	next_input(input)
	run_frame(state, input, model)
	key(state, input, model, .Home)
	key(state, input, model, .Right)
	key(state, input, model, .Right)
	key(state, input, model, .Right)
	key(state, input, model, .End, shift = true) // "ab " then "cd" selected
	next_input(input)
	commands = run_frame(state, input, model)
	before_box, selected_box: clay.BoundingBox
	for command_index in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(&commands, command_index)
		if command.commandType != .Text {
			continue
		}
		shown := command.renderData.text.stringContents
		switch string(shown.chars[:shown.length]) {
		case "ab ":
			before_box = command.boundingBox
		case "cd":
			selected_box = command.boundingBox
		}
	}
	testing.expect(test, before_box.width > 0 && selected_box.width > 0, "the text before the selection and the selection are drawn")
	set_font(state, .Regular, points(state, FONT_SIZE), 0)
	measured_width := fontstash.TextBounds(&state.font_context, "ab ")
	testing.expectf(test, abs(before_box.width - measured_width) < 0.5, "the piece \"ab \" is as wide as the caret measures it (%v vs %v)", before_box.width, measured_width)
	testing.expectf(test, abs(selected_box.x - (before_box.x + before_box.width)) < 1, "the selection starts where the text before it ends (%v vs %v)", selected_box.x, before_box.x + before_box.width)

	// --- The mouse: a press in the text puts the caret there, a drag selects.
	press_mouse(input, {before_box.x + 1, before_box.y + before_box.height * 0.5})
	run_frame(state, input, model)
	testing.expect_value(test, state.edit_caret, 0)
	start, end = selection_range(state)
	testing.expect(test, start == end, "a press clears the selection")
	move_mouse(input, {selected_box.x + 1, selected_box.y + selected_box.height * 0.5})
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
