// The transform gizmo, with Unity's tools and keys:
//   Q  Hand    left-drag pans the view (no gizmo)
//   W  Move    an arrow per axis: drag along it; a square per pair of axes: drag in that plane
//   E  Rotate  a ring per axis: drag around it; the outer ring turns around the view direction
//   R  Scale   a handle per local axis, and a centre handle for uniform scale
// Ctrl while dragging snaps (0.25 units, 15°, 0.1x steps). Escape during a drag cancels it.
// Hovered and dragged handles turn yellow.
//
// Toolbar toggles, as in Unity:
//   Pivot / Center  where the gizmo sits and what it turns and scales around. Pivot: the active
//                   object's origin, and each object turns and scales around its own origin.
//                   Center: the middle of the selection's bounds, and the selection turns and
//                   scales as one group around it.
//   Global / Local  Move and Rotate use world axes or the active object's own axes. Scale always
//                   uses local axes.
// The active object is the one selected last (see active_selected_entity).
//
// How it works:
//   - Like Unity's, the gizmo is drawn on top of the scene with the 2D overlay at a constant
//     size on screen, and hit-tested in screen space: the distance from the mouse to each
//     handle's projected line or ring, or whether it's inside a plane square.
//   - Dragging is solved in 3D. Move finds where the mouse ray passes closest to the axis line
//     (core.closest_line_parameter_to_ray), or where it crosses the handle's plane
//     (core.ray_plane_intersection); the change since the press is the movement. Scale divides
//     the axis position by the one at the press. Rotate measures the angle the mouse sweeps
//     around the gizmo's centre on screen, signed by whether the axis faces the viewer
//     (right-hand rule).
//   - Every frame recomputes the transforms from those saved at the press, rather than adding
//     small increments, so nothing drifts and cancelling restores the originals exactly.
package game

import "core:math"
import "core:math/linalg"
import "engine:core"
import "engine:platform"
import "engine:render"

Transform_Tool :: enum u8 {
	Hand,
	Move,
	Rotate,
	Scale,
}

TRANSFORM_TOOL_LABELS :: [Transform_Tool]string{
	.Hand   = "Hand (Q)",
	.Move   = "Move (W)",
	.Rotate = "Rotate (E)",
	.Scale  = "Scale (R)",
}

Gizmo_Part :: enum u8 {
	None,
	X, // axis arrows (Move), handles (Scale) and rings (Rotate)
	Y,
	Z,
	Plane_YZ, // Move in a plane; named by the axes it spans, coloured by the axis it faces
	Plane_ZX,
	Plane_XY,
	Center, // uniform scale
	View,   // the outer rotation ring: turn around the view direction
}

// Unity's "tool handle position".
Handle_Position :: enum u8 {
	Pivot,
	Center,
}

HANDLE_POSITION_LABELS :: [Handle_Position]string{
	.Pivot  = "Pivot",
	.Center = "Center",
}

MAX_DRAGGED_ENTITIES      :: 1024
GIZMO_SIZE_POINTS         :: 110 // handle length on screen
GIZMO_LINE_POINTS         :: 2.5
GIZMO_HIT_DISTANCE_POINTS :: 9
GIZMO_RING_SEGMENTS       :: 64
GIZMO_MIN_SCREEN_LENGTH_POINTS :: 12 // axes pointing (almost) at the camera can't be dragged
PLANE_HANDLE_INNER        :: 0.12 // plane squares span this range of the handle length on both axes
PLANE_HANDLE_OUTER        :: 0.38
PLANE_HANDLE_MIN_FACING   :: 0.2  // planes seen this close to edge-on are hidden (cosine)
PLANE_HANDLE_FILL_ALPHA   :: 0.35
VIEW_RING_SCALE           :: 1.15 // the outer ring's radius, relative to the handle length
MOVE_SNAP_UNITS           :: 0.25
ROTATE_SNAP_DEGREES       :: 15
SCALE_SNAP_STEP           :: 0.1
UNIFORM_SCALE_POINTS_PER_DOUBLING :: 150

