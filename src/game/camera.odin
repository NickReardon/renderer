// Editor viewport camera with Unity's scene-view controls:
//
//   Alt + left drag        orbit around the pivot
//   middle drag            pan
//   Alt + right drag       zoom (dolly toward the pivot)
//   wheel                  zoom
//   right drag             look around (flythrough); while held, WASD moves, Q/E go down/up,
//                          Shift moves faster
//   F                      frame the selection (handled in editor.odin)
//   view gizmo             snap to an axis or corner view, switch perspective / orthographic
//                          (view_gizmo.odin)
//
// The camera is stored as a pivot point plus angles and a distance. The eye is derived from
// those, so orbiting, zooming and flying are each a small change to one or two numbers.
//
// Orthographic mode keeps the same numbers. Its view is as tall as the perspective view's at
// the pivot's depth (2 * distance * tan(fov / 2)), so switching modes keeps the pivot's
// surroundings the same size on screen, and zoom (which changes `distance`) works unchanged.
package game

import "core:math"
import "core:math/linalg"
import "engine:core"
import "engine:platform"

Viewport_Camera :: struct {
	pivot:        [3]f32,
	yaw:          f32, // radians around +Y; 0 = eye on the +Z side, looking toward -Z
	pitch:        f32, // radians above the horizontal plane; ±90° looks straight down / up
	distance:     f32, // from pivot to eye
	vertical_fov: f32, // radians (perspective; orthographic derives its size from it)
	orthographic: bool,
}

CAMERA_NEAR :: 0.05
// Orthographic depth range, in front of and behind the eye. The near plane is behind the eye
// so nothing between the eye and the pivot is clipped when zooming in.
ORTHOGRAPHIC_DEPTH :: 1000

viewport_camera_eye :: proc(camera: Viewport_Camera) -> [3]f32 {
	return camera.pivot + camera.distance * viewport_camera_eye_direction(camera)
}

// Unit vector from the pivot toward the eye.
viewport_camera_eye_direction :: proc(camera: Viewport_Camera) -> [3]f32 {
	cos_pitch := math.cos(camera.pitch)
	return {cos_pitch * math.sin(camera.yaw), math.sin(camera.pitch), cos_pitch * math.cos(camera.yaw)}
}

// The camera's axes in world space. Built from the angles rather than from WORLD_UP: crossing
// the view direction with WORLD_UP gives zero when looking straight down (the Top view), but
// the yaw still says which way "right" is there.
viewport_camera_basis :: proc(camera: Viewport_Camera) -> (forward, right, up: [3]f32) {
	forward = -viewport_camera_eye_direction(camera)
	right = {math.cos(camera.yaw), 0, -math.sin(camera.yaw)}
	up = linalg.cross(right, forward)
	return
}

// Half the view's height in world units at the pivot (the orthographic view's size).
viewport_camera_half_height :: proc(camera: Viewport_Camera) -> f32 {
	return camera.distance * math.tan(camera.vertical_fov * 0.5)
}

viewport_camera_view :: proc(camera: Viewport_Camera) -> matrix[4, 4]f32 {
	_, _, up := viewport_camera_basis(camera)
	return core.look_at(viewport_camera_eye(camera), camera.pivot, up)
}

viewport_camera_projection :: proc(camera: Viewport_Camera, aspect_ratio: f32) -> matrix[4, 4]f32 {
	safe_aspect_ratio := max(aspect_ratio, 0.01)
	if camera.orthographic {
		return core.orthographic_reverse_z(viewport_camera_half_height(camera), safe_aspect_ratio, -ORTHOGRAPHIC_DEPTH, ORTHOGRAPHIC_DEPTH)
	}
	return core.perspective_reverse_z(camera.vertical_fov, safe_aspect_ratio, CAMERA_NEAR)
}

// The ray through a point of the view; `normalized_position` is -1..1 with y up.
viewport_camera_ray :: proc(camera: Viewport_Camera, aspect_ratio: f32, normalized_position: [2]f32) -> core.Ray {
	_, _, up := viewport_camera_basis(camera)
	eye := viewport_camera_eye(camera)
	if camera.orthographic {
		// Start at the near plane, behind the eye, so everything drawn can be picked.
		start := eye + viewport_camera_eye_direction(camera) * ORTHOGRAPHIC_DEPTH
		return core.ray_from_viewport_orthographic(start, camera.pivot, up, viewport_camera_half_height(camera), aspect_ratio, normalized_position)
	}
	return core.ray_from_viewport(eye, camera.pivot, up, camera.vertical_fov, aspect_ratio, normalized_position)
}

