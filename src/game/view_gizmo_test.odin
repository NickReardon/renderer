// Tests for the view gizmo and the orthographic camera: simulated clicks on the knobs' exact
// screen positions. Run with `build.bat test`.
package game

import "core:math"
import "core:math/linalg"
import "core:testing"
import "engine:core"
import "engine:platform"
import "engine:render"

@(private = "file")
make_view_test_memory :: proc() -> ^Game_Memory {
	memory := new(Game_Memory)
	memory.camera = default_viewport_camera()
	memory.viewport_min, memory.viewport_max = {0, 0}, {1000, 800}
	memory.user_interface.scale = 1
	return memory
}

@(private = "file")
// A press and, on the next frame, a release at the same pixel. Clicks act on the release; the
// animation it starts is then run to the end.
click_at :: proc(memory: ^Game_Memory, pixel: [2]f32) -> (owned: bool) {
	owned = press_at(memory, pixel)
	release := mouse_frame(pixel, {}, false, false)
	update_view_gizmo(memory, &release, true)
	advance_viewport_camera(&memory.camera, 1)
	return
}

@(private = "file")
press_at :: proc(memory: ^Game_Memory, pixel: [2]f32) -> (owned: bool) {
	press := mouse_frame(pixel, {}, true, true)
	return update_view_gizmo(memory, &press, true)
}

@(private = "file")
mouse_frame :: proc(position, delta: [2]f32, pressed, down: bool) -> (input: platform.Input) {
	input.mouse_position = position
	input.mouse_delta = delta
	input.mouse[.Left] = {down = down, pressed = pressed, released = !down}
	return
}

@(private = "file")
click_knob :: proc(memory: ^Game_Memory, direction_index: int) -> (owned: bool) {
	return click_at(memory, compute_view_gizmo_layout(memory).knob_centers[direction_index])
}

@(private = "file")
directions_match :: proc(first, second: [3]f32) -> bool {
	return linalg.length(linalg.normalize(first) - linalg.normalize(second)) < 1e-4
}

// A direction `degrees` away from `direction`, tilted toward an arbitrary side.
@(private = "file")
tilted_from :: proc(direction: [3]f32, degrees: f32) -> [3]f32 {
	unit := linalg.normalize(direction)
	side := linalg.normalize(linalg.cross(unit, [3]f32{0.3, 0.5, 0.8}))
	angle := math.to_radians(degrees)
	return unit * math.cos(angle) + side * math.sin(angle)
}

@(test)
test_view_gizmo_axis_views :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	directions := VIEW_GIZMO_DIRECTIONS
	names := VIEW_GIZMO_AXIS_VIEW_NAMES
	testing.expect_value(test, view_gizmo_axis_view_name(memory.camera), "")

	// Each axis knob puts the eye on that side. Start from a view where the knob faces the viewer,
	// 40° off centre, so neither the centre square nor a corner knob covers it.
	for axis_index in 0 ..< 6 {
		memory.camera = default_viewport_camera()
		snap_viewport_camera(&memory.camera, tilted_from(directions[axis_index], 40))
		pivot, distance := memory.camera.pivot, memory.camera.distance
		testing.expect(test, click_knob(memory, axis_index), "a click on a knob is the gizmo's")
		testing.expectf(test, directions_match(viewport_camera_eye_direction(memory.camera), directions[axis_index]), "%s view: eye on the %v side", names[axis_index], directions[axis_index])
		testing.expect_value(test, view_gizmo_axis_view_name(memory.camera), names[axis_index])
		testing.expect(test, memory.camera.pivot == pivot && memory.camera.distance == distance, "snapping only turns the camera")
	}

	// Top view: looking straight down, +X to the right and the scene's back (-Z) at the top.
	snap_viewport_camera(&memory.camera, {0, 1, 0})
	forward, right, up := viewport_camera_basis(memory.camera)
	testing.expect(test, directions_match(forward, -core.WORLD_UP), "Top looks down")
	testing.expect(test, directions_match(right, core.WORLD_RIGHT), "Top has +X on the right")
	testing.expect(test, directions_match(up, core.WORLD_FORWARD), "Top has -Z at the top of the screen")
}

