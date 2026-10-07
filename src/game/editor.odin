// The editor: selection, picking, the Hierarchy and Inspector panels, and shortcuts.
//
// Selection is a flag on each entity (`.Selected`) rather than a separate list: the editor's
// loops already walk the entity pool, and a flag can't go stale when an entity is deleted.
// The *active* object (Unity's term) is the one selected last; the gizmo sits on it in Pivot
// mode and takes its axes in Local mode. It's a handle in Editor_State, checked against the
// selection whenever it's used, so it can't go stale either.
//
// Viewport clicks (Unity's rules):
//   click                select the object under the mouse; clicking empty space clears
//   Shift + click        add to the selection
//   Ctrl + click         toggle the object in or out of the selection
// A press only counts as a click if the mouse moved less than a few pixels before release, so
// it never fights with dragging.
//
// Shortcuts (when no field is being typed into): Delete, Ctrl+D duplicate, F frame selection,
// F2 rename, Escape clear selection, Q W E R tools, Z Pivot/Center, X Global/Local (Unity's
// keys). Ctrl+Z undo and Ctrl+Y / Ctrl+Shift+Z redo work wherever the mouse is, except while
// typing in a field or in the middle of a drag.
//
// Renaming (Unity's two ways): the name box at the top of the Inspector, or F2, which turns the
// active object's Hierarchy row into a text box. Either way the name changes once, when typing
// is applied, so undo records one step per rename (nothing in undo knows about names).
package game

import "core:fmt"
import "core:math/linalg"
import "engine:core"
import "engine:platform"
import "engine:render"
import "engine:ui"

CLICK_MOVE_TOLERANCE_PIXELS :: 4
SELECTION_OUTLINE_COLOR :: [4]f32{1.0, 0.42, 0.0, 1} // Unity's selection orange, linear

Editor_State :: struct {
	click_pending:        bool, // left button went down in the viewport and hasn't moved far
	click_start_position: [2]f32,
	hierarchy_open:       bool,
	create_section_open:  bool,
	transform_section_open: bool,
	active_entity:        Entity_Handle, // selected last; see active_selected_entity
	renaming_entity:      Entity_Handle, // its Hierarchy row is a text box (F2); nil when not renaming
	rename_starting:      bool,          // F2 was just pressed: the row's text box starts typing
	view_gizmo_hovered:   View_Gizmo_Part,
	view_gizmo_hovered_direction: int,
	view_gizmo_pressed:   View_Gizmo_Part, // the left button went down on this part and is still down
	view_gizmo_pressed_direction: int,
	view_gizmo_press_position: [2]f32,
	view_gizmo_dragging:  bool,          // the press moved: orbiting, and no click on release

	// Developer flag --pick-center-of=<name>: once the viewport is laid out, click the pixel
	// where that entity's centre appears, through the normal picking path.
	developer_pick_name_bytes:  [ENTITY_NAME_BYTES]u8,
	developer_pick_name_length: int,
	developer_rename:           bool, // --rename: press F2 once the pick is done
	developer_type_bytes:       [ENTITY_NAME_BYTES]u8, // --rename-type=TEXT: typed once the rename starts
	developer_type_length:      int,
}

