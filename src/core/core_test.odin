// Tests for package core. Run with `build.bat test`.
package core

import "core:math"
import "core:math/linalg"
import "core:testing"

EPSILON :: 1e-5

@(test)
test_cube_counts :: proc(test: ^testing.T) {
	cube := make_cube(2, context.temp_allocator)
	testing.expect_value(test, len(cube.positions), 8)
	testing.expect_value(test, face_count(cube), 6)
	testing.expect_value(test, len(cube.corner_verts), 24)
	testing.expect_value(test, cube.face_offsets[0], 0)
	testing.expect_value(test, int(cube.face_offsets[6]), len(cube.corner_verts))
}

// Closed and consistently oriented: every directed edge a->b appears exactly once, and so does
// its reverse b->a (the neighbouring face walks the shared edge the other way).
@(test)
test_cube_is_closed_and_oriented :: proc(test: ^testing.T) {
	cube := make_cube(1, context.temp_allocator)
	directed_edge_counts := make(map[[2]u32]int, allocator = context.temp_allocator)
	for face_index in 0 ..< face_count(cube) {
		corners := face_corners(cube, face_index)
		for corner_index in 0 ..< len(corners) {
			edge := [2]u32{corners[corner_index], corners[(corner_index + 1) % len(corners)]}
			directed_edge_counts[edge] += 1
		}
	}
	testing.expect_value(test, len(directed_edge_counts), 24) // 12 edges, both directions
	for edge, count in directed_edge_counts {
		testing.expect_value(test, count, 1)
		reverse_edge := [2]u32{edge[1], edge[0]}
		testing.expect(test, directed_edge_counts[reverse_edge] == 1, "every edge needs a reverse twin")
	}
}

@(test)
test_cube_volume :: proc(test: ^testing.T) {
	for size in ([]f32{1, 2, 0.5}) {
		cube := make_cube(size, context.temp_allocator)
		volume := mesh_volume(cube)
		testing.expectf(test, abs(volume - size * size * size) < EPSILON, "size %v: volume %v", size, volume)
	}
}

@(test)
test_cube_normals_point_outward :: proc(test: ^testing.T) {
	cube := make_cube(1, context.temp_allocator)
	for face_index in 0 ..< face_count(cube) {
		normal := face_normal(cube, face_index)
		testing.expectf(test, abs(linalg.length(normal) - 1) < EPSILON, "face %d normal is not unit length", face_index)
		testing.expectf(test, linalg.dot(normal, face_center(cube, face_index)) > 0, "face %d points inward", face_index)
	}
}

@(test)
test_flat_shaded_triangles :: proc(test: ^testing.T) {
	cube := make_cube(1, context.temp_allocator)
	positions, normals, indices := flat_shaded_triangles(cube, context.temp_allocator)
	testing.expect_value(test, len(positions), 24)
	testing.expect_value(test, len(normals), 24)
	testing.expect_value(test, len(indices), 36) // 6 quads * 2 triangles * 3

	// Each triangle must face the same way as its face normal.
	for triangle_index in 0 ..< len(indices) / 3 {
		first := positions[indices[triangle_index * 3 + 0]]
		second := positions[indices[triangle_index * 3 + 1]]
		third := positions[indices[triangle_index * 3 + 2]]
		winding_normal := linalg.normalize(linalg.cross(second - first, third - first))
		expected_normal := normals[indices[triangle_index * 3]]
		testing.expectf(test, linalg.dot(winding_normal, expected_normal) > 0.999, "triangle %d winding disagrees with its normal", triangle_index)
	}
}

@(test)
test_look_at :: proc(test: ^testing.T) {
	eye := [3]f32{3, 4, 5}
	target := [3]f32{0, 1, 0}
	view := look_at(eye, target, WORLD_UP)

	eye_in_view := view * [4]f32{eye.x, eye.y, eye.z, 1}
	testing.expect(test, linalg.length(eye_in_view.xyz) < EPSILON, "eye must map to the view-space origin")

	// The target sits straight ahead, on the -Z axis, at its true distance.
	target_in_view := view * [4]f32{target.x, target.y, target.z, 1}
	distance := linalg.length(target - eye)
	testing.expect(test, abs(target_in_view.x) < EPSILON && abs(target_in_view.y) < EPSILON, "target must be on the view axis")
	testing.expect(test, abs(target_in_view.z + distance) < EPSILON, "target must be in front of the camera (-Z)")
}