@(test)
test_view_gizmo_corner_views :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	directions := VIEW_GIZMO_DIRECTIONS
	corner_index := 6 // +X +Y +Z
	snap_viewport_camera(&memory.camera, tilted_from(directions[corner_index], 40))
	testing.expect(test, click_knob(memory, corner_index), "a click on a corner knob is the gizmo's")
	testing.expect(test, directions_match(viewport_camera_eye_direction(memory.camera), directions[corner_index]), "eye on the corner's diagonal")
	// The isometric angle: atan(1 / sqrt(2)), about 35.26° above the horizon.
	testing.expect(test, abs(memory.camera.pitch - math.atan(1 / math.sqrt(f32(2)))) < 1e-5, "isometric pitch")
	testing.expect(test, abs(memory.camera.yaw - math.PI / 4) < 1e-5, "yaw 45°")
}

@(test)
test_view_gizmo_projection_toggle :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	layout := compute_view_gizmo_layout(memory)
	testing.expect(test, click_at(memory, layout.center), "the centre square is the gizmo's")
	testing.expect(test, memory.camera.orthographic, "the centre square switches to orthographic")
	testing.expect(test, click_at(memory, (layout.label_min + layout.label_max) * 0.5), "the label is the gizmo's")
	testing.expect(test, !memory.camera.orthographic, "the label switches back")

	// In the Front view the +Z knob sits exactly on the centre square; the square still wins.
	snap_viewport_camera(&memory.camera, {0, 0, 1})
	click_at(memory, compute_view_gizmo_layout(memory).center)
	testing.expect(test, memory.camera.orthographic, "the centre square is on top of a knob facing the viewer")

	// Away from every part, the mouse stays the view's.
	testing.expect(test, !click_at(memory, {500, 400}), "clicks in the scene aren't the gizmo's")
}

// Orthographic picking and drawing must agree: the ray through the pixel where a point is
// drawn passes through that point, and rays are parallel.
@(test)
test_orthographic_ray_matches_projection :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	memory.camera.orthographic = true
	snap_viewport_camera(&memory.camera, {0, 1, 0}) // Top: the pole, where look_at with WORLD_UP fails
	point := [3]f32{1.5, 0.25, -0.75}
	view_projection := viewport_view_projection(memory)
	pixel, visible := project_to_pixel(view_projection, memory.viewport_min, memory.viewport_max, point)
	testing.expect(test, visible, "the point is in view")
	ray := viewport_ray(memory, pixel)
	to_point := point - ray.origin
	along := linalg.dot(to_point, ray.direction)
	testing.expect(test, along > 0, "the ray starts behind the point (at the near plane)")
	testing.expect(test, linalg.length(to_point - ray.direction * along) < 1e-3, "the ray passes through the drawn point")
	other := viewport_ray(memory, {100, 100})
	testing.expect(test, directions_match(ray.direction, other.direction), "orthographic rays are parallel")

	// Constant size on screen: one pixel is the same world size at any depth.
	near_size := viewport_camera_world_per_pixel(memory.camera, {0, 3, 0}, 800)
	far_size := viewport_camera_world_per_pixel(memory.camera, {0, -3, 0}, 800)
	testing.expect(test, abs(near_size - far_size) < 1e-6, "orthographic pixel size doesn't change with depth")
}

@(test)
test_grid_plane_for_view :: proc(test: ^testing.T) {
	camera := default_viewport_camera()
	snap_viewport_camera(&camera, {0, 0, 1})
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.XZ) // perspective: always the ground
	camera.orthographic = true
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.XY) // Front
	snap_viewport_camera(&camera, {0, 0, -1})
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.XY) // Back
	snap_viewport_camera(&camera, {-1, 0, 0})
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.YZ) // Left
	snap_viewport_camera(&camera, {0, 1, 0})
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.XZ) // Top
	snap_viewport_camera(&camera, {1, 1, 1})
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.XZ) // isometric: the ground, seen at 35°
	snap_viewport_camera(&camera, {1, 0.3, 0.2})
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.YZ) // mostly from the side
	snap_viewport_camera(&camera, {0.52, 0.42, 0.74}) // the default angle, 25° above the ground
	testing.expect_value(test, grid_plane_for_view(camera), render.Grid_Plane.XZ) // ground: still readable
}

