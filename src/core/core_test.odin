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