GIZMO_AXIS_COLORS :: [3][4]f32{{0.93, 0.27, 0.22, 1}, {0.45, 0.82, 0.25, 1}, {0.25, 0.5, 0.95, 1}}
GIZMO_CENTER_COLOR :: [4]f32{0.85, 0.85, 0.85, 1}
GIZMO_HIGHLIGHT_COLOR :: [4]f32{1.0, 0.92, 0.02, 1} // Unity's yellow

Dragged_Entity :: struct {
	handle:   Entity_Handle,
	position: [3]f32,
	rotation: [3]f32,
	scale:    [3]f32,
}

Gizmo_State :: struct {
	tool:              Transform_Tool,
	handle_position:   Handle_Position,
	local_orientation: bool,
	hovered:           Gizmo_Part,
	active:            Gizmo_Part, // being dragged
	// Captured when the drag starts:
	drag_origin:       [3]f32,
	drag_axes:         [3][3]f32,
	drag_start_mouse:  [2]f32,
	drag_start_value:  f32, // axis parameter (Move, Scale) or screen angle (Rotate)
	drag_previous_angle: f32,
	drag_total_angle:  f32, // accumulated, so rotations past 180° keep going
	drag_start_point:  [3]f32, // where the mouse ray met the plane (plane handles)
	drag_view_axis:    [3]f32, // toward the viewer (the View ring's rotation axis)
	dragged:           [MAX_DRAGGED_ENTITIES]Dragged_Entity,
	dragged_count:     int,
}

// Where the gizmo is this frame, and how to map world points to viewport pixels.
Gizmo_Frame :: struct {
	visible:         bool,
	origin:          [3]f32,
	axes:            [3][3]f32, // unit world directions of the X, Y, Z handles
	world_length:    f32,       // handle length in world units (constant on screen)
	origin_pixel:    [2]f32,
	toward_viewer:   [3]f32,    // unit vector from the gizmo to the camera
	view_projection: matrix[4, 4]f32,
	viewport_min:    [2]f32,
	viewport_max:    [2]f32,
	points_to_pixels: f32,
}

toggle_handle_position :: proc(gizmo: ^Gizmo_State) {
	gizmo.handle_position = .Center if gizmo.handle_position == .Pivot else .Pivot
}

// The camera matrices the renderer uses for the 3D view, from the last frame's viewport.
viewport_view_projection :: proc(memory: ^Game_Memory) -> matrix[4, 4]f32 {
	viewport_size := memory.viewport_max - memory.viewport_min
	eye := viewport_camera_eye(memory.camera)
	view := core.look_at(eye, memory.camera.pivot, core.WORLD_UP)
	projection := core.perspective_reverse_z(memory.camera.vertical_fov, viewport_size.x / max(viewport_size.y, 1), 0.05)
	return projection * view
}

// World point to window pixel. `visible` is false for points behind the camera.
project_to_pixel :: proc(view_projection: matrix[4, 4]f32, viewport_min, viewport_max: [2]f32, point: [3]f32) -> (pixel: [2]f32, visible: bool) {
	clip := view_projection * [4]f32{point.x, point.y, point.z, 1}
	if clip.w <= 1e-6 {
		return {}, false
	}
	normalized := clip.xy / clip.w
	return viewport_min + [2]f32{(normalized.x + 1) * 0.5, (1 - normalized.y) * 0.5} * (viewport_max - viewport_min), true
}