@(test)
test_view_gizmo_drag_orbits :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	start := default_viewport_camera()
	layout := compute_view_gizmo_layout(memory)

	// Pressing a knob does nothing yet: it might be the start of a drag.
	knob := layout.knob_centers[0] // +X
	testing.expect(test, press_at(memory, knob), "a press on a knob is the gizmo's")
	testing.expect(test, memory.camera == start, "a press alone doesn't snap")

	// Moving past the click tolerance orbits by the mouse movement, exactly like Alt + left drag.
	expected := start
	delta := [2]f32{30, -12}
	orbit_viewport_camera(&expected, delta)
	drag := mouse_frame(knob + delta, delta, false, true)
	testing.expect(test, update_view_gizmo(memory, &drag, true), "the gizmo keeps the mouse while dragging")
	testing.expect(test, memory.editor.view_gizmo_dragging, "moved past the tolerance: dragging")
	testing.expect(test, memory.camera == expected, "dragging orbits")

	// The drag keeps going outside the gizmo and over the panels (no viewport mouse).
	far_away := mouse_frame({20, 700}, delta, false, true)
	testing.expect(test, update_view_gizmo(memory, &far_away, false), "the drag keeps the mouse anywhere")
	orbit_viewport_camera(&expected, delta)
	testing.expect(test, memory.camera == expected, "dragging over panels still orbits")

	// Releasing after a drag doesn't click the knob it started on.
	release := mouse_frame({20, 700}, {}, false, false)
	update_view_gizmo(memory, &release, false)
	testing.expect(test, memory.camera == expected, "no snap after a drag")
	testing.expect_value(test, memory.editor.view_gizmo_pressed, View_Gizmo_Part.None)

	// The empty disc between the knobs can be dragged too, but clicking it does nothing.
	layout = compute_view_gizmo_layout(memory)
	empty: [2]f32
	found_empty := false
	for step in 0 ..< 36 {
		angle := f32(step) * math.PI / 18
		candidate := layout.center + [2]f32{math.cos(angle), math.sin(angle)} * (layout.background_radius - 2)
		if part, _ := view_gizmo_part_under_mouse(layout, candidate); part == .Background {
			empty, found_empty = candidate, true
			break
		}
	}
	testing.expect(test, found_empty, "the disc's rim has empty space between knobs")
	before := memory.camera
	testing.expect(test, click_at(memory, empty), "the empty disc is the gizmo's")
	testing.expect(test, memory.camera == before, "clicking the empty disc changes nothing")

	// A small wobble within the tolerance is still a click.
	memory.camera = start
	testing.expect(test, press_at(memory, knob), "press")
	wobble := mouse_frame(knob + {2, 1}, {2, 1}, false, true)
	update_view_gizmo(memory, &wobble, true)
	release_on_knob := mouse_frame(knob + {2, 1}, {}, false, false)
	update_view_gizmo(memory, &release_on_knob, true)
	advance_viewport_camera(&memory.camera, 1)
	testing.expect(test, directions_match(viewport_camera_eye_direction(memory.camera), {1, 0, 0}), "a wobbly click still snaps")
}