// Viewport mouse and keyboard handling. Runs after the UI has claimed what it wants.
// `raw_input` is unfiltered (the gizmo keeps dragging over panels); `input` has the mouse and
// keyboard removed when the UI owns them.
update_editor :: proc(memory: ^Game_Memory, raw_input, input: ^platform.Input, viewport_has_mouse, viewport_has_keyboard: bool) {
	editor := &memory.editor
	scene := &memory.scene
	left_mouse := input.mouse[.Left]
	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down
	ctrl_held := input.keys[.Left_Ctrl].down || input.keys[.Right_Ctrl].down
	shift_held := input.keys[.Left_Shift].down || input.keys[.Right_Shift].down

	// Undo and redo. `input` has no keys while a field is being typed into, and nothing is
	// undone mid-drag. Any edit made earlier this frame is committed first, so it's what gets
	// undone.
	if !edit_in_progress(memory, raw_input) && ctrl_held {
		undo_pressed := input.keys[.Z].pressed && !shift_held
		redo_pressed := input.keys[.Y].pressed || (input.keys[.Z].pressed && shift_held)
		if undo_pressed || redo_pressed {
			commit_undo_step(&memory.undo_history, scene)
			if undo_pressed {
				undo(&memory.undo_history, scene)
			} else {
				redo(&memory.undo_history, scene)
			}
		}
	}

	// The view gizmo goes first (it draws on top), then the transform gizmo: a press on either
	// is theirs, not a selection click. `raw_input` for the view gizmo because the Hand tool
	// turns `input`'s left button into a pan; while the view gizmo has the mouse, the view
	// doesn't get the buttons either.
	gizmo_was_dragging := memory.gizmo.active != .None
	if !gizmo_was_dragging && update_view_gizmo(memory, raw_input, viewport_has_mouse) {
		editor.click_pending = false
		memory.gizmo.hovered = .None
		input.mouse = {}
	} else if update_gizmo(memory, raw_input if gizmo_was_dragging else input, viewport_has_mouse) {
		editor.click_pending = false
		if gizmo_was_dragging {
			return // while dragging, the gizmo owns the mouse and Escape: no clicks or shortcuts
		}
	} else if viewport_has_mouse && left_mouse.pressed && !alt_held {
		// Clicks: Alt + left is orbiting, so only plain (or Shift/Ctrl) clicks select.
		editor.click_pending = true
		editor.click_start_position = input.mouse_position
	}
	if editor.click_pending && linalg.length(input.mouse_position - editor.click_start_position) > CLICK_MOVE_TOLERANCE_PIXELS {
		editor.click_pending = false
	}
	if editor.click_pending && left_mouse.released {
		editor.click_pending = false
		click_in_viewport(memory, input.mouse_position, ctrl_held, shift_held)
	}
	if editor.developer_pick_name_length > 0 && memory.viewport_max != {} {
		developer_pick(memory)
	}
	if editor.developer_rename && editor.developer_pick_name_length == 0 && memory.viewport_max != {} {
		editor.developer_rename = false
		start_rename(memory)
	}

	if !viewport_has_keyboard || input.mouse[.Right].down { // right-drag flying uses WASD/QE
		return
	}
	if input.keys[.Delete].pressed {
		for slot_index in 1 ..= scene.highest_entity_slot {
			if .Selected in scene.entities[slot_index].flags {
				destroy_entity(scene, entity_handle(scene, slot_index))
			}
		}
	}
	if ctrl_held && input.keys[.D].pressed {
		duplicate_selection(scene)
	}
	if input.keys[.F].pressed {
		frame_selection(memory)
	}
	if input.keys[.F2].pressed {
		start_rename(memory)
	}
	if input.keys[.Escape].pressed {
		clear_selection(scene)
	}
	// Unity's tool keys (Ctrl combinations are left for other shortcuts).
	if !ctrl_held {
		if input.keys[.Q].pressed do memory.gizmo.tool = .Hand
		if input.keys[.W].pressed do memory.gizmo.tool = .Move
		if input.keys[.E].pressed do memory.gizmo.tool = .Rotate
		if input.keys[.R].pressed do memory.gizmo.tool = .Scale
		if input.keys[.Z].pressed do toggle_handle_position(&memory.gizmo)
		if input.keys[.X].pressed do memory.gizmo.local_orientation = !memory.gizmo.local_orientation
	}
}

// True while an edit that should become a single undo step is still going on: the left button
// is held (a gizmo or number-field drag), or a field is being typed into.
edit_in_progress :: proc(memory: ^Game_Memory, raw_input: ^platform.Input) -> bool {
	return raw_input.mouse[.Left].down || memory.gizmo.active != .None || ui.wants_keyboard(&memory.user_interface)
}

// Selection change for a click at a window pixel inside the 3D view.
click_in_viewport :: proc(memory: ^Game_Memory, pixel: [2]f32, ctrl_held, shift_held: bool) {
	scene := &memory.scene
	hit_handle, hit := pick_entity(scene, viewport_ray(memory, pixel))
	if !ctrl_held && !shift_held {
		clear_selection(scene)
	}
	if hit {
		entity, _ := get_entity(scene, hit_handle)
		if ctrl_held {
			entity.flags ~= {.Selected} // toggle
		} else {
			entity.flags += {.Selected}
		}
		if .Selected in entity.flags {
			memory.editor.active_entity = hit_handle
		}
	}
}

// The active object: the one selected last, if it's still selected; otherwise the first
// selected one (after Ctrl+D, Delete or undo changed the selection). `found` is false when
// nothing is selected.
active_selected_entity :: proc(memory: ^Game_Memory) -> (handle: Entity_Handle, entity: ^Entity, found: bool) {
	scene := &memory.scene
	if active, active_found := get_entity(scene, memory.editor.active_entity); active_found && .Selected in active.flags {
		return memory.editor.active_entity, active, true
	}
	count, first := selected_count(scene)
	if count == 0 {
		return {}, &scene.entities[0], false
	}
	entity, _ = get_entity(scene, first)
	return first, entity, true
}

