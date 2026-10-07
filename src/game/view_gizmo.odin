// The view gizmo in the 3D view's top-right corner (Unity's "scene gizmo"): it shows which way
// the world axes point, and clicking it turns the camera.
//
//   X Y Z knobs (coloured, lettered)    look from that side: Right, Top, Front
//   -X -Y -Z knobs (smaller, hollow)    Left, Bottom, Back
//   corner knobs (small, grey)          look from a corner of the cube along its diagonal; in
//                                       orthographic mode that is the isometric view
//   centre square                       switch perspective / orthographic
//   label underneath                    names the view; clicking it also switches projection
//   dragging anywhere on it             orbits the camera, like Alt + left drag
// The centre square is drawn over the knobs, so it stays clickable when a knob faces you
// (that knob is the view you're in).
//
// How it works: every knob is a unit direction from the gizmo's centre. Projecting it onto the
// camera's right and up axes gives its offset on screen (an orthographic projection of just
// the camera's rotation, so the gizmo never changes size), and its component toward the viewer
// gives its depth. Knobs are drawn far to near, and hit-tested near to far, so what's on top is
// what gets clicked. Snapping only changes the camera's yaw and pitch: the pivot and distance
// stay, so the object you were looking at stays in the middle.
package game

import "core:fmt"
import "core:math/linalg"
import "engine:platform"
import "engine:render"
import "engine:ui"

VIEW_GIZMO_RADIUS_POINTS        :: 36 // centre to an axis knob
VIEW_GIZMO_MARGIN_POINTS        :: 18 // from the view's top-right corner to the knobs' reach
VIEW_GIZMO_AXIS_KNOB_POINTS     :: 9  // knob radii
VIEW_GIZMO_NEGATIVE_KNOB_POINTS :: 6.5
VIEW_GIZMO_CORNER_KNOB_POINTS   :: 4.5
VIEW_GIZMO_CENTER_POINTS        :: 7  // half the centre square's size
VIEW_GIZMO_LABEL_SIZE_POINTS    :: [2]f32{96, 18}
VIEW_GIZMO_DIRECTION_COUNT      :: 14
VIEW_GIZMO_ALIGNED_COSINE       :: 0.9999 // "already looking from this direction"

