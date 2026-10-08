// Scene files (#36): what is saved about a scene, and the text it's saved as.
//
// A scene is a folder: a scene file, plus one file per entity in `entities/`, named after the
// entity's id. There's no list of the entities anywhere, so adding or removing one touches only
// its own file, and people (or agents) can edit different entities in parallel. This file turns
// entity files into records and records back into text. Reading and writing the files on disk
// comes in #50 (saving) and #51 (loading).
//
// Records, not entities: a file is read into an Entity_Record, never straight into Entity, so
// runtime state (generations, selection, handles) never reaches the disk, and renaming a field
// in Entity can't break old files.
//
// The text is SJSON, Bitsquid's simplified JSON (see REFERENCES.md): keys without quotes, `=`
// between key and value, optional commas, `//` and `/* */` comments, and no braces around the
// file. Plain JSON is accepted too (quoted keys, `:`, braces), so nothing written as ordinary
// JSON is rejected.
//
// Our own reader and writer, on Odin's JSON tokenizer:
//   - reading: `json.unmarshal` silently skips keys it doesn't know, so a typo ("postion") would
//     vanish, and its parse tree keeps no positions. Ours refuses unknown keys, and every error
//     names its file and line, which is what someone (or an agent) fixing a hand edit needs;
//   - the tokenizer counts lines wrong in SJSON mode: a newline it turns into a comma, and the
//     newline ending a `//` comment, are consumed without being counted. So lines are counted
//     here from each token's byte offset;
//   - writing: `json.marshal` writes f32 with a fixed 8 decimals (`0.5` as `0.50000000`, and
//     `1e-9` as `0.00000000`, which loses the value). Ours writes the shortest text that reads
//     back as the same f32, so values survive exactly and unchanged entities save identical
//     bytes.
package game

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "engine:core"

// Placeholders until the engine has a name (#36). Defined only here, so renaming them is one
// change.
PROJECT_FILE_EXTENSION :: ".project"
SCENE_FILE_EXTENSION   :: ".scene"
ENTITY_FILE_EXTENSION  :: ".entity"

// Raised when what's saved changes. Older versions are upgraded when read (none exist yet);
// newer ones are refused, since this editor can't know what their keys mean.
ENTITY_FILE_VERSION :: 1
SCENE_FILE_VERSION  :: 1

DEFAULT_ENTITY_COLOR :: [3]f32{0.8, 0.8, 0.8}

// The saved fields of one entity. Its strings belong to whoever made the record: the reader's
// allocator, or the entity, for entity_record_from_entity.
Entity_Record :: struct {
	id:        u64,
	name:      string,
	order:     string, // a core order key
	position:  [3]f32,
	rotation:  [3]f32, // Euler degrees, as in Entity
	scale:     [3]f32,
	has_mesh:  bool,   // primitive, color
	primitive: Primitive_Kind,
	color:     [3]f32,
	// What reading changed compared with the file. Any fix means the file on disk is out of
	// date, so the scene starts out with unsaved changes (#36's "pending" state).
	fixes:     bit_set[Record_Fix],
}

Record_Fix :: enum u8 {
	New_Id,    // the file had no id, so one was made
	New_Order, // the file had no order key, so the entity was placed last
	Renamed,   // another entity had the same name
}

// One entity file's name (with its extension, without a folder) and contents.
Entity_File :: struct {
	name: string,
	text: string,
}

// What's wrong with a file, for the user: `file:line: key: message`. `line` is 0 when the
// problem isn't on one line (a missing key, two files with the same id); `key` is "" when no key
// is involved (a syntax error).
File_Error :: struct {
	file_name: string,
	line:      int,
	key:       string, // a path: "mesh.primitive", "position[1]"
	message:   string,
}

file_error_text :: proc(error: File_Error, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, error.file_name)
	if error.line > 0 {
		fmt.sbprintf(&builder, ":%d", error.line)
	}
	strings.write_string(&builder, ": ")
	if error.key != "" {
		fmt.sbprintf(&builder, "%s: ", error.key)
	}
	strings.write_string(&builder, error.message)
	return strings.to_string(builder)
}

