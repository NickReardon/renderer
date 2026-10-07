// The scene: entities and the mesh data they share.
//
// Entities follow the hybrid fat-struct model (docs/STYLE.md §15, docs/ENTITIES.md):
//   - one `Entity` struct with every field any object may need, in a fixed pool;
//   - referred to by `Entity_Handle { index, generation }`; slot 0 is the nil entity, so a zero
//     handle means "none" and looking up a stale handle returns the nil entity, never garbage;
//   - optional fields belong to a flag (`.Has_Mesh`) and are only read when it's set;
//   - large or shared data lives behind handles: entities point at a Mesh_Asset, so many
//     objects can share one mesh (Blender's Object/data split).
//
// Mesh assets keep the CPU geometry (core.Mesh, used for picking, outlines and later editing)
// next to the GPU copy the renderer draws.
package game

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "engine:core"
import "engine:render"

MAX_ENTITIES       :: 4096
MAX_MESH_ASSETS    :: 256
ENTITY_NAME_BYTES  :: 48
ENTITY_SIZE_BUDGET :: 512 // raising it is a design decision: record why in docs/DESIGN.md

Entity_Handle :: struct {
	index:      u32,
	generation: u32,
}

Mesh_Asset_Handle :: struct {
	index:      u32,
	generation: u32,
}

Entity_Flag :: enum u8 {
	Alive,
	Selected,
	Has_Mesh, // mesh, color
}

Entity :: struct {
	generation:  u32,
	flags:       bit_set[Entity_Flag; u32],
	name_bytes:  [ENTITY_NAME_BYTES]u8,
	name_length: u8,

	// Transform, on every entity. Rotation is Euler angles in degrees, applied Z first, then X,
	// then Y (Unity's order), so values match what Unity users expect.
	position:    [3]f32 `inspect:"Position" step:"0.01" format:"%.2f"`,
	rotation:    [3]f32 `inspect:"Rotation" step:"0.5" format:"%.1f°"`,
	scale:       [3]f32 `inspect:"Scale" step:"0.005" format:"%.2f"`,

	// .Has_Mesh
	mesh:        Mesh_Asset_Handle,
	color:       [3]f32 `inspect:"Color" hint:"color"`, // linear RGB
}
#assert(size_of(Entity) <= ENTITY_SIZE_BUDGET)

Primitive_Kind :: enum {
	Cube,
	Sphere,
	Cylinder,
	Plane,
}

PRIMITIVE_NAMES :: [Primitive_Kind]string{
	.Cube     = "Cube",
	.Sphere   = "Sphere",
	.Cylinder = "Cylinder",
	.Plane    = "Plane",
}

Mesh_Asset :: struct {
	generation: u32,
	alive:      bool,
	geometry:   core.Mesh, // allocated with the host's allocator; freed by scene_shutdown
	gpu_mesh:   render.Mesh_Handle,
	bounds_min: [3]f32,
	bounds_max: [3]f32,
}

Scene :: struct {
	entities:            [MAX_ENTITIES]Entity, // slot 0 is the nil entity
	highest_entity_slot: int,                  // loops run over 1 ..= highest_entity_slot
	// The highest generation each slot has ever had. New entities count up from it, never from
	// the slot's current entity: undo can bring back an entity with an older generation, and a
	// handle must still never be reused for a different entity.
	slot_generations:    [MAX_ENTITIES]u32,
	mesh_assets:         [MAX_MESH_ASSETS]Mesh_Asset, // slot 0 unused
	primitive_meshes:    [Primitive_Kind]Mesh_Asset_Handle,
}

scene_init :: proc(scene: ^Scene, renderer: ^render.Renderer) {
	// Sizes match Unity's primitives: unit cube, 1-unit-diameter sphere, 2-unit-tall cylinder,
	// 10 x 10 plane.
	scene.primitive_meshes[.Cube] = create_mesh_asset(scene, renderer, core.make_cube(1))
	scene.primitive_meshes[.Sphere] = create_mesh_asset(scene, renderer, core.make_uv_sphere(0.5, 32, 16))
	scene.primitive_meshes[.Cylinder] = create_mesh_asset(scene, renderer, core.make_cylinder(0.5, 2, 32))
	scene.primitive_meshes[.Plane] = create_mesh_asset(scene, renderer, core.make_plane(10, 10))
}

