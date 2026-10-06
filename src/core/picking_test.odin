// Tests for rays and picking. Run with `build.bat test`.
package core

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_ray_from_viewport :: proc(test: ^testing.T) {
	eye := [3]f32{0, 0, 10}
	target := [3]f32{0, 0, 0}
	vertical_fov := math.to_radians(f32(90))

	// The centre of the viewport looks straight at the target.
	center := ray_from_viewport(eye, target, WORLD_UP, vertical_fov, 2, {0, 0})
	testing.expect(test, linalg.length(center.direction - [3]f32{0, 0, -1}) < EPSILON, "centre ray should point down -Z")

	// The top edge is half the field of view up (45° here), the right edge accounts for aspect.
	top := ray_from_viewport(eye, target, WORLD_UP, vertical_fov, 2, {0, 1})
	testing.expect(test, abs(top.direction.y - top.direction.z * -1) < EPSILON, "top-edge ray should be 45° up")
	right := ray_from_viewport(eye, target, WORLD_UP, vertical_fov, 2, {1, 0})
	testing.expect(test, right.direction.x > 0 && abs(right.direction.x / -right.direction.z - 2) < 1e-4, "right-edge ray: tan = aspect * tan(fov/2)")

	// Pixel to normalized: top-left is (-1, 1), bottom-right is (1, -1).
	testing.expect(test, viewport_normalized_position({100, 50}, {100, 50}, {300, 250}) == {-1, 1}, "top-left pixel")
	testing.expect(test, viewport_normalized_position({300, 250}, {100, 50}, {300, 250}) == {1, -1}, "bottom-right pixel")
}

@(test)
test_ray_box_intersection :: proc(test: ^testing.T) {
	box_min, box_max := [3]f32{-1, -1, -1}, [3]f32{1, 1, 1}
	t, hit := ray_box_intersection({origin = {0, 0, 5}, direction = {0, 0, -1}}, box_min, box_max)
	testing.expect(test, hit && abs(t - 4) < EPSILON, "ray toward the box should enter at t = 4")
	_, hit = ray_box_intersection({origin = {3, 0, 5}, direction = {0, 0, -1}}, box_min, box_max)
	testing.expect(test, !hit, "ray beside the box should miss")
	_, hit = ray_box_intersection({origin = {0, 0, 5}, direction = {0, 0, 1}}, box_min, box_max)
	testing.expect(test, !hit, "ray pointing away should miss")
	t, hit = ray_box_intersection({origin = {0, 0, 0}, direction = {1, 0, 0}}, box_min, box_max)
	testing.expect(test, hit && t == 0, "ray starting inside should hit at t = 0")
}

@(test)
test_ray_triangle_intersection :: proc(test: ^testing.T) {
	corner_a, corner_b, corner_c := [3]f32{0, 0, 0}, [3]f32{1, 0, 0}, [3]f32{0, 1, 0}
	t, hit := ray_triangle_intersection({origin = {0.25, 0.25, 3}, direction = {0, 0, -1}}, corner_a, corner_b, corner_c)
	testing.expect(test, hit && abs(t - 3) < EPSILON, "ray through the triangle should hit at t = 3")
	_, hit = ray_triangle_intersection({origin = {0.25, 0.25, -3}, direction = {0, 0, 1}}, corner_a, corner_b, corner_c)
	testing.expect(test, hit, "the test is two-sided: hits from behind too")
	_, hit = ray_triangle_intersection({origin = {0.75, 0.75, 3}, direction = {0, 0, -1}}, corner_a, corner_b, corner_c)
	testing.expect(test, !hit, "ray outside the hypotenuse should miss")
	_, hit = ray_triangle_intersection({origin = {0.25, 0.25, 3}, direction = {1, 0, 0}}, corner_a, corner_b, corner_c)
	testing.expect(test, !hit, "ray parallel to the triangle should miss")
}

@(test)
test_ray_mesh_intersection_through_a_transform :: proc(test: ^testing.T) {
	cube := make_cube(1, context.temp_allocator)
	// A cube scaled 2x along X and moved to x = 10. Picking transforms the world ray into the
	// cube's local space; t must come back in world units of the original ray.
	world := linalg.matrix4_translate_f32({10, 0, 0}) * linalg.matrix4_scale_f32({2, 1, 1})
	world_ray := Ray{origin = {0, 0, 0}, direction = {1, 0, 0}}
	local_ray := ray_transformed(world_ray, linalg.inverse(world))
	t, hit := ray_mesh_intersection(local_ray, cube)
	testing.expect(test, hit, "the ray along +X should hit the cube")
	// The scaled cube's near face is at x = 10 - 1 = 9.
	testing.expectf(test, abs(t - 9) < 1e-4, "hit should be 9 units away in world space, got %v", t)
	hit_point := ray_point(world_ray, t)
	testing.expect(test, abs(hit_point.x - 9) < 1e-4, "world hit point should be on the near face")

	_, hit = ray_mesh_intersection(ray_transformed({origin = {0, 5, 0}, direction = {1, 0, 0}}, linalg.inverse(world)), cube)
	testing.expect(test, !hit, "a ray above the cube should miss")
}