compute_gizmo_frame :: proc(memory: ^Game_Memory) -> (frame: Gizmo_Frame) {
	gizmo := &memory.gizmo
	scene := &memory.scene
	if gizmo.tool == .Hand || memory.viewport_max == {} {
		return
	}
	// Origin: the active object's origin (Pivot) or the middle of the selection's bounds
	// (Center). Orientation: world axes, or the active object's (Local mode, and always for
	// Scale).
	_, active, any_selected := active_selected_entity(memory)
	if !any_selected {
		return
	}
	switch gizmo.handle_position {
	case .Pivot:
		frame.origin = active.position
	case .Center:
		bounds_min, bounds_max, _ := selection_world_bounds(scene)
		frame.origin = (bounds_min + bounds_max) * 0.5
	}
	frame.axes = {core.WORLD_RIGHT, core.WORLD_UP, {0, 0, 1}}
	if gizmo.local_orientation || gizmo.tool == .Scale {
		rotation := core.euler_rotation_matrix(active.rotation)
		for axis in 0 ..< 3 {
			frame.axes[axis] = linalg.normalize((rotation * [4]f32{frame.axes[axis].x, frame.axes[axis].y, frame.axes[axis].z, 0}).xyz)
		}
	}
	if gizmo.active != .None {
		frame.origin, frame.axes = gizmo.drag_origin, gizmo.drag_axes // stay put while dragging
	}

	frame.view_projection = viewport_view_projection(memory)
	frame.viewport_min, frame.viewport_max = memory.viewport_min, memory.viewport_max
	frame.points_to_pixels = memory.user_interface.scale if memory.user_interface.scale > 0 else 1
	origin_pixel, origin_visible := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin)
	if !origin_visible {
		return
	}
	frame.origin_pixel = origin_pixel

	// World size of one pixel at the gizmo's depth, to keep the gizmo a constant size on screen.
	eye := viewport_camera_eye(memory.camera)
	forward := linalg.normalize(memory.camera.pivot - eye)
	depth := linalg.dot(frame.origin - eye, forward)
	viewport_height := max(frame.viewport_max.y - frame.viewport_min.y, 1)
	world_per_pixel := 2 * depth * math.tan(memory.camera.vertical_fov * 0.5) / viewport_height
	frame.world_length = GIZMO_SIZE_POINTS * frame.points_to_pixels * world_per_pixel
	frame.toward_viewer = linalg.normalize(eye - frame.origin)
	frame.visible = true
	return
}

// Mouse handling for the gizmo. Returns true when the gizmo owns the mouse this frame (hovering
// a handle or dragging), so clicks don't also select. `input` is unfiltered: a drag that strays
// over a panel keeps going, and its release is never lost.
update_gizmo :: proc(memory: ^Game_Memory, input: ^platform.Input, viewport_has_mouse: bool) -> (owns_mouse: bool) {
	gizmo := &memory.gizmo
	frame := compute_gizmo_frame(memory)
	left_mouse := input.mouse[.Left]
	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down

	if gizmo.active != .None {
		if input.keys[.Escape].pressed {
			restore_dragged_transforms(memory)
			gizmo.active = .None
			return true
		}
		if left_mouse.down {
			apply_gizmo_drag(memory, frame, input)
		} else {
			gizmo.active = .None // released (even outside the view)
		}
		return true
	}

	gizmo.hovered = .None
	if !frame.visible || !viewport_has_mouse || alt_held || left_mouse.down && !left_mouse.pressed {
		return false
	}
	gizmo.hovered = gizmo_part_under_mouse(memory, frame, input.mouse_position)
	if gizmo.hovered != .None && left_mouse.pressed {
		begin_gizmo_drag(memory, frame, gizmo.hovered, input.mouse_position)
	}
	return gizmo.hovered != .None
}