// Right-handed with Y up: a camera on +Z looking at the origin sees +X to its right.
@(test)
test_coordinate_system_is_right_handed :: proc(test: ^testing.T) {
	testing.expect(test, linalg.cross(WORLD_RIGHT, WORLD_UP) == -WORLD_FORWARD, "X cross Y must equal +Z (toward the viewer)")
	view := look_at({0, 0, 5}, {0, 0, 0}, WORLD_UP)
	right_in_view := view * [4]f32{1, 0, 0, 1}
	testing.expect(test, right_in_view.x > 0, "+X must appear on the right of a camera looking down -Z")
}

@(test)
test_dynamic_resolution :: proc(test: ^testing.T) {
	budget: f32 = 16.667 // 60 fps; the controller aims for 90% of it, 15 ms

	// Far over budget: drops, but by at most 15% in one adjustment.
	dropped := next_render_scale(1.0, 40, budget, 0.5, 2.0)
	testing.expectf(test, dropped < 1.0 && dropped >= 0.85 - EPSILON, "over budget should drop by at most 15%%, got %v", dropped)

	// Far under budget: rises, by at most 5% (plus snapping to the next 2.5% step).
	risen := next_render_scale(1.0, 2, budget, 0.5, 2.0)
	testing.expectf(test, risen > 1.0 && risen <= 1.05 + EPSILON, "under budget should rise by at most 5%%, got %v", risen)

	// Close to the 15 ms aim: no change, so the resolution doesn't pump.
	testing.expect_value(test, next_render_scale(1.0, 15.2, budget, 0.5, 2.0), 1.0)

	// Results snap to 2.5% steps.
	snapped := next_render_scale(1.0, 20, budget, 0.5, 2.0)
	steps := snapped / DYNAMIC_RESOLUTION_STEP
	testing.expectf(test, abs(steps - math.round(steps)) < 1e-3, "scale %v should be a multiple of the step", snapped)

	// Never outside the allowed range, in either direction.
	testing.expect_value(test, next_render_scale(0.5, 100, budget, 0.5, 2.0), 0.5)
	testing.expect_value(test, next_render_scale(2.0, 0.5, budget, 0.5, 2.0), 2.0)
	testing.expect_value(test, next_render_scale(1.0, 2, budget, 0.5, 1.0), 1.0)

	// Repeated adjustments converge near the budget: a GPU cost proportional to scale squared,
	// 30 ms at scale 1, settles where cost is about 15 ms (scale ~0.71).
	scale: f32 = 1
	for _ in 0 ..< 40 {
		simulated_milliseconds := 30 * scale * scale
		scale = next_render_scale(scale, simulated_milliseconds, budget, 0.5, 2.0)
	}
	settled_milliseconds := 30 * scale * scale
	testing.expectf(test, settled_milliseconds > 13 && settled_milliseconds < 16.7, "should settle near 15 ms, got %v ms at scale %v", settled_milliseconds, scale)

	// No measurement yet: keep the current scale.
	testing.expect_value(test, next_render_scale(1.25, 0, budget, 0.5, 2.0), 1.25)
}

