// Tests for the transform gizmo: simulated mouse input on exact projected points, so the
// expected results are exact. Run with `build.bat test`.
package game

import "core:math"
import "core:testing"
import "engine:platform"

// A scene with one selected cube at the origin, the default camera, and a 1000 x 800 view.
@(private = "file")
make_gizmo_test_memory :: proc(tool: Transform_Tool) -> ^Game_Memory {
	memory := new(Game_Memory)
	memory.camera = default_viewport_camera()
	memory.viewport_min, memory.viewport_max = {0, 0}, {1000, 800}
	memory.user_interface.scale = 1
	memory.gizmo.tool = tool
	_, entity := create_entity(&memory.scene, "Cube")
	entity.flags += {.Selected}
	return memory
}

@(private = "file")
pixel_of :: proc(memory: ^Game_Memory, frame: Gizmo_Frame, axis: int, length_fraction: f32) -> [2]f32 {
	pixel, _ := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + frame.axes[axis] * frame.world_length * length_fraction)
	return pixel
}

// A point on the rotation ring around `axis`, at `degrees` along it (same parameterization as
// the gizmo: the next two axes in order are the ring's 0° and 90° directions).
@(private = "file")
ring_point_pixel :: proc(memory: ^Game_Memory, frame: Gizmo_Frame, axis: int, degrees: f32) -> [2]f32 {
	angle := degrees * math.PI / 180
	offset := (frame.axes[(axis + 1) % 3] * math.cos(angle) + frame.axes[(axis + 2) % 3] * math.sin(angle)) * frame.world_length
	pixel, _ := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + offset)
	return pixel
}

@(private = "file")
mouse_input :: proc(position: [2]f32, pressed, down: bool) -> (input: platform.Input) {
	input.mouse_position = position
	input.mouse[.Left] = {down = down, pressed = pressed, released = !down}
	return
}

@(test)
test_gizmo_move :: proc(test: ^testing.T) {
	memory := make_gizmo_test_memory(.Move)
	defer free(memory)
	frame := compute_gizmo_frame(memory)
	testing.expect(test, frame.visible, "the gizmo should be visible on the selected cube")

	// Press halfway along the X arrow, drag to 1.5 lengths: the cube moves exactly 1 length on X.
	press := mouse_input(pixel_of(memory, frame, 0, 0.5), true, true)
	testing.expect(test, update_gizmo(memory, &press, true), "pressing the X arrow should be the gizmo's")
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.X)
	drag := mouse_input(pixel_of(memory, frame, 0, 1.5), false, true)
	update_gizmo(memory, &drag, true)
	entity := &memory.scene.entities[1]
	testing.expectf(test, abs(entity.position.x - frame.world_length) < 1e-3 && abs(entity.position.y) < 1e-5 && abs(entity.position.z) < 1e-5, "moved along X only by one length, got %v", entity.position)

	// Back to the press point: back to the start (computed from the press, so no drift).
	back := mouse_input(pixel_of(memory, frame, 0, 0.5), false, true)
	update_gizmo(memory, &back, true)
	testing.expectf(test, abs(entity.position.x) < 1e-4, "returning the mouse should return the cube, got %v", entity.position)

	// Escape cancels and restores; the drag ends.
	update_gizmo(memory, &drag, true)
	escape := drag
	escape.keys[.Escape] = {down = true, pressed = true}
	update_gizmo(memory, &escape, true)
	testing.expect(test, entity.position == {0, 0, 0} && memory.gizmo.active == .None, "Escape should restore the original position")

	// A press away from every handle isn't the gizmo's (it becomes a selection click instead).
	elsewhere := mouse_input({20, 20}, true, true)
	testing.expect(test, !update_gizmo(memory, &elsewhere, true), "a press far from the gizmo should not start a drag")
}

@(test)
test_gizmo_rotate :: proc(test: ^testing.T) {
	memory := make_gizmo_test_memory(.Rotate)
	defer free(memory)
	frame := compute_gizmo_frame(memory)

	// Points on the Y ring are Z cos(a) + X sin(a). Press at 45° (only the Y ring passes there; the
	// ring ends at +Z and +X are shared with the other rings) and drag to 135°: that turns +Z toward
	// +X, a positive rotation about Y (right-hand rule). The angle swept on screen isn't exactly
	// 90° because the ring is seen at an angle, so check direction and rough size.
	press := mouse_input(ring_point_pixel(memory, frame, 1, 45), true, true)
	update_gizmo(memory, &press, true)
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.Y)
	drag := mouse_input(ring_point_pixel(memory, frame, 1, 135), false, true)
	update_gizmo(memory, &drag, true)
	rotation := memory.scene.entities[1].rotation
	testing.expectf(test, rotation.y > 30 && rotation.y < 150 && abs(rotation.x) < 1e-3 && abs(rotation.z) < 1e-3, "should rotate about Y only, positively, got %v", rotation)
}

@(test)
test_gizmo_scale :: proc(test: ^testing.T) {
	memory := make_gizmo_test_memory(.Scale)
	defer free(memory)
	frame := compute_gizmo_frame(memory)

	// Press at half the X handle, drag to its full length: the X scale doubles, exactly.
	press := mouse_input(pixel_of(memory, frame, 0, 0.5), true, true)
	update_gizmo(memory, &press, true)
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.X)
	drag := mouse_input(pixel_of(memory, frame, 0, 1), false, true)
	update_gizmo(memory, &drag, true)
	scale := memory.scene.entities[1].scale
	testing.expectf(test, abs(scale.x - 2) < 1e-3 && scale.y == 1 && scale.z == 1, "X scale should double, got %v", scale)

	// Release ends the drag; the centre handle then scales uniformly (right = bigger).
	release := mouse_input(pixel_of(memory, frame, 0, 1), false, false)
	update_gizmo(memory, &release, true)
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.None)
	center_press := mouse_input(frame.origin_pixel, true, true)
	update_gizmo(memory, &center_press, true)
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.Center)
	center_drag := mouse_input(frame.origin_pixel + {UNIFORM_SCALE_POINTS_PER_DOUBLING, 0}, false, true)
	update_gizmo(memory, &center_drag, true)
	uniform := memory.scene.entities[1].scale
	testing.expectf(test, abs(uniform.x - 4) < 1e-3 && abs(uniform.y - 2) < 1e-3 && abs(uniform.z - 2) < 1e-3, "one doubling distance should double every axis, got %v", uniform)
}

@(test)
test_gizmo_hidden_for_hand_tool_and_empty_selection :: proc(test: ^testing.T) {
	memory := make_gizmo_test_memory(.Hand)
	defer free(memory)
	testing.expect(test, !compute_gizmo_frame(memory).visible, "the Hand tool has no gizmo")
	memory.gizmo.tool = .Move
	memory.scene.entities[1].flags -= {.Selected}
	testing.expect(test, !compute_gizmo_frame(memory).visible, "no selection, no gizmo")

}