@(private = "file")
gizmo_part_under_mouse :: proc(memory: ^Game_Memory, frame: Gizmo_Frame, mouse: [2]f32) -> Gizmo_Part {
	tool := memory.gizmo.tool
	best_part := Gizmo_Part.None
	best_distance := GIZMO_HIT_DISTANCE_POINTS * frame.points_to_pixels
	parts := [3]Gizmo_Part{.X, .Y, .Z}

	if tool == .Rotate {
		for axis in 0 ..< 3 {
			ring := ring_pixels(frame, axis)
			for segment_index in 0 ..< GIZMO_RING_SEGMENTS {
				if !ring.visible[segment_index] || !ring.visible[segment_index + 1] {
					continue
				}
				distance := pixel_segment_distance(mouse, ring.pixels[segment_index], ring.pixels[segment_index + 1])
				if distance < best_distance {
					best_distance, best_part = distance, parts[axis]
				}
			}
		}
		view_ring_distance := abs(linalg.length(mouse - frame.origin_pixel) - view_ring_radius(frame))
		if view_ring_distance < best_distance {
			best_part = .View
		}
		return best_part
	}

	if tool == .Move {
		// Inside a plane square wins over the axis lines that border it.
		plane_parts := [3]Gizmo_Part{.Plane_YZ, .Plane_ZX, .Plane_XY}
		for normal_axis in 0 ..< 3 {
			quad, quad_visible := plane_handle_pixels(frame, normal_axis)
			if quad_visible && point_in_convex_quad(mouse, quad) {
				return plane_parts[normal_axis]
			}
		}
	}
	if tool == .Scale {
		center_half_size := 7 * frame.points_to_pixels
		if linalg.length(mouse - frame.origin_pixel) < center_half_size + 2 {
			return .Center
		}
	}
	for axis in 0 ..< 3 {
		tip_pixel, tip_visible := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + frame.axes[axis] * frame.world_length)
		if !tip_visible || linalg.length(tip_pixel - frame.origin_pixel) < GIZMO_MIN_SCREEN_LENGTH_POINTS * frame.points_to_pixels {
			continue
		}
		// The arrowhead or end cube extends the handle a little past the line's end.
		direction := linalg.normalize(tip_pixel - frame.origin_pixel)
		handle_end := tip_pixel + direction * 12 * frame.points_to_pixels
		distance := pixel_segment_distance(mouse, frame.origin_pixel, handle_end)
		if distance < best_distance {
			best_distance, best_part = distance, parts[axis]
		}
	}
	return best_part
}

@(private = "file")
begin_gizmo_drag :: proc(memory: ^Game_Memory, frame: Gizmo_Frame, part: Gizmo_Part, mouse: [2]f32) {
	gizmo := &memory.gizmo
	scene := &memory.scene
	gizmo.drag_origin = frame.origin
	gizmo.drag_axes = frame.axes
	gizmo.drag_start_mouse = mouse

	switch part {
	case .None:
		return
	case .X, .Y, .Z:
		if gizmo.tool == .Move || gizmo.tool == .Scale {
			axis := int(part) - int(Gizmo_Part.X)
			parameter, ok := closest_line_parameter_to_mouse(memory, frame.origin, frame.axes[axis], mouse)
			if !ok || (gizmo.tool == .Scale && abs(parameter) < 1e-6) {
				return // edge-on or degenerate: don't start a drag we can't measure
			}
			gizmo.drag_start_value = parameter
		}
	case .Plane_YZ, .Plane_ZX, .Plane_XY:
		normal_axis := int(part) - int(Gizmo_Part.Plane_YZ)
		point, hit := mouse_on_plane(memory, frame.origin, frame.axes[normal_axis], mouse)
		if !hit {
			return
		}
		gizmo.drag_start_point = point
	case .Center:
	case .View:
		gizmo.drag_view_axis = frame.toward_viewer
	}
	if gizmo.tool == .Rotate {
		gizmo.drag_start_value = screen_angle(frame.origin_pixel, mouse)
		gizmo.drag_previous_angle = gizmo.drag_start_value
		gizmo.drag_total_angle = 0
	}

	gizmo.dragged_count = 0
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags && .Selected in entity.flags && gizmo.dragged_count < MAX_DRAGGED_ENTITIES {
			gizmo.dragged[gizmo.dragged_count] = {
				handle   = entity_handle(scene, slot_index),
				position = entity.position,
				rotation = entity.rotation,
				scale    = entity.scale,
			}
			gizmo.dragged_count += 1
		}
	}
	gizmo.active = part
}

