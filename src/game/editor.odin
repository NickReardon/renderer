// The editor: selection, picking, the Hierarchy and Inspector panels, and shortcuts.
//
// Selection is a flag on each entity (`.Selected`) rather than a separate list: the editor's
// loops already walk the entity pool, and a flag can't go stale when an entity is deleted.
//
// Viewport clicks (Unity's rules):
//   click                select the object under the mouse; clicking empty space clears
//   Shift + click        add to the selection
//   Ctrl + click         toggle the object in or out of the selection
// A press only counts as a click if the mouse moved less than a few pixels before release, so
// it never fights with dragging.
//
// Shortcuts (when the 3D view has the keyboard): Delete, Ctrl+D duplicate, F frame selection,
// Escape clear selection.
package game

import "core:fmt"
import "core:math"
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

	// Developer flag --pick-center-of=<name>: once the viewport is laid out, click the pixel
	// where that entity's centre appears, through the normal picking path.
	developer_pick_name_bytes:  [ENTITY_NAME_BYTES]u8,
	developer_pick_name_length: int,
}

// Viewport mouse and keyboard handling. Runs after the UI has claimed what it wants.
update_editor :: proc(memory: ^Game_Memory, input: ^platform.Input, viewport_has_mouse, viewport_has_keyboard: bool) {
	editor := &memory.editor
	scene := &memory.scene
	left_mouse := input.mouse[.Left]
	alt_held := input.keys[.Left_Alt].down || input.keys[.Right_Alt].down
	ctrl_held := input.keys[.Left_Ctrl].down || input.keys[.Right_Ctrl].down
	shift_held := input.keys[.Left_Shift].down || input.keys[.Right_Shift].down

	// Clicks: Alt + left is orbiting, so only plain (or Shift/Ctrl) clicks select.
	if viewport_has_mouse && left_mouse.pressed && !alt_held {
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
	if input.keys[.Escape].pressed {
		clear_selection(scene)
	}
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
	}
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
		eye := viewport_camera_eye(memory.camera)
		view := core.look_at(eye, memory.camera.pivot, core.WORLD_UP)
		projection := core.perspective_reverse_z(memory.camera.vertical_fov, viewport_size.x / max(viewport_size.y, 1), 0.05)
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
	camera := memory.camera
	return core.ray_from_viewport(viewport_camera_eye(camera), camera.pivot, core.WORLD_UP, camera.vertical_fov, aspect_ratio, normalized)
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
		local_ray := core.ray_transformed(ray, linalg.inverse(entity_world_matrix(entity)))
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

// Moves the camera pivot to the selection's centre and backs off until it fits the view.
// With nothing selected, frames the origin.
frame_selection :: proc(memory: ^Game_Memory) {
	scene := &memory.scene
	bounds_min := [3]f32{max(f32), max(f32), max(f32)}
	bounds_max := -bounds_min
	any_selected := false
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
	if !any_selected {
		memory.camera.pivot = {0, 0, 0}
		memory.camera.distance = 7
		return
	}
	center := (bounds_min + bounds_max) * 0.5
	radius := max(linalg.length(bounds_max - bounds_min) * 0.5, 0.1)
	memory.camera.pivot = center
	// Distance at which a sphere of this radius fills the vertical field of view, plus margin.
	memory.camera.distance = radius / math.sin(memory.camera.vertical_fov * 0.5) * 1.15
}

// Draws the selected objects' edges in orange, pulled very slightly toward the camera so they
// win the depth test against their own faces. (A true silhouette outline needs a post pass;
// that comes later.)
draw_selection_outlines :: proc(memory: ^Game_Memory, renderer: ^render.Renderer) {
	scene := &memory.scene
	eye := viewport_camera_eye(memory.camera)
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
				start := outline_point(world, geometry.positions[corners[corner_index]], eye)
				end := outline_point(world, geometry.positions[corners[(corner_index + 1) % len(corners)]], eye)
				render.debug_line(renderer, start, end, SELECTION_OUTLINE_COLOR)
			}
		}
	}

	outline_point :: proc(world: matrix[4, 4]f32, local_position: [3]f32, eye: [3]f32) -> [3]f32 {
		world_position := (world * [4]f32{local_position.x, local_position.y, local_position.z, 1}).xyz
		to_eye := eye - world_position
		return world_position + to_eye * 0.002 // 0.2% of the way to the camera
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
					select_only(scene, create_primitive_entity(scene, .Cube, spawn_position, {0.8, 0.8, 0.82}))
				}
				if ui.button(user_interface, "Sphere") {
					select_only(scene, create_primitive_entity(scene, .Sphere, spawn_position, {0.8, 0.8, 0.82}))
				}
			}
			if ui.row(user_interface, "second row") {
				if ui.button(user_interface, "Cylinder") {
					select_only(scene, create_primitive_entity(scene, .Cylinder, spawn_position, {0.8, 0.8, 0.82}))
				}
				if ui.button(user_interface, "Plane") {
					select_only(scene, create_primitive_entity(scene, .Plane, {spawn_position.x, 0, spawn_position.z}, {0.5, 0.52, 0.55}))
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
				interaction := ui.selectable(user_interface, entity_name(entity), .Selected in entity.flags, u32(slot_index))
				if interaction.clicked {
					if ctrl_held {
						entity.flags ~= {.Selected}
					} else if shift_held {
						entity.flags += {.Selected}
					} else {
						select_only(scene, entity_handle(scene, slot_index))
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
		ui.label(user_interface, entity_name(entity), .Semibold)
		if ui.section(user_interface, "Transform", &memory.editor.transform_section_open) {
			ui.inspect(user_interface, entity, Entity)
		}
	case:
		ui.label(user_interface, fmt.tprintf("%d objects selected", count), .Semibold)
		ui.label(user_interface, "Editing several objects at once comes later.", .Regular)
	}
}