// All of an error's strings are copied to `allocator`, so callers can build messages with the
// temp allocator.
@(private = "file")
make_file_error :: proc(file_name: string, line: int, key: string, message: string, allocator: runtime.Allocator) -> File_Error {
	return {
		file_name = strings.clone(file_name, allocator),
		line      = line,
		key       = strings.clone(key, allocator),
		message   = strings.clone(message, allocator),
	}
}

// ---------------------------------------------------------------------------------------------
// Entity records <-> entities

// The saved fields of `entity`. The record's strings point into the entity, so they're valid
// until it changes. Fails for a mesh that isn't one of the primitives; none exist yet, and
// imported meshes get their own kind of reference in #43.
entity_record_from_entity :: proc(scene: ^Scene, entity: ^Entity) -> (record: Entity_Record, ok: bool) {
	record = {
		id       = entity.id,
		name     = entity_name(entity),
		order    = entity_order_key(entity),
		position = entity.position,
		rotation = entity.rotation,
		scale    = entity.scale,
		color    = DEFAULT_ENTITY_COLOR,
	}
	if .Has_Mesh in entity.flags {
		for mesh_handle, kind in scene.primitive_meshes {
			if mesh_handle == entity.mesh {
				record.has_mesh, record.primitive, record.color = true, kind, entity.color
				return record, true
			}
		}
		return record, false
	}
	return record, true
}

// Sets `entity`'s saved fields from `record`; runtime state (generation, selection) is left as
// it is. The record must be valid: from read_entity_files, or from an entity.
apply_entity_record :: proc(scene: ^Scene, entity: ^Entity, record: Entity_Record) {
	entity.id = record.id
	set_entity_name(entity, record.name)
	set_entity_order_key(entity, record.order)
	entity.position, entity.rotation, entity.scale = record.position, record.rotation, record.scale
	if record.has_mesh {
		entity.flags += {.Has_Mesh}
		entity.mesh = scene.primitive_meshes[record.primitive]
		entity.color = record.color
	} else {
		entity.flags -= {.Has_Mesh}
		entity.mesh = {}
		entity.color = DEFAULT_ENTITY_COLOR
	}
}

// The file name an entity is saved under: its id, which never changes, so a save never renames
// a file (#36). The name isn't in it; find an entity's file with
// `grep -l 'name = "Cube"' entities/`.
entity_file_name :: proc(id: u64, allocator := context.allocator) -> string {
	return fmt.aprintf("%016x%s", id, ENTITY_FILE_EXTENSION, allocator = allocator)
}

// ---------------------------------------------------------------------------------------------
// Writing

// Appends an entity file's text. The same record always gives the same bytes: keys in a fixed
// order, floats in their shortest exact form, LF line endings, four-space indents.
write_entity_file :: proc(builder: ^strings.Builder, record: Entity_Record) {
	assert(record.id != 0 && core.order_key_is_valid(record.order), "write_entity_file needs a valid record")
	primitive_names := PRIMITIVE_NAMES
	fmt.sbprintf(builder, "type = \"entity\"\nversion = %d\nid = \"%016x\"\n", ENTITY_FILE_VERSION, record.id)
	strings.write_string(builder, "name = ")
	write_sjson_string(builder, record.name)
	strings.write_string(builder, "\norder = ")
	write_sjson_string(builder, record.order)
	strings.write_string(builder, "\nposition = ")
	write_sjson_vector(builder, record.position)
	strings.write_string(builder, "\nrotation = ")
	write_sjson_vector(builder, record.rotation)
	strings.write_string(builder, "\nscale = ")
	write_sjson_vector(builder, record.scale)
	strings.write_string(builder, "\n")
	if record.has_mesh {
		strings.write_string(builder, "mesh = {\n    primitive = ")
		write_sjson_string(builder, primitive_names[record.primitive])
		strings.write_string(builder, "\n    color = ")
		write_sjson_vector(builder, record.color)
		strings.write_string(builder, "\n}\n")
	}
}

