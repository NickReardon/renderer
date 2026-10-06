// Tests for undo and redo: edits made directly on the scene (as the Inspector and shortcuts
// do), then committed the way the frame loop commits them. Run with `build.bat test`.
package game

import "core:testing"
import "engine:platform"

@(private = "file")
Undo_Test :: struct {
	scene:   Scene,
	history: Undo_History,
}

// Two entities, "A" at the origin (selected) and "B" at x = 5, with an empty history.
@(private = "file")
make_undo_test :: proc() -> (^Undo_Test, Entity_Handle, Entity_Handle) {
	test_data := new(Undo_Test)
	first_handle, first := create_entity(&test_data.scene, "A")
	first.flags += {.Selected}
	second_handle, second := create_entity(&test_data.scene, "B")
	second.position = {5, 0, 0}
	reset_undo_history(&test_data.history, &test_data.scene)
	return test_data, first_handle, second_handle
}

@(test)
test_undo_redo_edit :: proc(test: ^testing.T) {
	test_data, first_handle, _ := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	testing.expect(test, !commit_undo_step(history, scene), "no change, no step")
	first, _ := get_entity(scene, first_handle)
	first.position = {1, 2, 3}
	first.color = {1, 0, 0}
	testing.expect(test, commit_undo_step(history, scene), "an edit makes a step")
	testing.expect(test, !commit_undo_step(history, scene), "the same edit isn't recorded twice")

	testing.expect(test, undo(history, scene), "there is a step to undo")
	testing.expect(test, first.position == {0, 0, 0} && first.color == {0.8, 0.8, 0.8}, "undo restores every changed field")
	testing.expect(test, !undo(history, scene), "nothing more to undo")
	testing.expect(test, !commit_undo_step(history, scene), "an undo isn't itself a new edit")

	testing.expect(test, redo(history, scene), "there is a step to redo")
	testing.expect(test, first.position == {1, 2, 3} && first.color == {1, 0, 0}, "redo reapplies the edit")
	testing.expect(test, !redo(history, scene), "nothing more to redo")
}

@(test)
test_undo_ignores_selection_only_changes :: proc(test: ^testing.T) {
	test_data, first_handle, second_handle := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	select_only(scene, second_handle)
	testing.expect(test, !commit_undo_step(history, scene), "selecting isn't an undo step")
	undoable, _ := undo_counts(history)
	testing.expect_value(test, undoable, 0)

	// Move A while B is selected, select B again, then undo: A is back and selected alone, as
	// it was when the move happened.
	select_only(scene, first_handle)
	commit_undo_step(history, scene) // the click and the later drag are separate frames
	first, _ := get_entity(scene, first_handle)
	first.position.y = 4
	commit_undo_step(history, scene)
	select_only(scene, second_handle)
	commit_undo_step(history, scene)
	undo(history, scene)
	second, _ := get_entity(scene, second_handle)
	testing.expect(test, first.position.y == 0, "the move is undone")
	testing.expect(test, .Selected in first.flags && !(.Selected in second.flags), "undo restores the selection of the step")
}

@(test)
test_undo_delete_keeps_handles :: proc(test: ^testing.T) {
	test_data, first_handle, _ := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	destroy_entity(scene, first_handle)
	commit_undo_step(history, scene)
	undo(history, scene)
	restored, found := get_entity(scene, first_handle)
	testing.expect(test, found && entity_name(restored) == "A" && .Selected in restored.flags, "undoing a delete brings the entity back under its old handle, selected")

	// Redo the delete, make something new in the freed slot, then undo back past both: the old
	// entity returns with its old handle, and the new one's handle never matched it.
	redo(history, scene)
	new_handle, _ := create_entity(scene, "New")
	commit_undo_step(history, scene)
	testing.expect(test, new_handle.index == first_handle.index && new_handle.generation != first_handle.generation, "the slot is reused with a new generation")
	undo(history, scene)
	undo(history, scene)
	_, old_found := get_entity(scene, first_handle)
	_, new_found := get_entity(scene, new_handle)
	testing.expect(test, old_found && !new_found, "the old handle works again; the new one doesn't")

	// A third entity in that slot (after the old one is deleted again) still gets a generation
	// no handle has had, even though undo moved the slot's generation back.
	destroy_entity(scene, first_handle)
	third_handle, _ := create_entity(scene, "Third")
	testing.expect(test, third_handle.generation != first_handle.generation && third_handle.generation != new_handle.generation, "generations are never reused")
}

@(test)
test_undo_duplicate_reselects_originals :: proc(test: ^testing.T) {
	test_data, first_handle, _ := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	duplicate_selection(scene)
	commit_undo_step(history, scene)
	count, copy_handle := selected_count(scene)
	testing.expect(test, count == 1 && copy_handle != first_handle, "the copy is selected")

	undo(history, scene)
	_, copy_found := get_entity(scene, copy_handle)
	first, _ := get_entity(scene, first_handle)
	testing.expect(test, !copy_found, "undo removes the copy")
	testing.expect(test, .Selected in first.flags, "undo reselects the original")
}