scene_shutdown :: proc(scene: ^Scene) {
	for &asset in scene.mesh_assets {
		if asset.alive {
			core.mesh_destroy(&asset.geometry)
		}
	}
	// GPU meshes are released with the renderer.
}

// Takes ownership of `geometry` and uploads a flat-shaded copy to the GPU.
create_mesh_asset :: proc(scene: ^Scene, renderer: ^render.Renderer, geometry: core.Mesh) -> Mesh_Asset_Handle {
	for slot_index in 1 ..< MAX_MESH_ASSETS {
		asset := &scene.mesh_assets[slot_index]
		if asset.alive {
			continue
		}
		positions, normals, indices := core.flat_shaded_triangles(geometry, context.temp_allocator)
		asset.generation += 1
		asset.alive = true
		asset.geometry = geometry
		asset.gpu_mesh = render.create_mesh(renderer, positions, normals, indices)
		asset.bounds_min, asset.bounds_max = core.mesh_bounds(geometry)
		return {index = u32(slot_index), generation = asset.generation}
	}
	fmt.eprintln("game: out of mesh asset slots, raise MAX_MESH_ASSETS")
	return {}
}

get_mesh_asset :: proc(scene: ^Scene, handle: Mesh_Asset_Handle) -> (^Mesh_Asset, bool) {
	if handle.index == 0 || handle.index >= MAX_MESH_ASSETS {
		return nil, false
	}
	asset := &scene.mesh_assets[handle.index]
	if !asset.alive || asset.generation != handle.generation {
		return nil, false
	}
	return asset, true
}

// Returns the new entity, already alive with an identity transform, or the nil entity if the
// pool is full.
create_entity :: proc(scene: ^Scene, name: string) -> (Entity_Handle, ^Entity) {
	for slot_index in 1 ..< MAX_ENTITIES {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags {
			continue
		}
		scene.slot_generations[slot_index] += 1
		generation := scene.slot_generations[slot_index]
		entity^ = {generation = generation, flags = {.Alive}, scale = {1, 1, 1}, color = {0.8, 0.8, 0.8}}
		set_entity_name(entity, name)
		scene.highest_entity_slot = max(scene.highest_entity_slot, slot_index)
		return {index = u32(slot_index), generation = generation}, entity
	}
	fmt.eprintln("game: out of entity slots, raise MAX_ENTITIES")
	return {}, &scene.entities[0]
}

destroy_entity :: proc(scene: ^Scene, handle: Entity_Handle) {
	entity, found := get_entity(scene, handle)
	if !found {
		return
	}
	entity^ = {generation = entity.generation} // keep the generation so old handles stay invalid
}

// A stale or zero handle gives the nil entity (slot 0, never alive) and false.
get_entity :: proc(scene: ^Scene, handle: Entity_Handle) -> (^Entity, bool) {
	if handle.index == 0 || handle.index >= MAX_ENTITIES {
		return &scene.entities[0], false
	}
	entity := &scene.entities[handle.index]
	if !(.Alive in entity.flags) || entity.generation != handle.generation {
		return &scene.entities[0], false
	}
	return entity, true
}

entity_handle :: proc(scene: ^Scene, slot_index: int) -> Entity_Handle {
	return {index = u32(slot_index), generation = scene.entities[slot_index].generation}
}

entity_name :: proc(entity: ^Entity) -> string {
	return string(entity.name_bytes[:entity.name_length])
}