// The scene file holds only its type and version so far; scene-wide settings go here later.
write_scene_file :: proc(builder: ^strings.Builder) {
	fmt.sbprintf(builder, "type = \"scene\"\nversion = %d\n", SCENE_FILE_VERSION)
}

write_sjson_vector :: proc(builder: ^strings.Builder, vector: [3]f32) {
	strings.write_byte(builder, '[')
	for component, component_index in vector {
		if component_index > 0 {
			strings.write_string(builder, ", ")
		}
		write_sjson_f32(builder, component)
	}
	strings.write_byte(builder, ']')
}

// Text that reads back (with strconv.parse_f32, as the reader does) as exactly this f32: the
// shortest such digits, as a plain decimal from 1e-6 up to 1e21 and with an exponent outside that
// range (the switch-over points JavaScript uses). `-0` keeps its sign. The value must be finite.
//
// Shortest digits alone aren't quite enough. parse_f32 parses to f64 and then rounds to f32, and
// rounding twice can go wrong when the f64 lands exactly halfway between two f32s. Checking every
// finite f32 found two such values (±7.038531e-26, bits 0x15ae43fd); the textbook example of
// this double rounding (see REFERENCES.md, Regan). So the text is read back, and if it doesn't
// give the same bits, more digits are written: 9 significant digits identify any f32, and they're
// never that close to a halfway point.
write_sjson_f32 :: proc(builder: ^strings.Builder, value: f32) {
	assert(!math.is_nan(value) && !math.is_inf(value), "SJSON numbers are finite")
	reads_back :: proc(text: string, value: f32) -> bool {
		parsed, ok := strconv.parse_f32(text)
		return ok && transmute(u32)parsed == transmute(u32)value
	}
	without_plus :: proc(text: string) -> string {
		return text[1:] if len(text) > 0 && text[0] == '+' else text // write_float signs positives too
	}
	magnitude := abs(value)
	format: u8 = 'f'
	if magnitude != 0 && (magnitude < 1e-6 || magnitude >= 1e21) {
		format = 'e'
	}
	buffer: [64]u8
	text := without_plus(strconv.write_float(buffer[:], f64(value), format, -1, 32))
	for significant_digits := 9; !reads_back(text, value); significant_digits += 1 {
		ensure(significant_digits <= 17, "17 significant digits identify any f64, so any f32")
		text = without_plus(strconv.write_float(buffer[:], f64(value), 'e', significant_digits - 1, 64))
	}
	strings.write_string(builder, text)
}