// Six axis directions (+X -X +Y -Y +Z -Z), then the eight cube corners. Corners aren't unit
// length here; they're normalized where used.
VIEW_GIZMO_DIRECTIONS :: [VIEW_GIZMO_DIRECTION_COUNT][3]f32{
	{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
	{1, 1, 1}, {1, 1, -1}, {1, -1, 1}, {1, -1, -1}, {-1, 1, 1}, {-1, 1, -1}, {-1, -1, 1}, {-1, -1, -1},
}
// Names of the axis views, in the order above. +Z points toward the default viewer, so the
// view from +Z is the Front.
VIEW_GIZMO_AXIS_VIEW_NAMES :: [6]string{"Right", "Left", "Top", "Bottom", "Front", "Back"}
VIEW_GIZMO_AXIS_LETTERS    :: [3]string{"X", "Y", "Z"}
VIEW_GIZMO_CORNER_COLOR    :: [4]f32{0.62, 0.62, 0.66, 1}
VIEW_GIZMO_LETTER_COLOR    :: [4]f32{0.06, 0.06, 0.07, 1}

View_Gizmo_Part :: enum u8 {
	None,
	Direction,  // a knob; which one is in Editor_State.view_gizmo_hovered_direction
	Projection, // the centre square or the label
	Background, // the disc around the knobs: only for dragging
}

// Where everything is on screen this frame.
View_Gizmo_Layout :: struct {
	center:           [2]f32,
	knob_centers:     [VIEW_GIZMO_DIRECTION_COUNT][2]f32,
	knob_radii:       [VIEW_GIZMO_DIRECTION_COUNT]f32,
	knob_depths:      [VIEW_GIZMO_DIRECTION_COUNT]f32, // toward the viewer: 1 in front, -1 behind
	center_half_size: f32,
	background_radius: f32, // the disc that can be dragged to orbit
	label_min:        [2]f32,
	label_max:        [2]f32,
	points_to_pixels: f32,
}

compute_view_gizmo_layout :: proc(memory: ^Game_Memory) -> (layout: View_Gizmo_Layout) {
	scale := memory.user_interface.scale if memory.user_interface.scale > 0 else 1
	layout.points_to_pixels = scale
	radius := VIEW_GIZMO_RADIUS_POINTS * scale
	reach := radius + VIEW_GIZMO_AXIS_KNOB_POINTS * scale + VIEW_GIZMO_MARGIN_POINTS * scale
	layout.center = {memory.viewport_max.x - reach, memory.viewport_min.y + reach}
	layout.center_half_size = VIEW_GIZMO_CENTER_POINTS * scale
	layout.background_radius = radius + (VIEW_GIZMO_AXIS_KNOB_POINTS + 4) * scale

	_, right, up := viewport_camera_basis(memory.camera)
	toward_viewer := viewport_camera_eye_direction(memory.camera)
	directions := VIEW_GIZMO_DIRECTIONS
	for direction, direction_index in directions {
		unit := linalg.normalize(direction)
		depth := linalg.dot(unit, toward_viewer)
		layout.knob_depths[direction_index] = depth
		// Screen y points down.
		layout.knob_centers[direction_index] = layout.center + [2]f32{linalg.dot(unit, right), -linalg.dot(unit, up)} * radius
		knob_points: f32 = VIEW_GIZMO_CORNER_KNOB_POINTS
		if direction_index < 6 {
			knob_points = VIEW_GIZMO_AXIS_KNOB_POINTS if direction_index % 2 == 0 else VIEW_GIZMO_NEGATIVE_KNOB_POINTS
		}
		// Slightly larger in front and smaller behind, a cheap depth cue.
		layout.knob_radii[direction_index] = knob_points * scale * (1 + 0.12 * depth)
	}

	label_size := VIEW_GIZMO_LABEL_SIZE_POINTS * scale
	label_top := layout.center.y + radius + VIEW_GIZMO_AXIS_KNOB_POINTS * scale + 6 * scale
	layout.label_min = {layout.center.x - label_size.x * 0.5, label_top}
	layout.label_max = layout.label_min + label_size
	return
}

// The knobs in drawing order, far to near.
@(private = "file")
view_gizmo_draw_order :: proc(layout: View_Gizmo_Layout) -> (order: [VIEW_GIZMO_DIRECTION_COUNT]int) {
	for direction_index in 0 ..< len(order) {
		order[direction_index] = direction_index
	}
	// Insertion sort: 14 items.
	for sorted_count in 1 ..< len(order) {
		for position := sorted_count; position > 0 && layout.knob_depths[order[position]] < layout.knob_depths[order[position - 1]]; position -= 1 {
			order[position], order[position - 1] = order[position - 1], order[position]
		}
	}
	return
}

// The label and the centre square come first: they're drawn on top. Then the knobs, near to
// far.
view_gizmo_part_under_mouse :: proc(layout: View_Gizmo_Layout, mouse: [2]f32) -> (part: View_Gizmo_Part, direction_index: int) {
	if mouse.x >= layout.label_min.x && mouse.x <= layout.label_max.x && mouse.y >= layout.label_min.y && mouse.y <= layout.label_max.y {
		return .Projection, 0
	}
	hit_margin := 2 * layout.points_to_pixels
	center_offset := linalg.abs(mouse - layout.center)
	if max(center_offset.x, center_offset.y) <= layout.center_half_size + hit_margin {
		return .Projection, 0
	}
	order := view_gizmo_draw_order(layout)
	#reverse for knob_index in order {
		if linalg.length(mouse - layout.knob_centers[knob_index]) <= layout.knob_radii[knob_index] + hit_margin {
			return .Direction, knob_index
		}
	}
	if linalg.length(mouse - layout.center) <= layout.background_radius {
		return .Background, 0
	}
	return .None, 0
}