@(private = "file")
apply_gizmo_drag :: proc(memory: ^Game_Memory, frame: Gizmo_Frame, input: ^platform.Input) {
	gizmo := &memory.gizmo
	scene := &memory.scene
	snapping := input.keys[.Left_Ctrl].down || input.keys[.Right_Ctrl].down
	mouse := input.mouse_position
	axis := int(gizmo.active) - int(Gizmo_Part.X) // only meaningful for .X, .Y and .Z
	group_around_center := gizmo.handle_position == .Center

	switch gizmo.tool {
	case .Move:
		offset: [3]f32
		switch gizmo.active {
		case .Plane_YZ, .Plane_ZX, .Plane_XY:
			// Where the mouse ray crosses the plane now, against where it crossed at the press,
			// measured along the plane's two axes (each snapped on its own).
			normal_axis := int(gizmo.active) - int(Gizmo_Part.Plane_YZ)
			point, hit := mouse_on_plane(memory, gizmo.drag_origin, gizmo.drag_axes[normal_axis], mouse)
			if !hit {
				return
			}
			moved := point - gizmo.drag_start_point
			for in_plane_axis in ([2]int{(normal_axis + 1) % 3, (normal_axis + 2) % 3}) {
				direction := gizmo.drag_axes[in_plane_axis]
				distance := linalg.dot(moved, direction)
				if snapping {
					distance = math.round(distance / MOVE_SNAP_UNITS) * MOVE_SNAP_UNITS
				}
				offset += direction * distance
			}
		case .X, .Y, .Z:
			parameter, ok := closest_line_parameter_to_mouse(memory, gizmo.drag_origin, gizmo.drag_axes[axis], mouse)
			if !ok {
				return
			}
			distance := parameter - gizmo.drag_start_value
			if snapping {
				distance = math.round(distance / MOVE_SNAP_UNITS) * MOVE_SNAP_UNITS
			}
			offset = gizmo.drag_axes[axis] * distance
		case .None, .Center, .View:
			return
		}
		for dragged in gizmo.dragged[:gizmo.dragged_count] {
			if entity, found := get_entity(scene, dragged.handle); found {
				entity.position = dragged.position + offset
			}
		}

	case .Rotate:
		// Accumulate the angle swept on screen (unwrapping across ±180°), then turn it into a
		// rotation about the axis. Seen from the side the axis points to, positive rotation is
		// counter-clockwise; the screen angle is measured y-up, so flip the sign when the axis
		// points away from the viewer. (The View ring's axis points at the viewer.)
		angle := screen_angle(frame.origin_pixel, mouse)
		step := angle - gizmo.drag_previous_angle
		if step > math.PI do step -= 2 * math.PI
		if step < -math.PI do step += 2 * math.PI
		gizmo.drag_total_angle += step
		gizmo.drag_previous_angle = angle
		axis_direction := gizmo.drag_view_axis if gizmo.active == .View else gizmo.drag_axes[axis]
		degrees := gizmo.drag_total_angle * (180 / math.PI)
		if linalg.dot(axis_direction, frame.toward_viewer) < 0 {
			degrees = -degrees
		}
		if snapping {
			degrees = math.round(degrees / ROTATE_SNAP_DEGREES) * ROTATE_SNAP_DEGREES
		}
		turn := linalg.matrix4_rotate_f32(degrees * (math.PI / 180), axis_direction)
		for dragged in gizmo.dragged[:gizmo.dragged_count] {
			if entity, found := get_entity(scene, dragged.handle); found {
				// Choose the Euler angles nearest last frame's, so the Inspector's numbers change smoothly.
				entity.rotation = core.euler_degrees_from_matrix_near(turn * core.euler_rotation_matrix(dragged.rotation), entity.rotation)
				// Center: the objects also orbit the shared centre, like one rigid group. Pivot:
				// each turns in place.
				if group_around_center {
					offset := dragged.position - gizmo.drag_origin
					entity.position = gizmo.drag_origin + (turn * [4]f32{offset.x, offset.y, offset.z, 0}).xyz
				}
			}
		}

	case .Scale:
		factor: f32
		if gizmo.active == .Center {
			// Uniform: dragging right grows, left shrinks; exponential so it's symmetric.
			pixels := mouse.x - gizmo.drag_start_mouse.x
			factor = math.exp(pixels / (UNIFORM_SCALE_POINTS_PER_DOUBLING * frame.points_to_pixels) * math.LN2)
		} else {
			parameter, ok := closest_line_parameter_to_mouse(memory, gizmo.drag_origin, gizmo.drag_axes[axis], mouse)
			if !ok {
				return
			}
			factor = parameter / gizmo.drag_start_value
		}
		if snapping {
			factor = math.round(factor / SCALE_SNAP_STEP) * SCALE_SNAP_STEP
		}
		for dragged in gizmo.dragged[:gizmo.dragged_count] {
			if entity, found := get_entity(scene, dragged.handle); found {
				entity.scale = dragged.scale
				if gizmo.active == .Center {
					entity.scale = dragged.scale * factor
				} else {
					entity.scale[axis] = dragged.scale[axis] * factor
				}
				// Center: the group's spacing scales too (along the dragged axis, or uniformly),
				// so it grows as one object would. Pivot: each scales in place.
				if group_around_center {
					offset := dragged.position - gizmo.drag_origin
					if gizmo.active == .Center {
						offset *= factor
					} else {
						direction := gizmo.drag_axes[axis]
						offset += direction * (linalg.dot(offset, direction) * (factor - 1))
					}
					entity.position = gizmo.drag_origin + offset
				}
			}
		}

	case .Hand:
	}
}