@(test)
test_undo_new_edit_clears_redo :: proc(test: ^testing.T) {
	test_data, first_handle, _ := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	first, _ := get_entity(scene, first_handle)
	first.position.x = 1
	commit_undo_step(history, scene)
	first.position.x = 2
	commit_undo_step(history, scene)
	undo(history, scene)
	first.position.z = 7
	commit_undo_step(history, scene)
	undoable, redoable := undo_counts(history)
	testing.expect(test, undoable == 2 && redoable == 0, "a new edit after undo ends the redo branch")
	undo(history, scene)
	undo(history, scene)
	testing.expect(test, first.position == {0, 0, 0}, "both remaining steps undo cleanly")
}

@(test)
test_undo_drops_oldest_when_full :: proc(test: ^testing.T) {
	test_data, first_handle, _ := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	first, _ := get_entity(scene, first_handle)
	edit_count := MAX_UNDO_STEPS + 10
	for edit_index in 1 ..= edit_count {
		first.position.x = f32(edit_index)
		commit_undo_step(history, scene)
	}
	undoable, _ := undo_counts(history)
	testing.expect_value(test, undoable, MAX_UNDO_STEPS)
	for undo(history, scene) {}
	testing.expect_value(test, first.position.x, f32(edit_count - MAX_UNDO_STEPS))
}

// A gizmo drag over several frames, committed the way game_update does it, is one step.
@(test)
test_undo_gizmo_drag_is_one_step :: proc(test: ^testing.T) {
	memory := new(Game_Memory)
	defer free(memory)
	memory.camera = default_viewport_camera()
	memory.viewport_min, memory.viewport_max = {0, 0}, {1000, 800}
	memory.user_interface.scale = 1
	memory.gizmo.tool = .Move
	_, entity := create_entity(&memory.scene, "Cube")
	entity.flags += {.Selected}
	reset_undo_history(&memory.undo_history, &memory.scene)

	frame := compute_gizmo_frame(memory)
	run_frame :: proc(memory: ^Game_Memory, input: ^platform.Input) {
		update_gizmo(memory, input, true)
		if !edit_in_progress(memory, input) {
			commit_undo_step(&memory.undo_history, &memory.scene)
		}
	}
	along_x :: proc(frame: Gizmo_Frame, fraction: f32) -> [2]f32 {
		pixel, _ := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + frame.axes[0] * frame.world_length * fraction)
		return pixel
	}
	press := platform.Input{mouse_position = along_x(frame, 0.5)}
	press.mouse[.Left] = {down = true, pressed = true}
	run_frame(memory, &press)
	for fraction in ([]f32{0.8, 1.1, 1.5}) {
		drag := platform.Input{mouse_position = along_x(frame, fraction)}
		drag.mouse[.Left] = {down = true}
		run_frame(memory, &drag)
	}
	release := platform.Input{mouse_position = along_x(frame, 1.5)}
	release.mouse[.Left] = {released = true}
	run_frame(memory, &release)

	undoable, _ := undo_counts(&memory.undo_history)
	testing.expect_value(test, undoable, 1)
	testing.expect(test, entity.position.x > 0.1, "the drag moved the cube")
	undo(&memory.undo_history, &memory.scene)
	testing.expect(test, entity.position == {0, 0, 0}, "one undo returns it to where the drag started")
}

// The review's case: type a Position value, then click Create. The press applies the typed value
// (the UI reports it and game_update commits right after the UI pass); the cube is created on
// release and committed at the end of that frame. Undo must remove only the cube.
@(test)
test_undo_typed_value_then_button_are_separate_steps :: proc(test: ^testing.T) {
	test_data, first_handle, _ := make_undo_test()
	defer free(test_data)
	scene, history := &test_data.scene, &test_data.history

	// Press frame: the field applies its value (mouse down, so the end-of-frame commit is skipped).
	first, _ := get_entity(scene, first_handle)
	first.position.x = 4
	commit_undo_step(history, scene) // game_update: ui.typed_value_applied
	// Release frame: the button creates a cube; the end-of-frame commit records it.
	cube_handle := create_primitive_entity(scene, .Cube, {}, {1, 1, 1})
	commit_undo_step(history, scene)

	undo(history, scene)
	_, cube_found := get_entity(scene, cube_handle)
	testing.expect(test, !cube_found && first.position.x == 4, "the first undo removes only the cube")
	undo(history, scene)
	testing.expect(test, first.position.x == 0, "the second undo reverts the typed value")
}