// Hover, clicks and dragging. Returns true when the gizmo has the mouse (it's over a part, or a
// press on it is still held), so the click doesn't also select, and the view doesn't pan with
// the Hand tool.
//
// A press on any part becomes a click or a drag, decided by how far the mouse moves before the
// release (the same tolerance as selection clicks). Moved: the camera orbits with the mouse,
// as with Alt + left drag, and nothing is clicked. Not moved: the release clicks the part that
// was pressed. Clicks therefore act on release, not on press. `input` is unfiltered, so a drag
// keeps going over the panels and its release is never lost.
update_view_gizmo :: proc(memory: ^Game_Memory, input: ^platform.Input, viewport_has_mouse: bool) -> (owns_mouse: bool) {
	editor := &memory.editor
	editor.view_gizmo_hovered = .None
	left_mouse := input.mouse[.Left]

	if editor.view_gizmo_pressed != .None {
		if !editor.view_gizmo_dragging && linalg.length(input.mouse_position - editor.view_gizmo_press_position) > CLICK_MOVE_TOLERANCE_PIXELS {
			editor.view_gizmo_dragging = true
		}
		if editor.view_gizmo_dragging {
			orbit_viewport_camera(&memory.camera, input.mouse_delta)
			editor.view_gizmo_hovered = .Background // keep the disc lit while dragging
		} else {
			editor.view_gizmo_hovered, editor.view_gizmo_hovered_direction = editor.view_gizmo_pressed, editor.view_gizmo_pressed_direction
		}
		if !left_mouse.down {
			if !editor.view_gizmo_dragging {
				switch editor.view_gizmo_pressed {
				case .Direction:
					directions := VIEW_GIZMO_DIRECTIONS
					turn_viewport_camera(&memory.camera, directions[editor.view_gizmo_pressed_direction])
				case .Projection:
					switch_viewport_projection(&memory.camera)
				case .Background, .None:
				}
			}
			editor.view_gizmo_pressed = .None
			editor.view_gizmo_dragging = false
		}
		return true
	}

	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down
	if !viewport_has_mouse || alt_held || memory.viewport_max == {} {
		return false
	}
	// A drag that started elsewhere (orbit, pan, a gizmo handle) keeps the mouse.
	for button in platform.Mouse_Button {
		if input.mouse[button].down && !input.mouse[button].pressed {
			return false
		}
	}
	layout := compute_view_gizmo_layout(memory)
	part, direction_index := view_gizmo_part_under_mouse(layout, input.mouse_position)
	editor.view_gizmo_hovered, editor.view_gizmo_hovered_direction = part, direction_index
	if part == .None {
		return false
	}
	if left_mouse.pressed {
		editor.view_gizmo_pressed, editor.view_gizmo_pressed_direction = part, direction_index
		editor.view_gizmo_press_position = input.mouse_position
		editor.view_gizmo_dragging = false
	}
	return true
}

// The axis view the camera is in ("Top"), or "" between them.
view_gizmo_axis_view_name :: proc(camera: Viewport_Camera) -> string {
	directions := VIEW_GIZMO_DIRECTIONS
	names := VIEW_GIZMO_AXIS_VIEW_NAMES
	eye_direction := viewport_camera_eye_direction(camera)
	for axis_index in 0 ..< 6 {
		if linalg.dot(directions[axis_index], eye_direction) > VIEW_GIZMO_ALIGNED_COSINE {
			return names[axis_index]
		}
	}
	return ""
}