@(private = "file")
restore_dragged_transforms :: proc(memory: ^Game_Memory) {
	gizmo := &memory.gizmo
	for dragged in gizmo.dragged[:gizmo.dragged_count] {
		if entity, found := get_entity(&memory.scene, dragged.handle); found {
			entity.position, entity.rotation, entity.scale = dragged.position, dragged.rotation, dragged.scale
		}
	}
}

@(private = "file")
closest_line_parameter_to_mouse :: proc(memory: ^Game_Memory, line_origin, line_direction: [3]f32, mouse: [2]f32) -> (f32, bool) {
	return core.closest_line_parameter_to_ray(line_origin, line_direction, viewport_ray(memory, mouse))
}

// Where the mouse ray crosses a plane, in world space.
@(private = "file")
mouse_on_plane :: proc(memory: ^Game_Memory, plane_point, plane_normal: [3]f32, mouse: [2]f32) -> (point: [3]f32, hit: bool) {
	ray := viewport_ray(memory, mouse)
	t := core.ray_plane_intersection(ray, plane_point, plane_normal) or_return
	return core.ray_point(ray, t), true
}

// Angle of `point` around `center` on screen, counter-clockwise with y up (screen y points down).
@(private = "file")
screen_angle :: proc(center, point: [2]f32) -> f32 {
	return math.atan2(-(point.y - center.y), point.x - center.x)
}

@(private = "file")
pixel_segment_distance :: proc(point, start, end: [2]f32) -> f32 {
	along := end - start
	length_squared := linalg.dot(along, along)
	if length_squared < 1e-6 {
		return linalg.length(point - start)
	}
	fraction := clamp(linalg.dot(point - start, along) / length_squared, 0, 1)
	return linalg.length(point - (start + along * fraction))
}

Ring_Pixels :: struct {
	pixels:  [GIZMO_RING_SEGMENTS + 1][2]f32,
	visible: [GIZMO_RING_SEGMENTS + 1]bool,
	facing:  [GIZMO_RING_SEGMENTS + 1]bool, // on the half of the ring nearer the viewer
}

// Points of the rotation ring around one axis, projected to the screen.
@(private = "file")
ring_pixels :: proc(frame: Gizmo_Frame, axis: int) -> (ring: Ring_Pixels) {
	first_tangent := frame.axes[(axis + 1) % 3]
	second_tangent := frame.axes[(axis + 2) % 3]
	for point_index in 0 ..= GIZMO_RING_SEGMENTS {
		angle := 2 * math.PI * f32(point_index) / GIZMO_RING_SEGMENTS
		offset := (first_tangent * math.cos(angle) + second_tangent * math.sin(angle)) * frame.world_length
		ring.pixels[point_index], ring.visible[point_index] = project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + offset)
		ring.facing[point_index] = linalg.dot(offset, frame.toward_viewer) >= 0
	}
	return
}