// F2: rename the active object in its Hierarchy row. The row turns into a text box on the next
// frame (the Hierarchy is drawn before shortcuts are handled), with the name selected.
start_rename :: proc(memory: ^Game_Memory) {
	handle, _, found := active_selected_entity(memory)
	if !found {
		return
	}
	memory.editor.renaming_entity = handle
	memory.editor.rename_starting = true
	memory.editor.hierarchy_open = true // the row must be visible to type into it
}

// Selects only this entity and makes it the active one (Create, a plain Hierarchy click).
select_only_and_activate :: proc(memory: ^Game_Memory, handle: Entity_Handle) {
	select_only(&memory.scene, handle)
	memory.editor.active_entity = handle
}

// --pick-center-of: project the named entity's centre with the same camera the renderer uses,
// then click there. Checks that picking and rendering agree about where things are on screen.
developer_pick :: proc(memory: ^Game_Memory) {
	editor := &memory.editor
	scene := &memory.scene
	target_name := string(editor.developer_pick_name_bytes[:editor.developer_pick_name_length])
	editor.developer_pick_name_length = 0 // once
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if !(.Alive in entity.flags) || entity_name(entity) != target_name {
			continue
		}
		viewport_size := memory.viewport_max - memory.viewport_min
		view := viewport_camera_view(memory.camera)
		projection := viewport_camera_projection(memory.camera, viewport_size.x / max(viewport_size.y, 1))
		clip := projection * view * [4]f32{entity.position.x, entity.position.y, entity.position.z, 1}
		normalized := clip.xy / clip.w
		pixel := memory.viewport_min + [2]f32{(normalized.x + 1) * 0.5, (1 - normalized.y) * 0.5} * viewport_size
		fmt.printfln("editor: developer pick of %q at pixel %v", target_name, pixel)
		click_in_viewport(memory, pixel, false, false)
		return
	}
	fmt.eprintfln("editor: --pick-center-of found no entity named %q", target_name)
}

// The world-space ray under a window pixel, through the 3D viewport.
viewport_ray :: proc(memory: ^Game_Memory, pixel: [2]f32) -> core.Ray {
	viewport_size := memory.viewport_max - memory.viewport_min
	aspect_ratio := viewport_size.x / max(viewport_size.y, 1)
	normalized := core.viewport_normalized_position(pixel, memory.viewport_min, memory.viewport_max)
	return viewport_camera_ray(memory.camera, aspect_ratio, normalized)
}

// The nearest entity whose mesh the ray hits. Each mesh is tested in its own local space (the
// ray goes through the inverse world matrix), first against its bounding box, then its faces.
pick_entity :: proc(scene: ^Scene, ray: core.Ray) -> (nearest: Entity_Handle, hit: bool) {
	nearest_t := max(f32)
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if !(.Alive in entity.flags) || !(.Has_Mesh in entity.flags) {
			continue
		}
		asset, asset_found := get_mesh_asset(scene, entity.mesh)
		if !asset_found {
			continue
		}
		world := entity_world_matrix(entity)
		if abs(core.linear_determinant(world)) < 1e-12 {
			continue // a zero scale flattens the object: no inverse, and nothing solid to hit
		}
		local_ray := core.ray_transformed(ray, linalg.inverse(world))
		box_t, box_hit := core.ray_box_intersection(local_ray, asset.bounds_min, asset.bounds_max)
		if !box_hit || box_t >= nearest_t {
			continue // can't be closer than what we already have
		}
		t, mesh_hit := core.ray_mesh_intersection(local_ray, asset.geometry)
		if mesh_hit && t < nearest_t {
			nearest_t = t
			nearest = entity_handle(scene, slot_index)
			hit = true
		}
	}
	return
}

clear_selection :: proc(scene: ^Scene) {
	for slot_index in 1 ..= scene.highest_entity_slot {
		scene.entities[slot_index].flags -= {.Selected}
	}
}

select_only :: proc(scene: ^Scene, handle: Entity_Handle) {
	clear_selection(scene)
	if entity, found := get_entity(scene, handle); found {
		entity.flags += {.Selected}
	}
}

