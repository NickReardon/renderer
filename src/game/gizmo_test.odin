// Tests for the transform gizmo: simulated mouse input on exact projected points, so the
// expected results are exact. Run with `build.bat test`.
package game

import "core:math"
import "core:math/linalg"
import "core:testing"
import "engine:core"
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

@(test)
test_gizmo_move_in_plane :: proc(test: ^testing.T) {
	memory := make_gizmo_test_memory(.Move)
	defer free(memory)
	frame := compute_gizmo_frame(memory)

	// Press in the middle of the XY square (it faces Z), drag one handle length along its first
	// edge and half along its second: the cube moves exactly that much, and not at all along Z.
	corners := plane_handle_world_corners(frame, 2)
	center := (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25
	first_direction := linalg.normalize(corners[1] - corners[0])
	second_direction := linalg.normalize(corners[3] - corners[0])
	center_pixel, _ := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, center)
	press := mouse_input(center_pixel, true, true)
	update_gizmo(memory, &press, true)
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.Plane_XY)

	expected := first_direction * frame.world_length + second_direction * frame.world_length * 0.5
	target_pixel, _ := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, center + expected)
	drag := mouse_input(target_pixel, false, true)
	update_gizmo(memory, &drag, true)
	position := memory.scene.entities[1].position
	testing.expectf(test, linalg.length(position - expected) < 1e-3 && abs(position.z) < 1e-5, "should move %v within the XY plane, got %v", expected, position)

	release := mouse_input(target_pixel, false, false)
	update_gizmo(memory, &release, true)

	// Looking straight down: the ZX square faces the camera and can be grabbed; the XY and YZ
	// squares are edge-on slivers, so they're hidden and their spot belongs to nothing.
	memory.camera.pitch = math.to_radians(f32(89.9))
	memory.camera.yaw = 0
	frame = compute_gizmo_frame(memory)
	corners = plane_handle_world_corners(frame, 1)
	center = (corners[0] + corners[2]) * 0.5
	center_pixel, _ = project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, center)
	hover := mouse_input(center_pixel, false, false)
	update_gizmo(memory, &hover, true)
	testing.expect_value(test, memory.gizmo.hovered, Gizmo_Part.Plane_ZX)
	corners = plane_handle_world_corners(frame, 2)
	center = (corners[0] + corners[2]) * 0.5
	center_pixel, _ = project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, center)
	hover = mouse_input(center_pixel, false, false)
	update_gizmo(memory, &hover, true)
	testing.expect(test, memory.gizmo.hovered != .Plane_XY, "an edge-on square can't be grabbed")
}

@(test)
test_gizmo_view_ring :: proc(test: ^testing.T) {
	memory := make_gizmo_test_memory(.Rotate)
	defer free(memory)
	frame := compute_gizmo_frame(memory)
	radius := view_ring_radius(frame)

	// From the ring's right edge to its top: a quarter turn counter-clockwise on screen, which is
	// +90° about the axis pointing at the viewer.
	press := mouse_input(frame.origin_pixel + {radius, 0}, true, true)
	update_gizmo(memory, &press, true)
	testing.expect_value(test, memory.gizmo.active, Gizmo_Part.View)
	drag := mouse_input(frame.origin_pixel + {0, -radius}, false, true)
	update_gizmo(memory, &drag, true)

	rotation := core.euler_rotation_matrix(memory.scene.entities[1].rotation)
	expected := linalg.matrix4_rotate_f32(math.PI / 2, frame.toward_viewer)
	for column in 0 ..< 3 {
		for row in 0 ..< 3 {
			testing.expectf(test, abs(rotation[row, column] - expected[row, column]) < 1e-3, "rotation should be 90° about the view axis; [%d,%d] is %v, expected %v", row, column, rotation[row, column], expected[row, column])
		}
	}
	// And on screen: a point to the right of the centre turns to above it.
	right := linalg.normalize(linalg.cross(core.WORLD_UP, frame.toward_viewer)) * frame.world_length
	turned := (rotation * [4]f32{right.x, right.y, right.z, 0}).xyz
	turned_pixel, _ := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + turned)
	testing.expectf(test, turned_pixel.y < frame.origin_pixel.y - radius * 0.5 && abs(turned_pixel.x - frame.origin_pixel.x) < radius * 0.1, "right should turn to up on screen, got %v from %v", turned_pixel, frame.origin_pixel)
}