@(test)
test_view_snap_animates :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	start := memory.camera
	knob := compute_view_gizmo_layout(memory).knob_centers[0] // +X
	press_at(memory, knob)
	release := mouse_frame(knob, {}, false, false)
	update_view_gizmo(memory, &release, true)
	testing.expect(test, memory.camera.yaw == start.yaw && memory.camera.pitch == start.pitch, "the click starts a move; nothing jumps")

	// Part-way: between the start and the Right view, eased (more than half done at half time).
	advance_viewport_camera(&memory.camera, CAMERA_MOVE_SECONDS * 0.5)
	right_yaw := f32(math.PI / 2)
	fraction := (memory.camera.yaw - start.yaw) / (right_yaw - start.yaw)
	testing.expect(test, fraction > 0.5 && fraction < 1, "half time: past half way (ease out), not there yet")
	testing.expect(test, memory.camera.pivot == start.pivot && abs(memory.camera.distance - start.distance) < 1e-5, "a view snap only turns")

	advance_viewport_camera(&memory.camera, CAMERA_MOVE_SECONDS)
	testing.expect(test, directions_match(viewport_camera_eye_direction(memory.camera), {1, 0, 0}), "ends exactly in the Right view")
	testing.expect_value(test, memory.camera.transition_remaining, f32(0))

	// The short way round: from 170° to -170° is a 20° turn.
	memory.camera.yaw = math.to_radians(f32(170))
	target := viewport_camera_target_pose(memory.camera)
	target.yaw = math.to_radians(f32(-170))
	move_viewport_camera(&memory.camera, target)
	testing.expect(test, abs(memory.camera.transition_to.yaw - math.to_radians(f32(190))) < 1e-4, "yaw turns 20°, not 340°")

	// Orbiting takes over from a move, as in Unity.
	orbit_viewport_camera(&memory.camera, {10, 0})
	testing.expect_value(test, memory.camera.transition_remaining, f32(0))
}

@(test)
test_projection_switch_animates :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	camera := &memory.camera
	pixel_at_pivot := viewport_camera_world_per_pixel(camera^, camera.pivot, 800)

	switch_viewport_projection(camera)
	testing.expect(test, camera.orthographic, "the setting changes at once")
	for _ in 1 ..= 9 {
		advance_viewport_camera(camera, PROJECTION_SWITCH_SECONDS * 0.1)
		lens := viewport_camera_lens(camera^)
		testing.expect(test, !lens.orthographic, "mid-switch the view is a narrowing perspective")
		testing.expect(test, lens.eye_distance > camera.distance, "the eye backs away as the field of view narrows")
		// The dolly zoom: the pivot's surroundings keep their size on screen throughout.
		testing.expect(test, abs(viewport_camera_world_per_pixel(camera^, camera.pivot, 800) - pixel_at_pivot) < 1e-5 * pixel_at_pivot, "constant size at the pivot")
	}
	advance_viewport_camera(camera, PROJECTION_SWITCH_SECONDS)
	testing.expect(test, viewport_camera_lens(camera^).orthographic, "orthographic at the end")
	testing.expect(test, abs(viewport_camera_world_per_pixel(camera^, camera.pivot, 800) - pixel_at_pivot) < 1e-5 * pixel_at_pivot, "orthographic has the same size")

	// Switching back mid-way reverses from where it is, without a jump.
	switch_viewport_projection(camera)
	advance_viewport_camera(camera, PROJECTION_SWITCH_SECONDS * 0.3)
	before := viewport_camera_lens(camera^).tan_half_fov
	switch_viewport_projection(camera) // back to orthographic, from 30% of the way to perspective
	testing.expect(test, abs(viewport_camera_lens(camera^).tan_half_fov - before) < 1e-6, "reversing doesn't jump")
}

// F, then orbit: the framed object stays in the middle of the view, because orbiting turns
// around the pivot and F puts the pivot on the selection.
@(test)
test_orbit_after_frame_keeps_object_centred :: proc(test: ^testing.T) {
	memory := make_view_test_memory()
	defer free(memory)
	_, entity := create_entity(&memory.scene, "Cube")
	entity.position = {3, 1, -2}
	entity.flags += {.Selected}
	frame_selection(memory)
	advance_viewport_camera(&memory.camera, 1)
	testing.expect(test, linalg.length(memory.camera.pivot - entity.position) < 1e-4, "F puts the pivot on the object")
	view_center := (memory.viewport_min + memory.viewport_max) * 0.5
	for _ in 0 ..< 4 {
		orbit_viewport_camera(&memory.camera, {120, -35})
		pixel, _ := project_to_pixel(viewport_view_projection(memory), memory.viewport_min, memory.viewport_max, entity.position)
		testing.expect(test, linalg.length(pixel - view_center) < 0.01, "the object stays centred while orbiting")
	}
}