selected_count :: proc(scene: ^Scene) -> (count: int, first: Entity_Handle) {
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags && .Selected in entity.flags {
			if count == 0 {
				first = entity_handle(scene, slot_index)
			}
			count += 1
		}
	}
	return
}

// Duplicates every selected entity; the copies become the selection (as in Unity).
duplicate_selection :: proc(scene: ^Scene) {
	originals := make([dynamic]Entity_Handle, context.temp_allocator)
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags && .Selected in entity.flags {
			append(&originals, entity_handle(scene, slot_index))
		}
	}
	clear_selection(scene)
	for original in originals {
		copy_handle := duplicate_entity(scene, original)
		if copy_entity, found := get_entity(scene, copy_handle); found {
			copy_entity.flags += {.Selected}
		}
	}
}

// The world-space box around everything selected: each object's mesh bounds (a unit box for
// objects without a mesh), transformed. `any_selected` is false for an empty selection.
selection_world_bounds :: proc(scene: ^Scene) -> (bounds_min, bounds_max: [3]f32, any_selected: bool) {
	bounds_min = {max(f32), max(f32), max(f32)}
	bounds_max = -bounds_min
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if !(.Alive in entity.flags) || !(.Selected in entity.flags) {
			continue
		}
		asset, has_asset := get_mesh_asset(scene, entity.mesh)
		local_min, local_max := [3]f32{-0.5, -0.5, -0.5}, [3]f32{0.5, 0.5, 0.5}
		if .Has_Mesh in entity.flags && has_asset {
			local_min, local_max = asset.bounds_min, asset.bounds_max
		}
		// World bounds of the eight transformed box corners.
		world := entity_world_matrix(entity)
		for corner_index in 0 ..< 8 {
			corner := [3]f32{
				local_max.x if corner_index & 1 != 0 else local_min.x,
				local_max.y if corner_index & 2 != 0 else local_min.y,
				local_max.z if corner_index & 4 != 0 else local_min.z,
			}
			world_corner := (world * [4]f32{corner.x, corner.y, corner.z, 1}).xyz
			bounds_min = linalg.min(bounds_min, world_corner)
			bounds_max = linalg.max(bounds_max, world_corner)
		}
		any_selected = true
	}
	return
}

// Moves the camera pivot to the selection's centre and backs off until it fits the view.
// With nothing selected, frames the origin.
// Animated, as in Unity. Orbiting afterwards turns around the framed object, because orbiting
// always turns around the pivot.
frame_selection :: proc(memory: ^Game_Memory) {
	target := viewport_camera_target_pose(memory.camera) // keeps a view snap that's under way
	bounds_min, bounds_max, any_selected := selection_world_bounds(&memory.scene)
	if !any_selected {
		target.pivot, target.distance = {0, 0, 0}, 7
		move_viewport_camera(&memory.camera, target)
		return
	}
	radius := max(linalg.length(bounds_max - bounds_min) * 0.5, 0.1)
	target.pivot = (bounds_min + bounds_max) * 0.5
	// Back off until the bounding sphere fits both the vertical and horizontal field of view.
	viewport_size := memory.viewport_max - memory.viewport_min
	aspect_ratio := viewport_size.x / max(viewport_size.y, 1) if viewport_size.x > 0 else 1
	target.distance = core.distance_to_fit_sphere(radius, memory.camera.vertical_fov, aspect_ratio) * 1.1
	move_viewport_camera(&memory.camera, target)
}

// Draws the selected objects' edges in orange, pulled very slightly toward the camera so they
// win the depth test against their own faces. (A true silhouette outline needs a post pass;
// that comes later.)
draw_selection_outlines :: proc(memory: ^Game_Memory, renderer: ^render.Renderer) {
	scene := &memory.scene
	camera := memory.camera
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if !(.Alive in entity.flags) || !(.Selected in entity.flags) || !(.Has_Mesh in entity.flags) {
			continue
		}
		asset, found := get_mesh_asset(scene, entity.mesh)
		if !found {
			continue
		}
		world := entity_world_matrix(entity)
		geometry := asset.geometry
		for face_index in 0 ..< core.face_count(geometry) {
			corners := core.face_corners(geometry, face_index)
			for corner_index in 0 ..< len(corners) {
				start := outline_point(world, geometry.positions[corners[corner_index]], camera)
				end := outline_point(world, geometry.positions[corners[(corner_index + 1) % len(corners)]], camera)
				render.debug_line(renderer, start, end, SELECTION_OUTLINE_COLOR)
			}
		}
	}

	outline_point :: proc(world: matrix[4, 4]f32, local_position: [3]f32, camera: Viewport_Camera) -> [3]f32 {
		world_position := (world * [4]f32{local_position.x, local_position.y, local_position.z, 1}).xyz
		// 0.2% of the distance to the eye, toward the viewer. (Along the view direction in
		// orthographic mode, so the line moves in depth only, not sideways on screen.)
		distance_to_eye := linalg.length(viewport_camera_eye(camera) - world_position)
		return world_position + viewport_camera_toward_viewer(camera, world_position) * distance_to_eye * 0.002
	}
}

