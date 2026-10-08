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
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:unicode"
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
	generation:   u32,
	flags:        bit_set[Entity_Flag; u32],
	name_bytes:   [ENTITY_NAME_BYTES]u8,
	name_length:  u8,
	// Permanent identity, saved in scene files (#36). Handles are runtime-only: loading a scene
	// gives every entity a fresh one. What's saved refers to an entity by its id instead. Random
	// (never 0), so ids made by two people editing a scene in parallel don't clash.
	id:           u64,
	// Place in the Hierarchy: a core order key ("a0", "a1", ...). Entities sort by (key, id).
	order_bytes:  [core.ORDER_KEY_MAX_BYTES]u8,
	order_length: u8,

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
		order_buffer: [core.ORDER_KEY_MAX_BYTES]u8
		order_key := order_key_after_last(scene, order_buffer[:])
		scene.slot_generations[slot_index] += 1
		generation := scene.slot_generations[slot_index]
		entity^ = {generation = generation, flags = {.Alive}, id = new_entity_id(), scale = {1, 1, 1}, color = {0.8, 0.8, 0.8}}
		set_entity_name(entity, name)
		set_entity_order_key(entity, order_key)
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

// A new random id. Two random 64-bit ids are the same with probability 2^-64; across a scene of
// MAX_ENTITIES that's about 4096^2 / 2^65, or 5e-13 (the birthday bound), so they aren't checked
// here. Loading refuses a scene with two equal ids, which hand-copied files can produce.
new_entity_id :: proc() -> u64 {
	for {
		if id := rand.uint64(); id != 0 {
			return id
		}
	}
}

entity_order_key :: proc(entity: ^Entity) -> string {
	return string(entity.order_bytes[:entity.order_length])
}

// The unused tail is cleared, as for names, so equal keys give equal bytes for undo.
set_entity_order_key :: proc(entity: ^Entity, key: string) {
	ensure(len(key) <= core.ORDER_KEY_MAX_BYTES, "order key longer than its buffer")
	entity.order_bytes = {}
	entity.order_length = u8(copy(entity.order_bytes[:], key))
}

// Hierarchy order: by order key, then by id when two keys are equal (two people can give
// entities the same key in parallel), so the order never depends on slots. Used for entities
// and for entity records read from files.
order_comes_before :: proc(first_key: string, first_id: u64, second_key: string, second_id: u64) -> bool {
	if first_key != second_key {
		return first_key < second_key
	}
	return first_id < second_id
}

// The key for a new entity at the end of the Hierarchy, written into `buffer`. New entities
// always go last, even into a slot freed by a delete. Only an absurdly long last key (from a
// hand-edited file) leaves no room after it; then every entity gets a short key again, in the
// current order, which changes more entities but keeps the order.
order_key_after_last :: proc(scene: ^Scene, buffer: []u8) -> string {
	last := ""
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags && entity_order_key(entity) > last {
			last = entity_order_key(entity)
		}
	}
	if key, ok := core.order_key_after(buffer, last); ok {
		return key
	}
	last = renumber_order_keys(scene)
	key, ok := core.order_key_after(buffer, last)
	ensure(ok, "a renumbered key always has room after it")
	return key
}

// Gives every alive entity a fresh key ("a0", "a1", ...) in its current Hierarchy order.
// Returns the last key given (pointing into that entity), or "" for an empty scene.
renumber_order_keys :: proc(scene: ^Scene) -> string {
	Order_Item :: struct {
		slot_index: int,
		key:        string,
		id:         u64,
	}
	items := make([dynamic]Order_Item, context.temp_allocator)
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags {
			append(&items, Order_Item{slot_index, entity_order_key(entity), entity.id})
		}
	}
	slice.sort_by(items[:], proc(first, second: Order_Item) -> bool {
		return order_comes_before(first.key, first.id, second.key, second.id)
	})
	buffer: [core.ORDER_KEY_MAX_BYTES]u8
	last := ""
	for item in items {
		entity := &scene.entities[item.slot_index]
		key, ok := core.order_key_after(buffer[:], last)
		ensure(ok, "keys counted up from \"a0\" are short")
		set_entity_order_key(entity, key)
		last = entity_order_key(entity)
	}
	return last
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
//
// One pass over the scene marks which numbers are taken (0 is the name without a suffix), then
// the smallest free one is used. Testing each candidate against the whole scene in turn would
// cost a scan per candidate: with a thousand "Cube (N)" objects, about a million name
// comparisons, every frame while the rename box checks a taken name (found in review of #24).
unique_entity_name :: proc(scene: ^Scene, requested_name: string, excluding: Entity_Handle = {}) -> string {
	base_name := strip_number_suffix(requested_name)
	// Fewer than MAX_ENTITIES other entities can take fewer than MAX_ENTITIES numbers, so one
	// below MAX_ENTITIES is always free.
	taken: [MAX_ENTITIES]bool
	unsuffixed := truncate_utf8(base_name, ENTITY_NAME_BYTES)
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if !(.Alive in entity.flags) || slot_index == int(excluding.index) {
			continue
		}
		name := entity_name(entity)
		if name == unsuffixed {
			taken[0] = true
			continue
		}
		// Is this name candidate N? Only if it's written exactly as a candidate would be: digits
		// without a leading zero ("Cube (01)" isn't "Cube (1)"), after the base shortened for
		// that suffix's length.
		name_base := strip_number_suffix(name)
		if name_base == name {
			continue
		}
		digits := name[len(name_base) + 2:len(name) - 1] // between " (" and ")"
		if len(digits) > 4 || digits[0] == '0' { // MAX_ENTITIES has 4 digits
			continue
		}
		number := 0
		for digit in digits {
			number = number * 10 + int(digit - '0')
		}
		suffix_length := len(digits) + 3 // " (" and ")"
		if number < MAX_ENTITIES && name_base == truncate_utf8(base_name, ENTITY_NAME_BYTES - suffix_length) {
			taken[number] = true
		}
	}
	for number in 0 ..< MAX_ENTITIES {
		if !taken[number] {
			suffix := fmt.tprintf(" (%d)", number) if number > 0 else ""
			return fmt.tprintf("%s%s", truncate_utf8(base_name, ENTITY_NAME_BYTES - len(suffix)), suffix)
		}
	}
	unreachable()
}