@(test)
test_normal_matrix :: proc(test: ^testing.T) {
	transform_normal :: proc(transform: matrix[4, 4]f32, normal: [3]f32) -> [3]f32 {
		transformed := normal_matrix(transform) * [4]f32{normal.x, normal.y, normal.z, 0}
		return linalg.normalize0(transformed.xyz)
	}

	// Matches the inverse transpose for an ordinary transform (non-uniform scale and rotation).
	ordinary := linalg.matrix4_rotate_f32(0.7, linalg.normalize([3]f32{1, 2, 3})) * linalg.matrix4_scale_f32({2, 0.5, 3})
	from_inverse := linalg.transpose(linalg.inverse(ordinary)) * [4]f32{0.3, 0.8, -0.5, 0}
	expected := linalg.normalize(from_inverse.xyz)
	testing.expect(test, linalg.length(transform_normal(ordinary, {0.3, 0.8, -0.5}) - expected) < 1e-5, "should match the inverse transpose")

	// Mirrored (scale x = -1): the +X face ends up at -X, and its normal must point -X (outward).
	mirrored := linalg.matrix4_scale_f32({-1, 1, 1})
	testing.expect(test, linear_determinant(mirrored) < 0, "a negative scale mirrors")
	testing.expect(test, linalg.length(transform_normal(mirrored, {1, 0, 0}) - [3]f32{-1, 0, 0}) < EPSILON, "mirrored normal should point outward")

	// Zero scale: no inverse exists, but the normal matrix stays finite.
	flattened := linalg.matrix4_scale_f32({1, 0, 1})
	testing.expect_value(test, linear_determinant(flattened), 0)
	flattened_normal := normal_matrix(flattened)
	for row in 0 ..< 4 {
		for column in 0 ..< 4 {
			testing.expect(test, !math.is_nan(flattened_normal[row, column]) && !math.is_inf(flattened_normal[row, column]), "normal matrix must be finite at zero scale")
		}
	}
	// The top face survives flattening and still points up.
	testing.expect(test, linalg.length(transform_normal(flattened, {0, 1, 0}) - [3]f32{0, 1, 0}) < EPSILON, "top face normal should stay up")
}

@(test)
test_distance_to_fit_sphere :: proc(test: ^testing.T) {
	vertical_fov := math.to_radians(f32(50))
	// A wide viewport is limited by the vertical angle.
	wide := distance_to_fit_sphere(5, vertical_fov, 2)
	testing.expect(test, abs(wide - 5 / math.sin(vertical_fov * 0.5)) < 1e-4, "wide viewport: vertical field of view limits")

	// A tall, narrow viewport (440 x 860) is limited horizontally, so it needs more distance.
	narrow := distance_to_fit_sphere(5, vertical_fov, 440.0 / 860.0)
	testing.expect(test, narrow > wide, "narrow viewport must back off further")

	// At that distance the sphere's sides really are inside the horizontal view: the angle from the
	// view axis to the sphere's edge is at most half the horizontal field of view.
	horizontal_fov := 2 * math.atan(math.tan(vertical_fov * 0.5) * (440.0 / 860.0))
	edge_angle := math.asin(5 / narrow)
	testing.expect(test, edge_angle <= horizontal_fov * 0.5 + 1e-5, "sphere must fit horizontally")
}

@(test)
test_euler_round_trip :: proc(test: ^testing.T) {
	matrices_match :: proc(a, b: matrix[4, 4]f32) -> bool {
		for row in 0 ..< 3 {
			for column in 0 ..< 3 {
				if abs(a[row, column] - b[row, column]) > 1e-4 {
					return false
				}
			}
		}
		return true
	}

	// Angles -> matrix -> angles -> matrix gives the same rotation (the angles themselves can
	// differ, since several Euler triples describe one rotation).
	for angles in ([][3]f32{{10, 20, 30}, {-45, 170, -100}, {89, -30, 60}, {0, 0, 0}, {120, 45, 10}}) {
		original := euler_rotation_matrix(angles)
		recovered := euler_rotation_matrix(euler_degrees_from_matrix(original))
		testing.expectf(test, matrices_match(original, recovered), "round trip of %v gave a different rotation", angles)
	}

	// Gimbal lock (x = 90°): still the same rotation.
	locked := euler_rotation_matrix({90, 30, 20})
	testing.expect(test, matrices_match(locked, euler_rotation_matrix(euler_degrees_from_matrix(locked))), "gimbal-locked round trip")

	// Unity's order: rotating 90° about Y turns +Z (forward in Unity terms) toward +X.
	turned := euler_rotation_matrix({0, 90, 0}) * [4]f32{0, 0, 1, 0}
	testing.expect(test, linalg.length(turned.xyz - [3]f32{1, 0, 0}) < 1e-5, "90° about Y maps +Z to +X")
}