draw_view_gizmo :: proc(memory: ^Game_Memory, renderer: ^render.Renderer) {
	if memory.viewport_max == {} {
		return
	}
	editor := &memory.editor
	user_interface := &memory.user_interface
	layout := compute_view_gizmo_layout(memory)
	scale := layout.points_to_pixels
	axis_colors := GIZMO_AXIS_COLORS
	letters := VIEW_GIZMO_AXIS_LETTERS

	// Hovered parts lighten; parts on the far side darken, so the near side reads first.
	shade :: proc(color: [4]f32, depth: f32, hovered: bool) -> [4]f32 {
		shaded := color
		if depth < -0.01 {
			shaded.rgb *= 0.55
		}
		if hovered {
			shaded.rgb = linalg.lerp(shaded.rgb, [3]f32{1, 1, 1}, 0.45)
		}
		return shaded
	}

	render.overlay_set_scissor(renderer, memory.viewport_min, memory.viewport_max)
	defer render.overlay_clear_scissor(renderer)

	// A faint disc while the mouse is over the gizmo, brighter while dragging it: the whole disc
	// can be dragged to orbit, not just the knobs.
	if editor.view_gizmo_hovered != .None || editor.view_gizmo_pressed != .None {
		disc_alpha: f32 = 0.16 if editor.view_gizmo_dragging else 0.08
		disc_radius := layout.background_radius
		render.overlay_rect(renderer, layout.center - disc_radius, layout.center + disc_radius, {1, 1, 1, disc_alpha}, disc_radius)
	}

	for knob_index in view_gizmo_draw_order(layout) {
		knob_center := layout.knob_centers[knob_index]
		radius := layout.knob_radii[knob_index]
		depth := layout.knob_depths[knob_index]
		hovered := editor.view_gizmo_hovered == .Direction && editor.view_gizmo_hovered_direction == knob_index
		switch {
		case knob_index < 6 && knob_index % 2 == 0:
			// A positive axis: a line from the centre, a filled knob, its letter.
			axis := knob_index / 2
			color := shade(axis_colors[axis], depth, hovered)
			render.overlay_segment(renderer, layout.center, knob_center, 2 * scale, color)
			render.overlay_rect(renderer, knob_center - radius, knob_center + radius, color, radius)
			ui.overlay_text(user_interface, renderer, knob_center, letters[axis], VIEW_GIZMO_LETTER_COLOR, .Semibold, 10.5)
		case knob_index < 6:
			// A negative axis: a darker disc with a ring in the axis colour.
			axis := knob_index / 2
			color := shade(axis_colors[axis], depth, hovered)
			fill := color
			fill.rgb *= 0.35
			render.overlay_rect(renderer, knob_center - radius, knob_center + radius, fill, radius)
			render.overlay_rect(renderer, knob_center - radius, knob_center + radius, color, radius, 1.5 * scale)
		case:
			color := shade(VIEW_GIZMO_CORNER_COLOR, depth, hovered)
			render.overlay_rect(renderer, knob_center - radius, knob_center + radius, color, radius)
		}
	}

	// The centre square, on top of every knob: filled in orthographic mode, hollow (a dark
	// square with a light border) in perspective.
	center_hovered := editor.view_gizmo_hovered == .Projection
	center_color := shade({0.85, 0.85, 0.88, 1}, 0, center_hovered)
	half_size := layout.center_half_size
	if memory.camera.orthographic {
		render.overlay_rect(renderer, layout.center - half_size, layout.center + half_size, center_color, 2 * scale)
	} else {
		render.overlay_rect(renderer, layout.center - half_size, layout.center + half_size, {0.12, 0.12, 0.14, 1}, 2 * scale)
		render.overlay_rect(renderer, layout.center - half_size, layout.center + half_size, center_color, 2 * scale, 2 * scale)
	}

	// The label: the axis view's name, if the camera is in one, and the projection.
	projection_name := "Ortho" if memory.camera.orthographic else "Persp"
	label := projection_name
	if axis_view_name := view_gizmo_axis_view_name(memory.camera); axis_view_name != "" {
		label = fmt.tprintf("%s · %s", axis_view_name, projection_name)
	}
	label_hovered := editor.view_gizmo_hovered == .Projection
	label_background := [4]f32{0.16, 0.165, 0.18, 0.85} if !label_hovered else [4]f32{0.26, 0.27, 0.3, 0.95}
	render.overlay_rect(renderer, layout.label_min, layout.label_max, label_background, 4 * scale)
	ui.overlay_text(user_interface, renderer, (layout.label_min + layout.label_max) * 0.5, label, {0.86, 0.86, 0.88, 1}, .Regular, 11)
}

// The plane the grid lies in. Perspective always uses the ground. Orthographic keeps the ground
// too unless it's seen nearly edge-on (less than 20° from the side): there, as in the side
// views, it would be a thin smear or invisible, so the grid moves to the vertical plane the view
// faces most: XY for Front and Back, YZ for Right and Left.
grid_plane_for_view :: proc(camera: Viewport_Camera) -> render.Grid_Plane {
	GROUND_MIN_SINE :: 0.342 // sin(20°)
	if !viewport_camera_lens(camera).orthographic { // what's on screen, so not mid-switch
		return .XZ
	}
	toward_viewer := linalg.abs(viewport_camera_eye_direction(camera))
	if toward_viewer.y >= GROUND_MIN_SINE {
		return .XZ
	}
	return .XY if toward_viewer.z >= toward_viewer.x else .YZ
}