// Names: letters (any script), digits, spaces and _ - . ( ). Kept to these so a name can later
// be part of a file name or a reference typed by hand, on any system.
NAME_PUNCTUATION :: "_-.()"

name_character_allowed :: proc(character: rune) -> bool {
	return unicode.is_letter(character) || unicode.is_digit(character) || character == ' ' || strings.contains_rune(NAME_PUNCTUATION, character)
}

// Combining marks are part of written letters: the vowel sign in Hindi "किरण" (a spacing mark),
// or the accent in "Café" typed as "e" plus U+0301 (a nonspacing mark). Unicode's identifier
// rules (UAX #31) allow these two kinds after the first character, and so do we; a mark at the
// start has no letter to belong to.
name_mark_allowed :: proc(character: rune) -> bool {
	return unicode.is_nonspacing_mark(character) || unicode.is_spacing_mark(character)
}

// What renaming `entity` to `typed` would do. Spaces at either end are dropped. A name that's
// empty or has a character outside name_character_allowed (and name_mark_allowed after the
// first) can't be used: `blocked`, with
// `message` saying why. A name another entity already has gets the next free " (N)", as Create
// and Ctrl+D do: `final_name` is that name, and `message` says so (not blocking). The entity's
// own current name is never "taken". `final_name` and `message` use the temp allocator.
check_entity_name :: proc(scene: ^Scene, entity: Entity_Handle, typed: string) -> (final_name: string, message: string, blocked: bool) {
	trimmed := strings.trim_space(typed)
	if trimmed == "" {
		return "", "A name can't be empty.", true
	}
	for character, byte_index in trimmed {
		if name_character_allowed(character) || (byte_index > 0 && name_mark_allowed(character)) {
			continue
		}
		if name_mark_allowed(character) {
			return "", "A name can't start with a combining mark.", true
		}
		return "", fmt.tprintf("Names can't contain \"%c\". Use letters, digits, spaces and _ - . ( )", character), true
	}
	final_name = truncate_utf8(trimmed, ENTITY_NAME_BYTES)
	if entity_name_in_use(scene, final_name, entity) {
		final_name = unique_entity_name(scene, final_name, entity)
		message = fmt.tprintf("Taken: will be named \"%s\".", final_name)
	}
	return
}

// Whether an entity other than `excluding` has this name.
entity_name_in_use :: proc(scene: ^Scene, name: string, excluding: Entity_Handle = {}) -> bool {
	for slot_index in 1 ..= scene.highest_entity_slot {
		entity := &scene.entities[slot_index]
		if .Alive in entity.flags && slot_index != int(excluding.index) && entity_name(entity) == name {
			return true
		}
	}
	return false
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

// Copies an entity (same mesh, transform, color) under a new unique name. The copy is a new
// entity: it gets its own id and goes last in the Hierarchy.
duplicate_entity :: proc(scene: ^Scene, source_handle: Entity_Handle) -> Entity_Handle {
	source, found := get_entity(scene, source_handle)
	if !found {
		return {}
	}
	copy_of_source := source^ // copy before create_entity, which may reuse memory nearby
	handle, entity := create_entity(scene, unique_entity_name(scene, entity_name(&copy_of_source)))
	fresh := entity^ // the identity create_entity gave the copy
	entity^ = copy_of_source
	entity.generation = fresh.generation
	entity.id = fresh.id
	entity.name_bytes, entity.name_length = fresh.name_bytes, fresh.name_length
	entity.order_bytes, entity.order_length = fresh.order_bytes, fresh.order_length
	entity.flags -= {.Selected}
	return handle
}
