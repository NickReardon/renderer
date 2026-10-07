// Camera math.
//
// Conventions used everywhere in the engine:
//   - right-handed coordinates: X horizontal (right), Y vertical (up), Z depth. +Z points
//     toward the viewer, so a camera's forward direction is -Z (as in Maya, Godot, OpenGL);
//   - column vectors: a point transforms as `matrix * point`, so `a * b` applies b first;
//   - clip-space depth is in [0, 1] (WebGPU, D3D, Metal), with *reverse-Z*: the near plane
//     maps to depth 1 and infinity to depth 0. Floats have far more precision near 0, and
//     reversing puts that precision where the perspective divide needs it, far from the
//     camera. See Nathan Reed, "Depth Precision Visualized" (docs/REFERENCES.md).
package core

import "core:math"
import "core:math/linalg"

WORLD_RIGHT   :: [3]f32{1, 0, 0}
WORLD_UP      :: [3]f32{0, 1, 0}
WORLD_FORWARD :: [3]f32{0, 0, -1}

// World-to-view matrix for a camera at `eye` looking at `target`.
look_at :: proc(eye, target, up: [3]f32) -> matrix[4, 4]f32 {
	forward := linalg.normalize(target - eye)
	right := linalg.normalize(linalg.cross(forward, up))
	camera_up := linalg.cross(right, forward)

	// Rows are the camera's axes expressed in world space; the last column moves the eye to
	// the origin. Forward is negated because the camera looks down -Z.
	return matrix[4, 4]f32{
		right.x,      right.y,      right.z,      -linalg.dot(right, eye),
		camera_up.x,  camera_up.y,  camera_up.z,  -linalg.dot(camera_up, eye),
		-forward.x,   -forward.y,   -forward.z,   linalg.dot(forward, eye),
		0,            0,            0,            1,
	}
}

// Determinant of a transform's 3x3 linear part (rotation and scale). Negative means the
// transform mirrors (an odd number of negative scales), which reverses triangle winding.
// Zero means it flattens space (a zero scale) and has no inverse.
linear_determinant :: proc(transform: matrix[4, 4]f32) -> f32 {
	row_0 := [3]f32{transform[0, 0], transform[0, 1], transform[0, 2]}
	row_1 := [3]f32{transform[1, 0], transform[1, 1], transform[1, 2]}
	row_2 := [3]f32{transform[2, 0], transform[2, 1], transform[2, 2]}
	return linalg.dot(row_0, linalg.cross(row_1, row_2))
}

// The matrix that transforms normals for `transform`: the inverse transpose of its linear
// part, up to a positive scale (normals are renormalized after transforming anyway).
//
// It's computed from cofactors (cross products of the rows) instead of an inverse, so it never
// divides: a zero scale gives finite results (faces that collapse simply get zero-length
// normals), where an inverse would produce infinities. Multiplying by the determinant's sign
// keeps normals pointing outward for mirrored transforms.
normal_matrix :: proc(transform: matrix[4, 4]f32) -> matrix[4, 4]f32 {
	row_0 := [3]f32{transform[0, 0], transform[0, 1], transform[0, 2]}
	row_1 := [3]f32{transform[1, 0], transform[1, 1], transform[1, 2]}
	row_2 := [3]f32{transform[2, 0], transform[2, 1], transform[2, 2]}
	cofactor_0 := linalg.cross(row_1, row_2)
	cofactor_1 := linalg.cross(row_2, row_0)
	cofactor_2 := linalg.cross(row_0, row_1)
	sign: f32 = -1 if linalg.dot(row_0, cofactor_0) < 0 else 1
	return matrix[4, 4]f32{
		cofactor_0.x * sign, cofactor_0.y * sign, cofactor_0.z * sign, 0,
		cofactor_1.x * sign, cofactor_1.y * sign, cofactor_1.z * sign, 0,
		cofactor_2.x * sign, cofactor_2.y * sign, cofactor_2.z * sign, 0,
		0,                   0,                   0,                   1,
	}
}

// How far a perspective camera must be from a sphere's centre for the whole sphere to fit in
// view. The limiting angle is the narrower of the vertical field of view and the horizontal
// one (which depends on the aspect ratio): a tall, narrow viewport is limited horizontally.
distance_to_fit_sphere :: proc(radius, vertical_fov, aspect_ratio: f32) -> f32 {
	horizontal_fov := 2 * math.atan(math.tan(vertical_fov * 0.5) * aspect_ratio)
	narrowest_fov := min(vertical_fov, horizontal_fov)
	return radius / math.sin(narrowest_fov * 0.5)
}

// Rotation from Euler angles in degrees, applied Z first, then X, then Y (Unity's order):
// R = Ry * Rx * Rz.
euler_rotation_matrix :: proc(rotation_degrees: [3]f32) -> matrix[4, 4]f32 {
	radians := rotation_degrees * (math.PI / 180)
	return(
		linalg.matrix4_rotate_f32(radians.y, WORLD_UP) *
		linalg.matrix4_rotate_f32(radians.x, WORLD_RIGHT) *
		linalg.matrix4_rotate_f32(radians.z, [3]f32{0, 0, 1}) \
	)
}