// Names are any UTF-8 text up to ENTITY_NAME_BYTES (longer names are cut at a character
// boundary). Several entities may share a name, as in Unity. The unused tail of the buffer is
// cleared so an entity's bytes depend only on its name (undo compares entities byte for byte).
set_entity_name :: proc(entity: ^Entity, name: string) {
	entity.name_bytes = {}
	entity.name_length = u8(copy(entity.name_bytes[:], truncate_utf8(name, ENTITY_NAME_BYTES)))
}

// World matrix: scale, then rotate (Z, X, Y), then translate.
entity_world_matrix :: proc(entity: ^Entity) -> matrix[4, 4]f32 {
	return linalg.matrix4_translate_f32(entity.position) * core.euler_rotation_matrix(entity.rotation) * linalg.matrix4_scale_f32(entity.scale)
}

// A name not used by any other entity: "Cube", then "Cube (1)", "Cube (2)", ... as in Unity.
// An existing " (N)" suffix is dropped first, so duplicating "Cube (3)" gives "Cube (4)", not
// "Cube (3) (1)". Every candidate is built to fit the 48-byte name buffer (the base is shortened
// to leave room for the suffix), so uniqueness is checked on the name exactly as it will be
// stored.
unique_entity_name :: proc(scene: ^Scene, requested_name: string) -> string {
	name_in_use :: proc(scene: ^Scene, name: string) -> bool {
		for slot_index in 1 ..= scene.highest_entity_slot {
			entity := &scene.entities[slot_index]
			if .Alive in entity.flags && entity_name(entity) == name {
				return true
			}
		}
		return false
	}
	base_name := strip_number_suffix(requested_name)
	for number := 0; ; number += 1 {
		suffix := fmt.tprintf(" (%d)", number) if number > 0 else ""
		candidate := fmt.tprintf("%s%s", truncate_utf8(base_name, ENTITY_NAME_BYTES - len(suffix)), suffix)
		if !name_in_use(scene, candidate) {
			return candidate
		}
	}
}

// "Cube (12)" -> "Cube"; anything else is returned unchanged.
strip_number_suffix :: proc(name: string) -> string {
	if !strings.has_suffix(name, ")") {
		return name
	}
	opening := strings.last_index(name, " (")
	if opening < 0 {
		return name
	}
	digits := name[opening + 2:len(name) - 1]
	if len(digits) == 0 {
		return name
	}
	for character in digits {
		if character < '0' || character > '9' {
			return name
		}
	}
	return name[:opening]
}

// The longest prefix of `text` that fits in `maximum_bytes` without splitting a UTF-8 character.
truncate_utf8 :: proc(text: string, maximum_bytes: int) -> string {
	if len(text) <= maximum_bytes {
		return text
	}
	end := max(maximum_bytes, 0)
	for end > 0 && (text[end] & 0xC0) == 0x80 { // continuation byte: step back to a character start
		end -= 1
	}
	return text[:end]
}

create_primitive_entity :: proc(scene: ^Scene, kind: Primitive_Kind, position: [3]f32, color: [3]f32) -> Entity_Handle {
	primitive_names := PRIMITIVE_NAMES
	handle, entity := create_entity(scene, unique_entity_name(scene, primitive_names[kind]))
	entity.flags += {.Has_Mesh}
	entity.mesh = scene.primitive_meshes[kind]
	entity.position = position
	entity.color = color
	return handle
}

// Copies an entity (same mesh, transform, color) under a new unique name.
duplicate_entity :: proc(scene: ^Scene, source_handle: Entity_Handle) -> Entity_Handle {
	source, found := get_entity(scene, source_handle)
	if !found {
		return {}
	}
	copy_of_source := source^ // copy before create_entity, which may reuse memory nearby
	handle, entity := create_entity(scene, unique_entity_name(scene, entity_name(&copy_of_source)))
	generation, name_bytes, name_length := entity.generation, entity.name_bytes, entity.name_length
	entity^ = copy_of_source
	entity.generation, entity.name_bytes, entity.name_length = generation, name_bytes, name_length
	entity.flags -= {.Selected}
	return handle
}
