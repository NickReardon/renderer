// Tests for the view gizmo and the orthographic camera: simulated clicks on the knobs' exact
// screen positions. Run with `build.bat test`.
package game

import "core:math"
import "core:math/linalg"
import "core:testing"
import "engine:core"
import "engine:platform"

@(private = "file")
make_view_test_memory :: proc() -> ^Game_Memory {
	memory := new(Game_Memory)
	memory.camera = default_viewport_camera()
	memory.viewport_min, memory.viewport_max = {0, 0}, {1000, 800}
	memory.user_interface.scale = 1
	return memory
}

@(private = "file")
click_at :: proc(memory: ^Game_Memory, pixel: [2]f32) -> (owned: bool) {
	input: platform.Input
	input.mouse_position = pixel
	input.mouse[.Left] = {down = true, pressed = true}
	return update_view_gizmo(memory, &input, true)
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