// Euler angles in degrees (Z, X, Y order, as above) of a pure rotation matrix.
//
// Multiplying out Ry * Rx * Rz gives, among other entries,
//   [1][2] = -sin x
//   [0][2] =  sin y cos x,   [2][2] = cos y cos x
//   [1][0] =  cos x sin z,   [1][1] = cos x cos z
// so x comes from [1][2], and y and z from atan2 of their pairs. When cos x is ~0 (x = ±90°,
// gimbal lock) y and z turn about the same axis and only their sum matters: z is set to 0 and
// y taken from the remaining entries.
euler_degrees_from_matrix :: proc(rotation: matrix[4, 4]f32) -> [3]f32 {
	sin_x := clamp(-rotation[1, 2], -1, 1)
	x := math.asin(sin_x)
	y, z: f32
	if abs(sin_x) < 0.99999 {
		y = math.atan2(rotation[0, 2], rotation[2, 2])
		z = math.atan2(rotation[1, 0], rotation[1, 1])
	} else {
		y = math.atan2(-rotation[2, 0], rotation[0, 0])
		z = 0
	}
	return [3]f32{x, y, z} * (180 / math.PI)
}

// Like euler_degrees_from_matrix, but chooses, among the angle triples that describe the same
// rotation, the one closest to `hint` (usually the previous angles). Every rotation has two
// basic solutions, (x, y, z) and (180 - x, y + 180, z + 180), and each angle can also shift by
// whole turns. Without this, turning an object steadily about X past 90° would make the shown
// angles jump (e.g. to 53, 180, 180). Unity keeps a similar hint for the same reason.
euler_degrees_from_matrix_near :: proc(rotation: matrix[4, 4]f32, hint: [3]f32) -> [3]f32 {
	wrap_near :: proc(angles, hint: [3]f32) -> (wrapped: [3]f32) {
		for axis in 0 ..< 3 {
			wrapped[axis] = angles[axis] + 360 * math.round((hint[axis] - angles[axis]) / 360)
		}
		return
	}
	primary := euler_degrees_from_matrix(rotation)
	alternative := [3]f32{180 - primary.x, primary.y + 180, primary.z + 180}
	primary = wrap_near(primary, hint)
	alternative = wrap_near(alternative, hint)
	if linalg.length(alternative - hint) < linalg.length(primary - hint) {
		return alternative
	}
	return primary
}

// Where on the line `line_origin + t * line_direction` the ray passes closest. This is how a
// gizmo turns a mouse ray into a position along an axis. `ok` is false when the ray runs
// parallel to the line, where every point is equally close.
closest_line_parameter_to_ray :: proc(line_origin, line_direction: [3]f32, ray: Ray) -> (t: f32, ok: bool) {
	// Minimise |(line_origin + t*d) - (ray.origin + s*r)| over t and s (two linear equations).
	direction := line_direction
	ray_direction := ray.direction
	offset := line_origin - ray.origin
	direction_dot_direction := linalg.dot(direction, direction)
	direction_dot_ray := linalg.dot(direction, ray_direction)
	ray_dot_ray := linalg.dot(ray_direction, ray_direction)
	direction_dot_offset := linalg.dot(direction, offset)
	ray_dot_offset := linalg.dot(ray_direction, offset)
	denominator := direction_dot_direction * ray_dot_ray - direction_dot_ray * direction_dot_ray
	if abs(denominator) < 1e-9 * direction_dot_direction * ray_dot_ray {
		return 0, false
	}
	t = (direction_dot_ray * ray_dot_offset - ray_dot_ray * direction_dot_offset) / denominator
	return t, true
}

// Perspective projection with reverse-Z and no far plane.
// `vertical_fov` is the full vertical field of view in radians.
//
// For a view-space point (x, y, z, 1) with z < 0 this gives
//   clip.z = near, clip.w = -z   =>   depth = near / -z
// so depth is 1 at the near plane and falls toward 0 as the point moves away.
perspective_reverse_z :: proc(vertical_fov, aspect_ratio, near: f32) -> matrix[4, 4]f32 {
	assert(vertical_fov > 0 && aspect_ratio > 0 && near > 0)
	focal_scale := 1 / math.tan(vertical_fov * 0.5)
	return matrix[4, 4]f32{
		focal_scale / aspect_ratio, 0,           0,  0,
		0,                          focal_scale, 0,  0,
		0,                          0,           0,  near,
		0,                          0,           -1, 0,
	}
}

// Orthographic projection with reverse-Z: `half_height` world units above and below the view's
// centre fill the viewport, at every distance. `near` and `far` are distances in front of the
// eye; near may be negative (behind the eye), which the editor uses so that zooming in never
// clips objects between the eye and the pivot.
//
// For a view-space point (x, y, z, 1) this gives w = 1 (no perspective divide) and
//   depth = (z + far) / (far - near)
// which is 1 at z = -near and 0 at z = -far, falling linearly in between. Depth precision is
// spread evenly, so reverse-Z buys nothing here; it's kept so the depth test (.Greater, clear
// to 0) is the same for both projections.
orthographic_reverse_z :: proc(half_height, aspect_ratio, near, far: f32) -> matrix[4, 4]f32 {
	assert(half_height > 0 && aspect_ratio > 0 && far > near)
	depth_range := far - near
	return matrix[4, 4]f32{
		1 / (half_height * aspect_ratio), 0,               0,               0,
		0,                                1 / half_height, 0,               0,
		0,                                0,               1 / depth_range, far / depth_range,
		0,                                0,               0,               1,
	}
}