@(test)
test_euler_near_hint :: proc(test: ^testing.T) {
	// Turning steadily about X from 0° to 170°, feeding each result back as the next hint: the X
	// angle climbs smoothly instead of jumping to (53, 180, 180)-style equivalents.
	angles: [3]f32
	for step in 1 ..= 17 {
		target := f32(step * 10)
		rotation := linalg.matrix4_rotate_f32(target * math.PI / 180, WORLD_RIGHT)
		angles = euler_degrees_from_matrix_near(rotation, angles)
		testing.expectf(test, abs(angles.x - target) < 1e-2 && abs(angles.y) < 1e-2 && abs(angles.z) < 1e-2, "step %d: expected (%v, 0, 0), got %v", step, target, angles)
	}

	// Past a full turn: stays continuous (370°, not 10°) when the hint is near there.
	rotation := linalg.matrix4_rotate_f32(10 * math.PI / 180, WORLD_UP)
	near_full_turn := euler_degrees_from_matrix_near(rotation, {0, 365, 0})
	testing.expectf(test, abs(near_full_turn.y - 370) < 1e-2, "expected 370° about Y, got %v", near_full_turn)

	// Whatever is chosen, it's the same rotation.
	for hint in ([][3]f32{{0, 0, 0}, {170, 10, -20}, {-400, 720, 90}}) {
		original := euler_rotation_matrix({35, -120, 75})
		chosen := euler_rotation_matrix(euler_degrees_from_matrix_near(original, hint))
		for row in 0 ..< 3 {
			for column in 0 ..< 3 {
				testing.expectf(test, abs(original[row, column] - chosen[row, column]) < 1e-4, "hint %v changed the rotation", hint)
			}
		}
	}
}

@(test)
test_closest_line_parameter_to_ray :: proc(test: ^testing.T) {
	// The X axis, and a ray straight down through x = 3.
	t, ok := closest_line_parameter_to_ray({0, 0, 0}, {1, 0, 0}, {origin = {3, 5, 0}, direction = {0, -1, 0}})
	testing.expect(test, ok && abs(t - 3) < 1e-5, "ray crossing the axis at x = 3")

	// A skew ray passing above the axis at x = -2, z offset: still t = -2.
	t, ok = closest_line_parameter_to_ray({0, 0, 0}, {1, 0, 0}, {origin = {-2, 4, 7}, direction = {0, 0, -1}})
	testing.expect(test, ok && abs(t + 2) < 1e-5, "skew ray closest at x = -2")

	// A scaled line direction gives t in units of that direction.
	t, ok = closest_line_parameter_to_ray({1, 0, 0}, {2, 0, 0}, {origin = {5, 5, 0}, direction = {0, -1, 0}})
	testing.expect(test, ok && abs(t - 2) < 1e-5, "t is measured in line-direction units")

	// A ray along the axis itself: no unique answer.
	_, ok = closest_line_parameter_to_ray({0, 0, 0}, {1, 0, 0}, {origin = {-5, 0, 0}, direction = {1, 0, 0}})
	testing.expect(test, !ok, "parallel ray has no closest parameter")
}

@(test)
test_perspective_reverse_z :: proc(test: ^testing.T) {
	near: f32 = 0.1
	projection := perspective_reverse_z(math.to_radians(f32(60)), 16.0 / 9.0, near)

	depth_at :: proc(projection: matrix[4, 4]f32, view_z: f32) -> f32 {
		clip := projection * [4]f32{0, 0, view_z, 1}
		return clip.z / clip.w
	}
	testing.expect(test, abs(depth_at(projection, -near) - 1) < EPSILON, "near plane must map to depth 1")
	testing.expect(test, depth_at(projection, -1000) < 0.001, "far points must approach depth 0")
	testing.expect(test, depth_at(projection, -1) > depth_at(projection, -2), "depth must shrink with distance")
}