// The outer rotation ring's radius in pixels: a circle on screen, just outside the axis rings.
view_ring_radius :: proc(frame: Gizmo_Frame) -> f32 {
	return GIZMO_SIZE_POINTS * VIEW_RING_SCALE * frame.points_to_pixels
}

// The corners of the Move tool's square for the plane facing `normal_axis`, in world space.
// Like Unity's, each square sits on the side of its two axes that faces the camera, so it's
// never hidden behind the rest of the gizmo.
plane_handle_world_corners :: proc(frame: Gizmo_Frame, normal_axis: int) -> (corners: [4][3]f32) {
	first_axis := frame.axes[(normal_axis + 1) % 3]
	second_axis := frame.axes[(normal_axis + 2) % 3]
	if linalg.dot(first_axis, frame.toward_viewer) < 0 do first_axis = -first_axis
	if linalg.dot(second_axis, frame.toward_viewer) < 0 do second_axis = -second_axis
	inner := PLANE_HANDLE_INNER * frame.world_length
	outer := PLANE_HANDLE_OUTER * frame.world_length
	corners = {
		frame.origin + first_axis * inner + second_axis * inner,
		frame.origin + first_axis * outer + second_axis * inner,
		frame.origin + first_axis * outer + second_axis * outer,
		frame.origin + first_axis * inner + second_axis * outer,
	}
	return
}

// The square on screen. Not visible when its plane is seen nearly edge-on (it would be a sliver
// that's hard to hit, and dragging in it would be unstable).
@(private = "file")
plane_handle_pixels :: proc(frame: Gizmo_Frame, normal_axis: int) -> (quad: [4][2]f32, visible: bool) {
	if abs(linalg.dot(frame.axes[normal_axis], frame.toward_viewer)) < PLANE_HANDLE_MIN_FACING {
		return
	}
	for corner, corner_index in plane_handle_world_corners(frame, normal_axis) {
		corner_visible: bool
		quad[corner_index], corner_visible = project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, corner)
		if !corner_visible {
			return
		}
	}
	return quad, true
}

// Whether a point is inside a convex quadrilateral given in order (either winding): it must be
// on the same side of all four edges.
@(private = "file")
point_in_convex_quad :: proc(point: [2]f32, quad: [4][2]f32) -> bool {
	side: f32 = 0
	for corner_index in 0 ..< 4 {
		edge := quad[(corner_index + 1) % 4] - quad[corner_index]
		to_point := point - quad[corner_index]
		cross := edge.x * to_point.y - edge.y * to_point.x
		if cross == 0 {
			continue
		}
		if side == 0 {
			side = cross
		} else if (cross > 0) != (side > 0) {
			return false
		}
	}
	return true
}