// Two selected cubes at x = -2 and x = 2; the second is the active object.
@(private = "file")
make_two_cube_memory :: proc(tool: Transform_Tool, handle_position: Handle_Position) -> ^Game_Memory {
	memory := make_gizmo_test_memory(tool)
	memory.gizmo.handle_position = handle_position
	memory.scene.entities[1].position = {-2, 0, 0}
	second_handle, second := create_entity(&memory.scene, "Second")
	second.position = {2, 0, 0}
	second.flags += {.Selected}
	memory.editor.active_entity = second_handle
	return memory
}

@(test)
test_gizmo_pivot_and_center :: proc(test: ^testing.T) {
	// Where the gizmo sits: the active object's origin, or the middle of the selection's bounds.
	{
		memory := make_two_cube_memory(.Move, .Pivot)
		defer free(memory)
		testing.expect_value(test, compute_gizmo_frame(memory).origin, [3]f32{2, 0, 0})
		// The active object deselected: the gizmo falls back to the first selected one.
		memory.scene.entities[2].flags -= {.Selected}
		testing.expect_value(test, compute_gizmo_frame(memory).origin, [3]f32{-2, 0, 0})
		memory.gizmo.handle_position = .Center
		memory.scene.entities[2].flags += {.Selected}
		testing.expect_value(test, compute_gizmo_frame(memory).origin, [3]f32{0, 0, 0})
	}

	// Rotate, Pivot: each cube turns in place.
	{
		memory := make_two_cube_memory(.Rotate, .Pivot)
		defer free(memory)
		frame := compute_gizmo_frame(memory)
		press := mouse_input(ring_point_pixel(memory, frame, 1, 45), true, true)
		update_gizmo(memory, &press, true)
		drag := mouse_input(ring_point_pixel(memory, frame, 1, 135), false, true)
		update_gizmo(memory, &drag, true)
		first, second := memory.scene.entities[1], memory.scene.entities[2]
		testing.expectf(test, first.rotation.y > 30 && second.rotation.y > 30, "both should turn, got %v and %v", first.rotation, second.rotation)
		testing.expectf(test, first.position == {-2, 0, 0} && second.position == {2, 0, 0}, "Pivot keeps positions, got %v and %v", first.position, second.position)
	}

	// Rotate, Center: the pair also orbits the shared centre, staying 2 from it.
	{
		memory := make_two_cube_memory(.Rotate, .Center)
		defer free(memory)
		frame := compute_gizmo_frame(memory)
		press := mouse_input(ring_point_pixel(memory, frame, 1, 45), true, true)
		update_gizmo(memory, &press, true)
		drag := mouse_input(ring_point_pixel(memory, frame, 1, 135), false, true)
		update_gizmo(memory, &drag, true)
		first, second := memory.scene.entities[1], memory.scene.entities[2]
		testing.expectf(test, first.position != {-2, 0, 0} && abs(linalg.length(first.position) - 2) < 1e-4 && abs(first.position.y) < 1e-5, "Center orbits the centre, got %v", first.position)
		testing.expectf(test, linalg.length(first.position + second.position) < 1e-4, "the pair stays symmetric about the centre, got %v and %v", first.position, second.position)
	}

	// Scale X to double, Center: the spacing doubles too; Pivot: positions stay.
	for handle_position in Handle_Position {
		memory := make_two_cube_memory(.Scale, handle_position)
		defer free(memory)
		frame := compute_gizmo_frame(memory)
		press := mouse_input(pixel_of(memory, frame, 0, 0.5), true, true)
		update_gizmo(memory, &press, true)
		drag := mouse_input(pixel_of(memory, frame, 0, 1), false, true)
		update_gizmo(memory, &drag, true)
		first := memory.scene.entities[1]
		expected_x: f32 = -4 if handle_position == .Center else -2
		testing.expectf(test, abs(first.scale.x - 2) < 1e-3 && abs(first.position.x - expected_x) < 1e-3, "%v: scale x 2 and position x %v, got %v and %v", handle_position, expected_x, first.scale, first.position)
	}
}
