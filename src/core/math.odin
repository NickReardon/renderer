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
