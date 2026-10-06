// UI tests: run real frames (Clay layout, fontstash measuring, widget logic) with simulated
// input, without a GPU. Widgets are found the way UI test tools do it: by the text they show.
//
// Clay keeps its current context in a process-wide global, so everything runs in one test
// procedure rather than several tests that the runner would execute in parallel.
package ui

import "core:testing"
import "engine:platform"
import clay "engine:third_party/clay"

Test_Model :: struct {
	number:       f32,
	flag:         bool,
	button_count: int,
}

@(private = "file")
run_frame :: proc(state: ^Ui_State, input: ^platform.Input, model: ^Test_Model) -> clay.ClayArray(clay.RenderCommand) {
	begin_frame(state, input)
	flexible_space(state, "Test viewport")
	if panel(state, "Test panel", 300) {
		number_field(state, "Number", &model.number, 0.1, -100, 100, "%.3f")
		checkbox(state, "Flag", &model.flag)
		if button(state, "Press me") {
			model.button_count += 1
		}
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
	testing.expect(test, state.edit_all_selected, "editing should start with the whole value selected")
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

	// --- The mouse belongs to the viewport outside the panel, and to the UI over it.
	move_mouse(&input, {100, 400})
	run_frame(state, &input, &model)
	testing.expect(test, !wants_mouse(state), "the viewport area should keep the mouse")
	move_mouse(&input, button_center)
	run_frame(state, &input, &model)
	testing.expect(test, wants_mouse(state), "the panel should take the mouse")
	free_all(context.temp_allocator)
}
