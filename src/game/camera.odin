// Editor viewport camera with Unity's scene-view controls:
//
//   Alt + left drag        orbit around the pivot
//   middle drag            pan
//   Alt + right drag       zoom (dolly toward the pivot)
//   wheel                  zoom
//   right drag             look around (flythrough); while held, WASD moves, Q/E go down/up,
//                          Shift moves faster
//   F                      frame: move the pivot to the selection (the origin until there is
//                          a selection)
//
// The camera is stored as a pivot point plus angles and a distance. The eye is derived from
// those, so orbiting, zooming and flying are each a small change to one or two numbers.
package game

import "core:math"
import "core:math/linalg"
import "engine:core"
import "engine:platform"

Viewport_Camera :: struct {
	pivot:        [3]f32,
	yaw:          f32, // radians around +Y; 0 = eye on the +Z side, looking toward -Z
	pitch:        f32, // radians above the horizontal plane
	distance:     f32, // from pivot to eye
	vertical_fov: f32, // radians
}

viewport_camera_eye :: proc(camera: Viewport_Camera) -> [3]f32 {
	return camera.pivot + camera.distance * viewport_camera_eye_direction(camera)
}

// Unit vector from the pivot toward the eye.
viewport_camera_eye_direction :: proc(camera: Viewport_Camera) -> [3]f32 {
	cos_pitch := math.cos(camera.pitch)
	return {cos_pitch * math.sin(camera.yaw), math.sin(camera.pitch), cos_pitch * math.cos(camera.yaw)}
}

update_viewport_camera :: proc(camera: ^Viewport_Camera, input: ^platform.Input) {
	RADIANS_PER_PIXEL :: 0.005
	ZOOM_PER_WHEEL_STEP :: 0.88
	DOLLY_PER_PIXEL :: 0.01
	FLY_SPEED_UNITS_PER_SECOND :: 3.0
	FLY_FAST_MULTIPLIER :: 4.0
	MAX_PITCH :: math.PI / 2 - 0.01 // stay off the poles, where look_at's up vector degenerates

	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down
	shift_held := input.keys[.Left_Shift].down || input.keys[.Right_Shift].down
	mouse_delta := input.mouse_delta

	orbiting := alt_held && input.mouse[.Left].down
	dollying := alt_held && input.mouse[.Right].down
	flying := !alt_held && input.mouse[.Right].down
	panning := input.mouse[.Middle].down

	if orbiting {
		camera.yaw -= mouse_delta.x * RADIANS_PER_PIXEL
		camera.pitch = clamp(camera.pitch + mouse_delta.y * RADIANS_PER_PIXEL, -MAX_PITCH, MAX_PITCH)
	}

	if flying {
		// Turn the view around the eye instead of the pivot: keep the eye where it is and move
		// the pivot so it stays `distance` in front of the new view direction.
		eye := viewport_camera_eye(camera^)
		camera.yaw -= mouse_delta.x * RADIANS_PER_PIXEL
		camera.pitch = clamp(camera.pitch + mouse_delta.y * RADIANS_PER_PIXEL, -MAX_PITCH, MAX_PITCH)
		camera.pivot = eye - camera.distance * viewport_camera_eye_direction(camera^)

		forward := -viewport_camera_eye_direction(camera^)
		right := linalg.normalize(linalg.cross(forward, core.WORLD_UP))
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
		// Move the pivot in the screen plane. Scaling by distance and field of view makes the
		// point under the cursor follow the mouse at any zoom level.
		forward := -viewport_camera_eye_direction(camera^)
		right := linalg.normalize(linalg.cross(forward, core.WORLD_UP))
		up := linalg.cross(right, forward)
		window_height := f32(max(input.window_size.y, 1))
		world_units_per_pixel := 2 * camera.distance * math.tan(camera.vertical_fov * 0.5) / window_height
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

	if input.keys[.F].pressed && !flying {
		camera.pivot = {0, 0.5, 0} // until there is a selection to frame
	}
}