// A quoted string with JSON escapes, readable as JSON and SJSON alike.
write_sjson_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for character in text {
		switch character {
		case '"':  strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\t': strings.write_string(builder, "\\t")
		case '\r': strings.write_string(builder, "\\r")
		case:
			if character < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", character)
			} else {
				strings.write_rune(builder, character)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// ---------------------------------------------------------------------------------------------
// Reading a whole scene's entities

// Reads every entity file of a scene and checks them together. All or nothing: either every file
// is valid and the records come back sorted in Hierarchy order, or none do and the error says
// which file is wrong (#36's loading rules). Records' and the error's strings use `allocator`.
//
// Problems with an obvious fix are fixed, and the record says so in `fixes`: a missing id is
// made, a missing order key puts the entity last, and a name another entity already has is made
// unique (two people adding "Cube" in parallel produce exactly that, and refusing would make the
// scene unloadable). Everything else is refused.
read_entity_files :: proc(files: []Entity_File, allocator := context.allocator) -> (records: []Entity_Record, error: Maybe(File_Error)) {
	if len(files) > MAX_ENTITIES - 1 { // slot 0 is the nil entity
		return nil, make_file_error("", 0, "", fmt.tprintf("the scene has %d entities; this version holds at most %d", len(files), MAX_ENTITIES - 1), allocator)
	}
	records = make([]Entity_Record, len(files), allocator)
	for file, file_index in files {
		record, file_error := read_entity_file(file.name, file.text, allocator)
		if file_error != nil {
			return nil, file_error
		}
		records[file_index] = record
	}

	// The file name is the id. A file without an id is fine: it gets a new id, and the next save
	// writes it under the new name.
	file_index_of_id := make(map[u64]int, len(files), context.temp_allocator)
	for record, file_index in records {
		if .New_Id in record.fixes {
			continue
		}
		file_name := files[file_index].name
		expected_name := entity_file_name(record.id, context.temp_allocator)
		if file_name != expected_name {
			return nil, make_file_error(file_name, 0, "", fmt.tprintf("the file name must be its id: rename it to %s", expected_name), allocator)
		}
		if other_index, taken := file_index_of_id[record.id]; taken {
			return nil, make_file_error(file_name, 0, "id", fmt.tprintf("%s has the same id; if this file is a copy, delete its id line and it gets a new one", files[other_index].name), allocator)
		}
		file_index_of_id[record.id] = file_index
	}
	for &record in records {
		if .New_Id in record.fixes {
			for (record.id == 0 || record.id in file_index_of_id) {
				record.id = new_entity_id()
			}
			file_index_of_id[record.id] = -1
		}
	}

	// Hierarchy order: by (order, id), with the entities that had no key last, by id.
	slice.sort_by(records, proc(first, second: Entity_Record) -> bool {
		if (first.order == "") != (second.order == "") {
			return first.order != ""
		}
		return order_comes_before(first.order, first.id, second.order, second.id)
	})
	last_order := ""
	for &record in records {
		if record.order != "" {
			last_order = record.order
			continue
		}
		buffer: [core.ORDER_KEY_MAX_BYTES]u8
		key, ok := core.order_key_after(buffer[:], last_order)
		if !ok {
			// Only a hand-edited key of the full 32 bytes leaves no room after it. Then every
			// entity gets a short key again, in the same order, as order_key_after_last does.
			renumber_record_order_keys(records, allocator)
			break
		}
		record.order = strings.clone(key, allocator)
		record.fixes += {.New_Order}
		last_order = record.order
	}

	// Names are unique in the editor (docs/DESIGN.md, "Name validation"). The first entity in
	// Hierarchy order keeps a shared name; the others get the next free " (N)", the way Duplicate
	// names copies. Every name in the scene counts as taken from the start, so a new name never
	// takes one that a later entity has.
	taken := make(map[string]bool, len(records), context.temp_allocator)
	for record in records {
		taken[record.name] = true
	}
	seen := make(map[string]bool, len(records), context.temp_allocator)
	for &record in records {
		if record.name in seen {
			record.name = next_free_name(taken, record.name, allocator)
			taken[record.name] = true
			record.fixes += {.Renamed}
		}
		seen[record.name] = true
	}
	return records, nil
}

// Gives every record a fresh key ("a0", "a1", ...) in its current order.
@(private = "file")
renumber_record_order_keys :: proc(records: []Entity_Record, allocator: runtime.Allocator) {
	last_order := ""
	for &record in records {
		buffer: [core.ORDER_KEY_MAX_BYTES]u8
		key, ok := core.order_key_after(buffer[:], last_order)
		ensure(ok, "keys counted up from \"a0\" are short")
		record.order = strings.clone(key, allocator)
		record.fixes += {.New_Order}
		last_order = record.order
	}
}

// The first of "Cube", "Cube (1)", "Cube (2)", ... that isn't taken, built exactly the way
// unique_entity_name builds names (the base is shortened so the suffix fits in 48 bytes), but
// checked against a set of names instead of a scene.
next_free_name :: proc(taken: map[string]bool, name: string, allocator := context.allocator) -> string {
	base_name := strip_number_suffix(name)
	for number in 0 ..= len(taken) { // len(taken) names can't take len(taken) + 1 numbers
		suffix := fmt.tprintf(" (%d)", number) if number > 0 else ""
		candidate := fmt.tprintf("%s%s", truncate_utf8(base_name, ENTITY_NAME_BYTES - len(suffix)), suffix)
		if candidate not_in taken {
			return strings.clone(candidate, allocator)
		}
	}
	unreachable()
}

// ---------------------------------------------------------------------------------------------
// Reading one file

ENTITY_FILE_KEYS :: "type, version, id, name, order, position, rotation, scale, mesh"
MESH_KEYS        :: "primitive, color"

// Reads one entity file's text. Missing optional keys get defaults: position and rotation 0,
// scale 1, color 0.8 grey. A missing id or order is left for read_entity_files to fill in.
read_entity_file :: proc(file_name: string, text: string, allocator := context.allocator) -> (record: Entity_Record, error: Maybe(File_Error)) {
	root := parse_sjson(file_name, text, allocator) or_return

	// The type and version first: a file of another kind, or from a newer editor, gets that as
	// its error, not a list of keys this version doesn't know.
	read_file_header(file_name, root, "entity", ENTITY_FILE_VERSION, allocator) or_return
	// (Version 1 is the only one so far. Version 2 would read older files into their own record
	// structs here and upgrade them, with a fix flag, so the file is written again.)

	record = {scale = {1, 1, 1}, color = DEFAULT_ENTITY_COLOR, fixes = {.New_Id}}
	has_name := false
	for member in root.members {
		switch member.key {
		case "type", "version":
			// checked above
		case "id":
			id_text := sjson_string(file_name, member, allocator) or_return
			id, ok := strconv.parse_u64_of_base(id_text, 16)
			lowercase_hex := len(id_text) == 16
			for character in id_text {
				if !(('0' <= character && character <= '9') || ('a' <= character && character <= 'f')) {
					lowercase_hex = false
				}
			}
			if !lowercase_hex || !ok || id == 0 {
				return {}, make_file_error(file_name, member.line, member.key, "an id is 16 lowercase hex digits, not all zero; delete the line to get a new one", allocator)
			}
			record.id = id
			record.fixes -= {.New_Id}
		case "name":
			record.name = sjson_string(file_name, member, allocator) or_return
			if problem := entity_name_problem(record.name); problem != "" {
				return {}, make_file_error(file_name, member.line, member.key, problem, allocator)
			}
			has_name = true
		case "order":
			record.order = sjson_string(file_name, member, allocator) or_return
			if !core.order_key_is_valid(record.order) {
				return {}, make_file_error(file_name, member.line, member.key, fmt.tprintf("%q isn't an order key (like \"a0\"); delete the line to put the entity last", record.order), allocator)
			}
		case "position":
			record.position = sjson_vector(file_name, member, allocator) or_return
		case "rotation":
			record.rotation = sjson_vector(file_name, member, allocator) or_return
		case "scale":
			record.scale = sjson_vector(file_name, member, allocator) or_return
		case "mesh":
			if member.value.kind != .Object {
				return {}, make_file_error(file_name, member.line, member.key, "a mesh is { primitive = \"Cube\" color = [r, g, b] }", allocator)
			}
			record.has_mesh = true
			has_primitive := false
			for mesh_member in member.value.members {
				path_member := mesh_member
				path_member.key = fmt.tprintf("mesh.%s", mesh_member.key)
				switch mesh_member.key {
				case "primitive":
					primitive_name := sjson_string(file_name, path_member, allocator) or_return
					primitive_names := PRIMITIVE_NAMES
					has_primitive = false
					for kind_name, kind in primitive_names {
						if kind_name == primitive_name {
							record.primitive, has_primitive = kind, true
						}
					}
					if !has_primitive {
						return {}, make_file_error(file_name, path_member.line, path_member.key, fmt.tprintf("unknown primitive %q; the primitives are Cube, Sphere, Cylinder and Plane", primitive_name), allocator)
					}
				case "color":
					record.color = sjson_vector(file_name, path_member, allocator) or_return
				case:
					return {}, make_file_error(file_name, path_member.line, path_member.key, "unknown key; a mesh has: " + MESH_KEYS, allocator)
				}
			}
			if !has_primitive {
				return {}, make_file_error(file_name, member.line, member.key, "a mesh needs a primitive", allocator)
			}
		case:
			return {}, make_file_error(file_name, member.line, member.key, "unknown key; an entity file has: " + ENTITY_FILE_KEYS, allocator)
		}
	}
	if !has_name {
		return {}, make_file_error(file_name, 0, "name", "missing; every entity needs a name", allocator)
	}
	return record, nil
}

// Reads a scene file: its type and version, nothing else yet.
read_scene_file :: proc(file_name: string, text: string, allocator := context.allocator) -> Maybe(File_Error) {
	root := parse_sjson(file_name, text, allocator) or_return
	read_file_header(file_name, root, "scene", SCENE_FILE_VERSION, allocator) or_return
	for member in root.members {
		if member.key != "type" && member.key != "version" {
			return make_file_error(file_name, member.line, member.key, "unknown key; a scene file has: type, version", allocator)
		}
	}
	return nil
}

// Checks the `type` and `version` every file starts with.
@(private = "file")
read_file_header :: proc(file_name: string, root: Sjson_Value, expected_type: string, newest_version: int, allocator: runtime.Allocator) -> Maybe(File_Error) {
	type_member, has_type := sjson_find(root, "type")
	if !has_type {
		return make_file_error(file_name, 0, "type", fmt.tprintf("missing; the file should start with type = \"%s\"", expected_type), allocator)
	}
	file_type := sjson_string(file_name, type_member, allocator) or_return
	if file_type != expected_type {
		return make_file_error(file_name, type_member.line, "type", fmt.tprintf("expected type = \"%s\", found %q", expected_type, file_type), allocator)
	}
	version_member, has_version := sjson_find(root, "version")
	if !has_version {
		return make_file_error(file_name, 0, "version", fmt.tprintf("missing; add version = %d", newest_version), allocator)
	}
	version, ok := strconv.parse_int(version_member.value.text, 10)
	if version_member.value.kind != .Number || !ok || version < 1 {
		return make_file_error(file_name, version_member.line, "version", "a version is a whole number from 1", allocator)
	}
	if version > newest_version {
		return make_file_error(file_name, version_member.line, "version", fmt.tprintf("version %d is newer than this editor reads (%d); open it with a newer version", version, newest_version), allocator)
	}
	return nil
}

// Why `name` can't be an entity's name in a file, or "" if it can. Stricter than renaming in the
// editor (check_entity_name), which trims spaces and shortens long names quietly: a file can only
// hold such a name after a hand edit, and saying so is clearer than changing it. Uses the temp
// allocator.
entity_name_problem :: proc(name: string) -> string {
	if name == "" {
		return "a name can't be empty"
	}
	if strings.trim_space(name) != name {
		return "a name can't start or end with a space"
	}
	if len(name) > ENTITY_NAME_BYTES {
		return fmt.tprintf("a name is at most %d bytes", ENTITY_NAME_BYTES)
	}
	for character, byte_index in name {
		if name_character_allowed(character) || (byte_index > 0 && name_mark_allowed(character)) {
			continue
		}
		if name_mark_allowed(character) {
			return "a name can't start with a combining mark"
		}
		return fmt.tprintf("names can't contain %q; use letters, digits, spaces and _ - . ( )", character)
	}
	return ""
}

@(private = "file")
sjson_find :: proc(object: Sjson_Value, key: string) -> (member: Sjson_Member, found: bool) {
	for candidate in object.members {
		if candidate.key == key {
			return candidate, true
		}
	}
	return {}, false
}

@(private = "file")
sjson_string :: proc(file_name: string, member: Sjson_Member, allocator: runtime.Allocator) -> (text: string, error: Maybe(File_Error)) {
	if member.value.kind != .String {
		return "", make_file_error(file_name, member.line, member.key, "should be text in quotes", allocator)
	}
	return member.value.text, nil
}

// Three finite numbers that fit in an f32: [x, y, z].
@(private = "file")
sjson_vector :: proc(file_name: string, member: Sjson_Member, allocator: runtime.Allocator) -> (vector: [3]f32, error: Maybe(File_Error)) {
	if member.value.kind != .Array || len(member.value.elements) != 3 {
		return {}, make_file_error(file_name, member.line, member.key, "should be three numbers: [x, y, z]", allocator)
	}
	for element, component_index in member.value.elements {
		path := fmt.tprintf("%s[%d]", member.key, component_index)
		value, ok := strconv.parse_f32(element.text)
		if element.kind != .Number || !ok || math.is_nan(value) || math.is_inf(value) {
			return {}, make_file_error(file_name, element.line, path, "should be a finite number that fits in 32 bits", allocator)
		}
		vector[component_index] = value
	}
	return vector, nil
}

// ---------------------------------------------------------------------------------------------
// SJSON parser
//
// A small recursive parser on Odin's JSON tokenizer, building a tree that remembers each value's
// line. Commas are optional everywhere (the tokenizer only sometimes turns a newline into one),
// `=` and `:` both separate a key from its value, and the root may be wrapped in braces.

Sjson_Kind :: enum u8 {
	Null,
	Boolean,
	Number,
	String,
	Array,
	Object,
}

Sjson_Value :: struct {
	kind:     Sjson_Kind,
	line:     int,
	boolean:  bool,
	text:     string,         // .String: without quotes or escapes; .Number: as written
	elements: []Sjson_Value,  // .Array
	members:  []Sjson_Member, // .Object, in file order
}

Sjson_Member :: struct {
	key:   string,
	line:  int,
	value: Sjson_Value,
}

// Deeper nesting is refused, so a hostile file can't exhaust the stack. Our files nest two deep.
MAX_SJSON_DEPTH :: 64

Sjson_Parser :: struct {
	file_name:      string,
	text:           string,
	allocator:      runtime.Allocator,
	tokenizer:      json.Tokenizer,
	token:          json.Token, // the current token
	token_line:     int,        // its line, counted by us
	counted_offset: int,        // lines are counted up to this byte
	counted_line:   int,
	depth:          int,
}

// Parses SJSON (or plain JSON) text into a tree on `allocator`; the root is always an object.
parse_sjson :: proc(file_name: string, text: string, allocator := context.allocator) -> (root: Sjson_Value, error: Maybe(File_Error)) {
	parser := Sjson_Parser {
		file_name    = file_name,
		text         = text,
		allocator    = allocator,
		tokenizer    = json.make_tokenizer(text, .SJSON),
		counted_line = 1,
	}
	advance_sjson(&parser) or_return
	root = {kind = .Object, line = 1}
	if parser.token.kind == .Open_Brace {
		advance_sjson(&parser) or_return
		root.members = parse_sjson_members(&parser, .Close_Brace) or_return
		advance_sjson(&parser) or_return
		skip_sjson_commas(&parser) or_return
		if parser.token.kind != .EOF {
			return {}, sjson_error(&parser, "unexpected text after the closing }")
		}
	} else {
		root.members = parse_sjson_members(&parser, .EOF) or_return
	}
	return root, nil
}

@(private = "file")
sjson_error :: proc(parser: ^Sjson_Parser, message: string) -> File_Error {
	return make_file_error(parser.file_name, parser.token_line, "", message, parser.allocator)
}

// Moves to the next token and counts the lines up to it.
@(private = "file")
advance_sjson :: proc(parser: ^Sjson_Parser) -> Maybe(File_Error) {
	token, token_error := json.get_token(&parser.tokenizer)
	parser.token = token
	for parser.counted_offset < token.offset && parser.counted_offset < len(parser.text) {
		if parser.text[parser.counted_offset] == '\n' {
			parser.counted_line += 1
		}
		parser.counted_offset += 1
	}
	parser.token_line = parser.counted_line
	#partial switch token_error {
	case .None:
		return nil
	case .EOF:
		if token.kind == .EOF {
			return nil
		}
		return sjson_error(parser, "a /* comment is never closed")
	case .Illegal_Character:
		character, _ := utf8.decode_rune_in_string(parser.text[min(token.offset, len(parser.text)):])
		return sjson_error(parser, fmt.tprintf("unexpected character %q", character))
	case .Invalid_Number:
		return sjson_error(parser, fmt.tprintf("%s isn't a number", token.text))
	case .String_Not_Terminated, .Invalid_String:
		// An unterminated string is reported as .Invalid_String too (the tokenizer checks the
		// literal afterwards and overwrites the error), so look at the text.
		text := token.text
		if len(text) < 2 || text[len(text) - 1] != text[0] {
			return sjson_error(parser, "text is missing its closing quote")
		}
		return sjson_error(parser, "text has an escape that isn't valid")
	case:
		return sjson_error(parser, fmt.tprintf("can't read this: %v", token_error))
	}
}

@(private = "file")
skip_sjson_commas :: proc(parser: ^Sjson_Parser) -> Maybe(File_Error) {
	for parser.token.kind == .Comma {
		advance_sjson(parser) or_return
	}
	return nil
}

// Members up to `end` (a closing brace, or the end of the file for a root without braces). The
// closing token is left as the current token.
@(private = "file")
parse_sjson_members :: proc(parser: ^Sjson_Parser, end: json.Token_Kind) -> (members: []Sjson_Member, error: Maybe(File_Error)) {
	list := make([dynamic]Sjson_Member, parser.allocator)
	for {
		skip_sjson_commas(parser) or_return
		if parser.token.kind == end {
			return list[:], nil
		}
		if parser.token.kind == .EOF {
			return nil, sjson_error(parser, "a { is never closed")
		}
		member := Sjson_Member{line = parser.token_line}
		#partial switch parser.token.kind {
		case .Ident:
			member.key = strings.clone(parser.token.text, parser.allocator)
		case .String:
			unquoted, unquote_error := json.unquote_string(parser.token, .SJSON, parser.allocator)
			if unquote_error != .None {
				return nil, sjson_error(parser, "text has an escape that isn't valid")
			}
			member.key = unquoted
		case:
			return nil, sjson_error(parser, fmt.tprintf("expected a key, found %q", parser.token.text))
		}
		for existing in list {
			if existing.key == member.key {
				return nil, sjson_error(parser, fmt.tprintf("%q appears twice", member.key))
			}
		}
		advance_sjson(parser) or_return
		if parser.token.kind != .Colon {
			return nil, sjson_error(parser, fmt.tprintf("expected = after %s", member.key))
		}
		advance_sjson(parser) or_return
		member.value = parse_sjson_value(parser) or_return
		append(&list, member)
	}
}