draw_gizmo :: proc(memory: ^Game_Memory, renderer: ^render.Renderer) {
	gizmo := &memory.gizmo
	frame := compute_gizmo_frame(memory)
	if !frame.visible {
		return
	}
	scale := frame.points_to_pixels
	line_width := GIZMO_LINE_POINTS * scale
	axis_colors := GIZMO_AXIS_COLORS
	parts := [3]Gizmo_Part{.X, .Y, .Z}
	part_color :: proc(gizmo: ^Gizmo_State, part: Gizmo_Part, base: [4]f32) -> [4]f32 {
		highlighted := gizmo.active == part || (gizmo.active == .None && gizmo.hovered == part)
		return GIZMO_HIGHLIGHT_COLOR if highlighted else base
	}

	// Keep the gizmo inside the 3D view; the UI panels draw over it afterwards.
	render.overlay_set_scissor(renderer, frame.viewport_min, frame.viewport_max)
	defer render.overlay_clear_scissor(renderer)

	switch gizmo.tool {
	case .Move, .Scale:
		if gizmo.tool == .Move {
			// Plane squares first, so the arrows draw over them: a translucent fill, a solid
			// edge. Coloured by the axis each square faces, as in Unity.
			plane_parts := [3]Gizmo_Part{.Plane_YZ, .Plane_ZX, .Plane_XY}
			for normal_axis in 0 ..< 3 {
				quad, quad_visible := plane_handle_pixels(frame, normal_axis)
				if !quad_visible {
					continue
				}
				color := part_color(gizmo, plane_parts[normal_axis], axis_colors[normal_axis])
				fill := color
				fill.a *= PLANE_HANDLE_FILL_ALPHA
				render.overlay_triangle(renderer, quad[0], quad[1], quad[2], fill)
				render.overlay_triangle(renderer, quad[0], quad[2], quad[3], fill)
				for corner_index in 0 ..< 4 {
					render.overlay_segment(renderer, quad[corner_index], quad[(corner_index + 1) % 4], 1.5 * scale, color)
				}
			}
		}
		for axis in 0 ..< 3 {
			tip_pixel, tip_visible := project_to_pixel(frame.view_projection, frame.viewport_min, frame.viewport_max, frame.origin + frame.axes[axis] * frame.world_length)
			screen_length := linalg.length(tip_pixel - frame.origin_pixel)
			if !tip_visible || screen_length < GIZMO_MIN_SCREEN_LENGTH_POINTS * scale {
				continue
			}
			color := part_color(gizmo, parts[axis], axis_colors[axis])
			render.overlay_segment(renderer, frame.origin_pixel, tip_pixel, line_width, color)
			direction := (tip_pixel - frame.origin_pixel) / screen_length
			if gizmo.tool == .Move {
				// Arrowhead: a triangle continuing the line.
				side := [2]f32{-direction.y, direction.x} * 6 * scale
				render.overlay_triangle(renderer, tip_pixel + side, tip_pixel - side, tip_pixel + direction * 16 * scale, color)
			} else {
				half_size := 5 * scale
				render.overlay_rect(renderer, tip_pixel - half_size, tip_pixel + half_size, color, 1.5 * scale)
			}
		}
		if gizmo.tool == .Scale {
			half_size := 7 * scale
			render.overlay_rect(renderer, frame.origin_pixel - half_size, frame.origin_pixel + half_size, part_color(gizmo, .Center, GIZMO_CENTER_COLOR), 2 * scale)
		}

	case .Rotate:
		// Draw the far halves faintly first, then the near halves on top.
		for pass in 0 ..< 2 {
			draw_near_half := pass == 1
			for axis in 0 ..< 3 {
				ring := ring_pixels(frame, axis)
				color := part_color(gizmo, parts[axis], axis_colors[axis])
				if !draw_near_half {
					color.a *= 0.3
				}
				for segment_index in 0 ..< GIZMO_RING_SEGMENTS {
					if !ring.visible[segment_index] || !ring.visible[segment_index + 1] {
						continue
					}
					if (ring.facing[segment_index] && ring.facing[segment_index + 1]) != draw_near_half {
						continue
					}
					render.overlay_segment(renderer, ring.pixels[segment_index], ring.pixels[segment_index + 1], line_width, color)
				}
			}
		}
		// The outer ring turns around the view direction; a circle on screen, as in Unity.
		radius := view_ring_radius(frame)
		render.overlay_rect(renderer, frame.origin_pixel - radius - line_width * 0.5, frame.origin_pixel + radius + line_width * 0.5, part_color(gizmo, .View, GIZMO_CENTER_COLOR), radius + line_width * 0.5, line_width)
		// A small dot marks the centre.
		dot_radius := 3 * scale
		render.overlay_rect(renderer, frame.origin_pixel - dot_radius, frame.origin_pixel + dot_radius, GIZMO_CENTER_COLOR, dot_radius)

	case .Hand:
	}
}
