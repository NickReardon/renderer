// Rays for picking: from a viewport pixel into the scene, and against boxes, triangles and
// meshes. (Möller & Trumbore 1997 for triangles; the slab test for boxes; see
// docs/REFERENCES.md, Ericson's Real-Time Collision Detection.)
//
// Rays don't need a unit-length direction. That lets a caller transform a world ray into an
// object's local space with the inverse world matrix and get the *same* t values back: the hit
// point is origin + t * direction in either space, so hits on differently scaled objects can be
// compared directly.
package core

import "core:math"
import "core:math/linalg"

Ray :: struct {
	origin:    [3]f32,
	direction: [3]f32,
}

// The ray through a point of the viewport, for a perspective camera at `eye` looking at
// `target`. `normalized_position` is (-1, -1) at the bottom-left corner and (1, 1) at the
// top-right.
ray_from_viewport :: proc(eye, target, up: [3]f32, vertical_fov, aspect_ratio: f32, normalized_position: [2]f32) -> Ray {
	forward := linalg.normalize(target - eye)
	right := linalg.normalize(linalg.cross(forward, up))
	camera_up := linalg.cross(right, forward)
	half_height := math.tan(vertical_fov * 0.5)
	half_width := half_height * aspect_ratio
	direction := forward + right * (normalized_position.x * half_width) + camera_up * (normalized_position.y * half_height)
	return {origin = eye, direction = linalg.normalize(direction)}
}

// Converts a pixel inside a viewport rectangle (origin top-left, y down) to the -1..1 range
// used by ray_from_viewport (y up).
viewport_normalized_position :: proc(pixel, viewport_min, viewport_max: [2]f32) -> [2]f32 {
	relative := (pixel - viewport_min) / (viewport_max - viewport_min)
	return {relative.x * 2 - 1, 1 - relative.y * 2}
}

ray_transformed :: proc(ray: Ray, transform: matrix[4, 4]f32) -> Ray {
	origin := transform * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
	direction := transform * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}
	return {origin = origin.xyz, direction = direction.xyz}
}

ray_point :: proc(ray: Ray, t: f32) -> [3]f32 {
	return ray.origin + ray.direction * t
}

// Slab test: the ray's entry distance into an axis-aligned box. A ray starting inside the box
// hits at t = 0.
ray_box_intersection :: proc(ray: Ray, box_min, box_max: [3]f32) -> (t: f32, hit: bool) {
	t_enter: f32 = 0
	t_exit := max(f32)
	for axis in 0 ..< 3 {
		if abs(ray.direction[axis]) < 1e-12 {
			// Parallel to this pair of planes: inside the slab or never.
			if ray.origin[axis] < box_min[axis] || ray.origin[axis] > box_max[axis] {
				return 0, false
			}
			continue
		}
		inverse_direction := 1 / ray.direction[axis]
		t_near := (box_min[axis] - ray.origin[axis]) * inverse_direction
		t_far := (box_max[axis] - ray.origin[axis]) * inverse_direction
		if t_near > t_far {
			t_near, t_far = t_far, t_near
		}
		t_enter = max(t_enter, t_near)
		t_exit = min(t_exit, t_far)
		if t_enter > t_exit {
			return 0, false
		}
	}
	return t_enter, true
}

// Möller–Trumbore ray/triangle test, two-sided. Returns the distance along the ray (t > 0).
ray_triangle_intersection :: proc(ray: Ray, corner_a, corner_b, corner_c: [3]f32) -> (t: f32, hit: bool) {
	EPSILON_DETERMINANT :: 1e-12
	edge_ab := corner_b - corner_a
	edge_ac := corner_c - corner_a
	perpendicular := linalg.cross(ray.direction, edge_ac)
	determinant := linalg.dot(edge_ab, perpendicular)
	if abs(determinant) < EPSILON_DETERMINANT {
		return 0, false // the ray is parallel to the triangle
	}
	inverse_determinant := 1 / determinant
	from_a := ray.origin - corner_a
	barycentric_u := linalg.dot(from_a, perpendicular) * inverse_determinant
	if barycentric_u < 0 || barycentric_u > 1 {
		return 0, false
	}
	cross_ab := linalg.cross(from_a, edge_ab)
	barycentric_v := linalg.dot(ray.direction, cross_ab) * inverse_determinant
	if barycentric_v < 0 || barycentric_u + barycentric_v > 1 {
		return 0, false
	}
	t = linalg.dot(edge_ac, cross_ab) * inverse_determinant
	return t, t > 0
}

// Nearest hit between the ray and any face of the mesh (faces as triangle fans).
ray_mesh_intersection :: proc(ray: Ray, mesh: Mesh) -> (nearest_t: f32, hit: bool) {
	nearest_t = max(f32)
	for face_index in 0 ..< face_count(mesh) {
		corners := face_corners(mesh, face_index)
		first := mesh.positions[corners[0]]
		for corner_index in 1 ..< len(corners) - 1 {
			t, triangle_hit := ray_triangle_intersection(ray, first, mesh.positions[corners[corner_index]], mesh.positions[corners[corner_index + 1]])
			if triangle_hit && t < nearest_t {
				nearest_t = t
				hit = true
			}
		}
	}
	return
}

mesh_bounds :: proc(mesh: Mesh) -> (bounds_min, bounds_max: [3]f32) {
	if len(mesh.positions) == 0 {
		return
	}
	bounds_min, bounds_max = mesh.positions[0], mesh.positions[0]
	for position in mesh.positions[1:] {
		bounds_min = linalg.min(bounds_min, position)
		bounds_max = linalg.max(bounds_max, position)
	}
	return
}
