// Tests for the primitive meshes. Run with `build.bat test`.
package core

import "core:math"
import "core:math/linalg"
import "core:testing"

// Closed and consistently oriented: every directed edge a->b appears exactly once, and so does
// its reverse b->a (the face on the other side walks the shared edge the other way).
expect_closed_and_oriented :: proc(test: ^testing.T, mesh: Mesh, name: string) {
	directed_edge_counts := make(map[[2]u32]int, allocator = context.temp_allocator)
	for face_index in 0 ..< face_count(mesh) {
		corners := face_corners(mesh, face_index)
		for corner_index in 0 ..< len(corners) {
			edge := [2]u32{corners[corner_index], corners[(corner_index + 1) % len(corners)]}
			directed_edge_counts[edge] += 1
		}
	}
	for edge, count in directed_edge_counts {
		if count != 1 {
			testing.expectf(test, false, "%s: directed edge %v used %d times", name, edge, count)
			return
		}
		if directed_edge_counts[{edge[1], edge[0]}] != 1 {
			testing.expectf(test, false, "%s: edge %v has no reverse twin (hole or flipped face)", name, edge)
			return
		}
	}
}

// Every face normal points away from the centre (true for convex shapes around the origin).
expect_normals_outward :: proc(test: ^testing.T, mesh: Mesh, name: string) {
	for face_index in 0 ..< face_count(mesh) {
		if linalg.dot(face_normal(mesh, face_index), face_center(mesh, face_index)) <= 0 {
			testing.expectf(test, false, "%s: face %d points inward", name, face_index)
			return
		}
	}
}

@(test)
test_plane :: proc(test: ^testing.T) {
	plane := make_plane(4, 3, context.temp_allocator)
	testing.expect_value(test, len(plane.positions), 16)
	testing.expect_value(test, face_count(plane), 9)
	for face_index in 0 ..< face_count(plane) {
		normal := face_normal(plane, face_index)
		testing.expectf(test, linalg.dot(normal, WORLD_UP) > 0.999, "plane face %d should face up, got %v", face_index, normal)
	}
	bounds_min, bounds_max := mesh_bounds(plane)
	testing.expect(test, bounds_min == {-2, 0, -2} && bounds_max == {2, 0, 2}, "plane should span -2..2 on X and Z")
}

@(test)
test_uv_sphere :: proc(test: ^testing.T) {
	segments, rings := 32, 16
	sphere := make_uv_sphere(1, segments, rings, context.temp_allocator)
	testing.expect_value(test, len(sphere.positions), (rings - 1) * segments + 2)
	testing.expect_value(test, face_count(sphere), rings * segments)
	expect_closed_and_oriented(test, sphere, "sphere")
	expect_normals_outward(test, sphere, "sphere")
	for position in sphere.positions {
		testing.expectf(test, abs(linalg.length(position) - 1) < EPSILON, "sphere vertex %v not on the unit sphere", position)
	}
	// A tessellated sphere is slightly smaller than the true one: within 2% at this resolution.
	exact_volume := f32(4.0 / 3.0 * math.PI)
	volume := mesh_volume(sphere)
	testing.expectf(test, volume < exact_volume && volume > exact_volume * 0.98, "sphere volume %v vs exact %v", volume, exact_volume)
}

@(test)
test_cylinder :: proc(test: ^testing.T) {
	segments := 24
	radius: f32 = 0.5
	height: f32 = 2
	cylinder := make_cylinder(radius, height, segments, context.temp_allocator)
	testing.expect_value(test, len(cylinder.positions), segments * 2)
	testing.expect_value(test, face_count(cylinder), segments + 2)
	expect_closed_and_oriented(test, cylinder, "cylinder")
	expect_normals_outward(test, cylinder, "cylinder")
	// Exact volume of a prism over a regular polygon: area = n/2 * r^2 * sin(2π/n).
	polygon_area := f32(segments) * 0.5 * radius * radius * math.sin(2 * math.PI / f32(segments))
	volume := mesh_volume(cylinder)
	testing.expectf(test, abs(volume - polygon_area * height) < 1e-4, "cylinder volume %v, expected %v", volume, polygon_area * height)
}

@(test)
test_cube_with_shared_checks :: proc(test: ^testing.T) {
	cube := make_cube(1, context.temp_allocator)
	expect_closed_and_oriented(test, cube, "cube")
	expect_normals_outward(test, cube, "cube")
}