// --- Panels -------------------------------------------------------------------------------

draw_hierarchy_panel :: proc(memory: ^Game_Memory, input: ^platform.Input) {
	user_interface := &memory.user_interface
	scene := &memory.scene
	editor := &memory.editor
	// The panel closes itself when this block ends (a deferred call), so everything inside the
	// panel must be inside the block.
	if ui.panel(user_interface, "Hierarchy", 240) {
		if ui.section(user_interface, "Create", &editor.create_section_open) {
			spawn_position := memory.camera.pivot
			if ui.row(user_interface, "first row") {
				if ui.button(user_interface, "Cube") {
					select_only_and_activate(memory, create_primitive_entity(scene, .Cube, spawn_position, {0.8, 0.8, 0.82}))
				}
				if ui.button(user_interface, "Sphere") {
					select_only_and_activate(memory, create_primitive_entity(scene, .Sphere, spawn_position, {0.8, 0.8, 0.82}))
				}
			}
			if ui.row(user_interface, "second row") {
				if ui.button(user_interface, "Cylinder") {
					select_only_and_activate(memory, create_primitive_entity(scene, .Cylinder, spawn_position, {0.8, 0.8, 0.82}))
				}
				if ui.button(user_interface, "Plane") {
					select_only_and_activate(memory, create_primitive_entity(scene, .Plane, {spawn_position.x, 0, spawn_position.z}, {0.5, 0.52, 0.55}))
				}
			}
		}

		if ui.section(user_interface, "Scene", &editor.hierarchy_open) {
			ctrl_held := input.keys[.Left_Ctrl].down || input.keys[.Right_Ctrl].down
			shift_held := input.keys[.Left_Shift].down || input.keys[.Right_Shift].down
			for slot_index in 1 ..= scene.highest_entity_slot {
				entity := &scene.entities[slot_index]
				if !(.Alive in entity.flags) {
					continue
				}
				handle := entity_handle(scene, slot_index)
				if handle == editor.renaming_entity {
					// F2 renaming: this row is a text box until typing is applied or cancelled.
					new_name, result := ui.text_box(user_interface, "rename", entity_name(entity), ENTITY_NAME_BYTES, start_editing = editor.rename_starting)
					editor.rename_starting = false
					if result == .Applied {
						set_entity_name(entity, new_name)
					}
					if result != .Editing {
						editor.renaming_entity = {}
					}
					continue
				}
				interaction := ui.selectable(user_interface, entity_name(entity), .Selected in entity.flags, u32(slot_index))
				if interaction.clicked {
					if ctrl_held {
						entity.flags ~= {.Selected}
					} else if shift_held {
						entity.flags += {.Selected}
					} else {
						select_only(scene, entity_handle(scene, slot_index))
					}
					if .Selected in entity.flags {
						memory.editor.active_entity = entity_handle(scene, slot_index)
					}
				}
			}
		}
	}
}

// The selected object's properties, generated from the Entity struct's `inspect` tags.
draw_selection_inspector :: proc(memory: ^Game_Memory) {
	user_interface := &memory.user_interface
	scene := &memory.scene
	count, first := selected_count(scene)
	switch {
	case count == 0:
		ui.label(user_interface, "Nothing selected. Click an object, or pick one in the Hierarchy.", .Regular)
	case count == 1:
		entity, _ := get_entity(scene, first)
		// The name, editable in place as in Unity's Inspector header.
		if new_name, result := ui.text_box(user_interface, "Name", entity_name(entity), ENTITY_NAME_BYTES, .Semibold); result == .Applied {
			set_entity_name(entity, new_name)
		}
		if ui.section(user_interface, "Transform", &memory.editor.transform_section_open) {
			ui.inspect(user_interface, entity, Entity)
		}
	case:
		ui.label(user_interface, fmt.tprintf("%d objects selected", count), .Semibold)
		ui.label(user_interface, "Editing several objects at once comes later.", .Regular)
	}
}