// One value, starting at the current token; afterwards the token after it is current.
@(private = "file")
parse_sjson_value :: proc(parser: ^Sjson_Parser) -> (value: Sjson_Value, error: Maybe(File_Error)) {
	value.line = parser.token_line
	#partial switch parser.token.kind {
	case .String:
		unquoted, unquote_error := json.unquote_string(parser.token, .SJSON, parser.allocator)
		if unquote_error != .None {
			return {}, sjson_error(parser, "text has an escape that isn't valid")
		}
		value.kind, value.text = .String, unquoted
	case .Integer, .Float:
		value.kind, value.text = .Number, strings.clone(parser.token.text, parser.allocator)
	case .True, .False:
		value.kind, value.boolean = .Boolean, parser.token.kind == .True
	case .Null:
		value.kind = .Null
	case .Infinity, .NaN:
		return {}, sjson_error(parser, "numbers must be finite")
	case .Ident:
		return {}, sjson_error(parser, fmt.tprintf("text needs quotes: \"%s\"", parser.token.text))
	case .Open_Brace, .Open_Bracket:
		parser.depth += 1
		if parser.depth > MAX_SJSON_DEPTH {
			return {}, sjson_error(parser, "nested too deeply")
		}
		opening := parser.token.kind
		advance_sjson(parser) or_return
		if opening == .Open_Brace {
			value.kind = .Object
			value.members = parse_sjson_members(parser, .Close_Brace) or_return
		} else {
			value.kind = .Array
			elements := make([dynamic]Sjson_Value, parser.allocator)
			for {
				skip_sjson_commas(parser) or_return
				if parser.token.kind == .Close_Bracket {
					break
				}
				if parser.token.kind == .EOF {
					return {}, sjson_error(parser, "a [ is never closed")
				}
				element := parse_sjson_value(parser) or_return
				append(&elements, element)
			}
			value.elements = elements[:]
		}
		parser.depth -= 1
	case:
		return {}, sjson_error(parser, fmt.tprintf("expected a value, found %q", parser.token.text))
	}
	advance_sjson(parser) or_return
	return value, nil
}