// World size of one pixel at `point`, for drawing things at a constant size on screen.
// Perspective: grows with the point's depth. Orthographic: the same everywhere.
viewport_camera_world_per_pixel :: proc(camera: Viewport_Camera, point: [3]f32, viewport_height: f32) -> f32 {
	if camera.orthographic {
		return 2 * viewport_camera_half_height(camera) / max(viewport_height, 1)
	}
	eye := viewport_camera_eye(camera)
	depth := linalg.dot(point - eye, -viewport_camera_eye_direction(camera))
	return 2 * depth * math.tan(camera.vertical_fov * 0.5) / max(viewport_height, 1)
}

// Unit vector from `point` toward the viewer. In orthographic mode every point sees the camera
// along the same direction.
viewport_camera_toward_viewer :: proc(camera: Viewport_Camera, point: [3]f32) -> [3]f32 {
	if camera.orthographic {
		return viewport_camera_eye_direction(camera)
	}
	return linalg.normalize(viewport_camera_eye(camera) - point)
}

// Turns the camera around its pivot so the eye sits in `direction` from it (any length),
// looking back at the pivot. Straight up or down uses yaw 0, so in the Top view -Z (the
// scene's back) is at the top of the screen and +X on the right.
snap_viewport_camera :: proc(camera: ^Viewport_Camera, direction: [3]f32) {
	unit := linalg.normalize(direction)
	horizontal_length := linalg.length(unit.xz)
	camera.pitch = math.atan2(unit.y, horizontal_length)
	camera.yaw = math.atan2(unit.x, unit.z) if horizontal_length > 1e-6 else 0
}

// Turns the camera around its pivot by a mouse movement (Alt + left drag, or dragging the view
// gizmo): right turns the world right, down tilts it toward you. The poles are allowed
// (viewport_camera_basis doesn't degenerate there), but not beyond: past them the view would
// turn upside down.
orbit_viewport_camera :: proc(camera: ^Viewport_Camera, mouse_delta: [2]f32) {
	camera.yaw -= mouse_delta.x * ORBIT_RADIANS_PER_PIXEL
	camera.pitch = clamp(camera.pitch + mouse_delta.y * ORBIT_RADIANS_PER_PIXEL, -math.PI / 2, math.PI / 2)
}

ORBIT_RADIANS_PER_PIXEL :: 0.005

update_viewport_camera :: proc(camera: ^Viewport_Camera, input: ^platform.Input) {
	ZOOM_PER_WHEEL_STEP :: 0.88
	DOLLY_PER_PIXEL :: 0.01
	FLY_SPEED_UNITS_PER_SECOND :: 3.0
	FLY_FAST_MULTIPLIER :: 4.0

	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down
	shift_held := input.keys[.Left_Shift].down || input.keys[.Right_Shift].down
	mouse_delta := input.mouse_delta

	orbiting := alt_held && input.mouse[.Left].down
	dollying := alt_held && input.mouse[.Right].down
	flying := !alt_held && input.mouse[.Right].down
	panning := input.mouse[.Middle].down

	if orbiting {
		orbit_viewport_camera(camera, mouse_delta)
	}

	if flying {
		// Turn the view around the eye instead of the pivot: keep the eye where it is and move
		// the pivot so it stays `distance` in front of the new view direction.
		eye := viewport_camera_eye(camera^)
		orbit_viewport_camera(camera, mouse_delta) // the same turn, then moved to keep the eye
		camera.pivot = eye - camera.distance * viewport_camera_eye_direction(camera^)

		forward, right, _ := viewport_camera_basis(camera^)
		move_direction: [3]f32
		if input.keys[.W].down do move_direction += forward
		if input.keys[.S].down do move_direction -= forward
		if input.keys[.D].down do move_direction += right
		if input.keys[.A].down do move_direction -= right
		if input.keys[.E].down do move_direction += core.WORLD_UP
		if input.keys[.Q].down do move_direction -= core.WORLD_UP
		if move_direction != {} {
			speed: f32 = FLY_SPEED_UNITS_PER_SECOND * (FLY_FAST_MULTIPLIER if shift_held else 1)
			camera.pivot += linalg.normalize(move_direction) * speed * input.delta_seconds
		}
	}

	if panning {
		// Move the pivot in the screen plane. Scaling by the world size of a pixel at the pivot
		// makes the point under the cursor follow the mouse at any zoom level, in either
		// projection.
		_, right, up := viewport_camera_basis(camera^)
		world_units_per_pixel := viewport_camera_world_per_pixel(camera^, camera.pivot, f32(input.window_size.y))
		camera.pivot += (-mouse_delta.x * right + mouse_delta.y * up) * world_units_per_pixel
	}

	if dollying {
		// Dragging right or up moves toward the pivot.
		camera.distance *= math.exp(-(mouse_delta.x - mouse_delta.y) * DOLLY_PER_PIXEL)
	}
	if input.wheel != 0 && !flying {
		camera.distance *= math.pow(ZOOM_PER_WHEEL_STEP, input.wheel)
	}
	camera.distance = clamp(camera.distance, 0.1, 1000)
}
