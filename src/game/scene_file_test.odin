// Tests for scene files' records, reader and writer (scene_file.odin). No GPU and no disk: files
// are text in memory. Run with `build.bat test`.
package game

import "core:fmt"
import "core:strings"
import "core:testing"
import "engine:core"

// A scene whose primitive meshes have handles but no geometry, enough for records.
@(private = "file")
make_record_test_scene :: proc() -> ^Scene {
	scene := new(Scene, context.temp_allocator)
	for kind in Primitive_Kind {
		scene.primitive_meshes[kind] = {index = u32(kind) + 1, generation = 1}
	}
	return scene
}

@(private = "file")
TEST_FILE_NAME :: "7f3a9c21d04e5b16.entity"

@(private = "file")
read_test_entity :: proc(text: string) -> (Entity_Record, Maybe(File_Error)) {
	return read_entity_file(TEST_FILE_NAME, text, context.temp_allocator)
}

// Checks that `error` is a File_Error on `line` for `key`, with `message_part` in its message.
@(private = "file")
expect_file_error :: proc(test: ^testing.T, error: Maybe(File_Error), line: int, key: string, message_part: string, location := #caller_location) {
	file_error, failed := error.?
	if !testing.expectf(test, failed, "expected an error containing %q, got none", message_part, loc = location) {
		return
	}
	testing.expectf(
		test,
		file_error.line == line && file_error.key == key && strings.contains(file_error.message, message_part),
		"got %q; expected line %d, key %q and %q in the message",
		file_error_text(file_error, context.temp_allocator), line, key, message_part,
		loc = location,
	)
}

@(private = "file")
expect_no_file_error :: proc(test: ^testing.T, error: Maybe(File_Error), location := #caller_location) {
	if file_error, failed := error.?; failed {
		testing.expectf(test, false, "unexpected error: %s", file_error_text(file_error, context.temp_allocator), loc = location)
	}
}

@(test)
test_entity_file_text_is_exact :: proc(test: ^testing.T) {
	record := Entity_Record {
		id        = 0x7f3a9c21d04e5b16,
		name      = "Cube",
		order     = "a0",
		position  = {0, 0.5, 0},
		rotation  = {0, 45, 0},
		scale     = {1, 1, 1},
		has_mesh  = true,
		primitive = .Cube,
		color     = {0.8, 0.2, 0.2},
	}
	builder := strings.builder_make(context.temp_allocator)
	write_entity_file(&builder, record)
	expected := `type = "entity"
version = 1
id = "7f3a9c21d04e5b16"
name = "Cube"
order = "a0"
position = [0, 0.5, 0]
rotation = [0, 45, 0]
scale = [1, 1, 1]
mesh = {
    primitive = "Cube"
    color = [0.8, 0.2, 0.2]
}
`
	testing.expect_value(test, strings.to_string(builder), expected)

	// No mesh, no mesh block. Names with quotes and backslashes are escaped (the editor doesn't
	// allow them, but the writer must never produce text the reader can't read).
	record.has_mesh = false
	record.name = `a "b" \ c`
	strings.builder_reset(&builder)
	write_entity_file(&builder, record)
	text := strings.to_string(builder)
	testing.expect(test, !strings.contains(text, "mesh"), "an entity without a mesh has no mesh block")
	testing.expect(test, strings.contains(text, `name = "a \"b\" \\ c"`), "quotes and backslashes are escaped")
	free_all(context.temp_allocator)
}

@(test)
test_entity_file_round_trip :: proc(test: ^testing.T) {
	scene := make_record_test_scene()
	_, entity := create_entity(scene, "Crate (2)")
	entity.flags += {.Has_Mesh, .Selected}
	entity.mesh = scene.primitive_meshes[.Cylinder]
	entity.position = {-3.25, 0.1, 1e-9}
	entity.rotation = {12.5, -90, 359.9}
	entity.scale = {2, 0, -1}
	entity.color = {0.85, 0.35, 0.2}

	record, ok := entity_record_from_entity(scene, entity)
	testing.expect(test, ok, "a primitive mesh can be saved")
	builder := strings.builder_make(context.temp_allocator)
	write_entity_file(&builder, record)
	text := strings.clone(strings.to_string(builder), context.temp_allocator)

	read_back, error := read_entity_file(entity_file_name(record.id, context.temp_allocator), text, context.temp_allocator)
	expect_no_file_error(test, error)
	testing.expect(test, read_back.fixes == {}, "a file the editor wrote needs no fixes")
	read_back.fixes = {}
	testing.expect(test, read_back.id == record.id && read_back.name == record.name && read_back.order == record.order, "id, name and order survive")
	testing.expect(test, read_back.position == record.position && read_back.rotation == record.rotation && read_back.scale == record.scale, "the transform survives exactly")
	testing.expect(test, read_back.has_mesh && read_back.primitive == .Cylinder && read_back.color == record.color, "the mesh survives")

	// Writing what was read gives the same bytes: an unchanged entity never changes its file.
	strings.builder_reset(&builder)
	write_entity_file(&builder, read_back)
	testing.expect_value(test, strings.to_string(builder), text)

	// Applying the record to another entity gives the same saved fields, and leaves runtime
	// state alone.
	_, other := create_entity(scene, "Other")
	apply_entity_record(scene, other, read_back)
	testing.expect(test, other.id == entity.id && entity_name(other) == "Crate (2)" && entity_order_key(other) == entity_order_key(entity), "identity applied")
	testing.expect(test, other.position == entity.position && other.mesh == entity.mesh && .Has_Mesh in other.flags, "transform and mesh applied")
	testing.expect(test, !(.Selected in other.flags), "selection isn't part of a record")

	// A mesh that isn't a primitive can't be saved yet (#43).
	entity.mesh = {index = 99, generation = 1}
	_, saveable := entity_record_from_entity(scene, entity)
	testing.expect(test, !saveable, "a mesh that isn't a primitive is reported")
	free_all(context.temp_allocator)
}

@(test)
test_floats_round_trip_exactly :: proc(test: ^testing.T) {
	negative_zero := transmute(f32)u32(0x8000_0000) // from its bits: a `-0.0` constant may fold to +0
	values := []f32 {
		0, negative_zero, 0.1, 0.5, -3.25, 0.8, 1e-9, 16777216, 1234567,
		3.4028235e38,                   // the largest f32
		1.1754944e-38,                  // the smallest normal f32
		1e-45,                          // the smallest denormal f32
		1e21, 9.99e20, 1e-6, 9.99e-7,   // around the switch to exponent form
		transmute(f32)u32(0x15ae43fd),  // 7.038531e-26: its shortest text reads back wrong
	}
	for value in values {
		builder := strings.builder_make(context.temp_allocator)
		write_sjson_f32(&builder, value)
		number_text := strings.to_string(builder)
		text := fmt.tprintf("type = \"entity\"\nversion = 1\nname = \"N\"\nposition = [%s, %s, %s]\n", number_text, number_text, number_text)
		record, error := read_test_entity(text)
		expect_no_file_error(test, error)
		testing.expectf(test, transmute(u32)record.position.x == transmute(u32)value, "%v (bits %08x) written as %s read back as bits %08x", value, transmute(u32)value, number_text, transmute(u32)record.position.x)
	}

	shortest :: proc(value: f32) -> string {
		builder := strings.builder_make(context.temp_allocator)
		write_sjson_f32(&builder, value)
		return strings.to_string(builder)
	}
	testing.expect_value(test, shortest(0.1), "0.1")
	testing.expect_value(test, shortest(negative_zero), "-0")
	testing.expect_value(test, shortest(1e-9), "1e-09")
	testing.expect_value(test, shortest(1234567), "1234567")
	testing.expect_value(test, shortest(transmute(f32)u32(0x15ae43fd)), "7.03853069e-26")
	free_all(context.temp_allocator)
}

@(test)
test_reader_accepts_json_and_sjson_styles :: proc(test: ^testing.T) {
	// Plain JSON, as an agent or a script might write it.
	json_text := `{
  "type": "entity",
  "version": 1,
  "name": "Lamp",
  "position": [1, 2, 3],
  "mesh": {"primitive": "Sphere", "color": [1, 1, 0.5]}
}`
	record, error := read_test_entity(json_text)
	expect_no_file_error(test, error)
	testing.expect(test, record.name == "Lamp" && record.position == {1, 2, 3} && record.primitive == .Sphere && record.color == {1, 1, 0.5}, "plain JSON is read")
	testing.expect(test, record.scale == {1, 1, 1} && record.rotation == {}, "missing keys get defaults")
	testing.expect(test, .New_Id in record.fixes, "no id: one is made later")

	// SJSON with comments, no commas, a space-separated array, and Windows line endings.
	sjson_text := "// a lamp\r\ntype = \"entity\"\r\nversion = 1 /* first */\r\nname = \"Lamp\"\r\nscale = [2 2 2]\r\nmesh = {\r\n    primitive = \"Plane\" // flat\r\n}\r\n"
	record, error = read_test_entity(sjson_text)
	expect_no_file_error(test, error)
	testing.expect(test, record.scale == {2, 2, 2} && record.primitive == .Plane && record.color == DEFAULT_ENTITY_COLOR, "SJSON with comments is read")

	// SJSON inside braces, with trailing commas.
	braced_text := "{\n    type = \"entity\",\n    version = 1,\n    name = \"Lamp\",\n    position = [1, 2, 3,],\n}\n"
	record, error = read_test_entity(braced_text)
	expect_no_file_error(test, error)
	testing.expect(test, record.position == {1, 2, 3}, "braces and trailing commas are fine")
	free_all(context.temp_allocator)
}

@(test)
test_reader_reports_the_right_line :: proc(test: ^testing.T) {
	// The tokenizer's own line count falls behind after newlines it turns into commas, and after
	// comments; ours counts from offsets.
	text := `type = "entity"
version = 1
// a comment
/* a block
   comment */
name = "Cube"
postion = [0, 1, 0]
`
	_, error := read_test_entity(text)
	expect_file_error(test, error, 7, "postion", "unknown key")
	if file_error, failed := error.?; failed {
		testing.expect_value(test, file_error_text(file_error, context.temp_allocator), "7f3a9c21d04e5b16.entity:7: postion: unknown key; an entity file has: " + ENTITY_FILE_KEYS)
	}

	// An array element on its own line gets that line, and a path with its index.
	text = "type = \"entity\"\nversion = 1\nname = \"Cube\"\nposition = [\n    0,\n    \"x\",\n    0\n]\n"
	_, error = read_test_entity(text)
	expect_file_error(test, error, 6, "position[1]", "number")

	// A syntax error gets its line too.
	text = "type = \"entity\"\nversion = 1\n\nname = \"Cube\nscale = [1, 1, 1]\n"
	_, error = read_test_entity(text)
	expect_file_error(test, error, 4, "", "closing quote")
	free_all(context.temp_allocator)
}

@(test)
test_reader_refuses_bad_entity_files :: proc(test: ^testing.T) {
	HEADER :: "type = \"entity\"\nversion = 1\n"
	Case :: struct {
		text:         string,
		line:         int,
		key:          string,
		message_part: string,
	}
	cases := []Case {
		// type and version
		{"version = 1\nname = \"A\"\n", 0, "type", "missing"},
		{"type = \"scene\"\nversion = 1\n", 1, "type", "expected type = \"entity\""},
		{"type = \"entity\"\nname = \"A\"\n", 0, "version", "missing"},
		{"type = \"entity\"\nversion = \"1\"\n", 2, "version", "whole number"},
		{"type = \"entity\"\nversion = 2\n", 2, "version", "newer"},
		// keys
		{HEADER + "name = \"A\"\ncolour = [1, 1, 1]\n", 4, "colour", "unknown key"},
		{HEADER + "name = \"A\"\nmesh = { primitive = \"Cube\" tint = [1, 1, 1] }\n", 4, "mesh.tint", "unknown key; a mesh has"},
		{HEADER + "name = \"A\"\nmesh = { primitive = \"Cub\" }\n", 4, "mesh.primitive", "unknown primitive \"Cub\""},
		{HEADER + "name = \"A\"\nmesh = { color = [1, 1, 1] }\n", 4, "mesh", "needs a primitive"},
		{HEADER + "name = \"A\"\nmesh = \"Cube\"\n", 4, "mesh", "a mesh is"},
		{HEADER + "name = \"A\"\nname = \"B\"\n", 4, "", "\"name\" appears twice"},
		// names
		{HEADER + "position = [0, 0, 0]\n", 0, "name", "missing"},
		{HEADER + "name = \"\"\n", 3, "name", "empty"},
		{HEADER + "name = \" A\"\n", 3, "name", "space"},
		{HEADER + "name = \"a/b\"\n", 3, "name", "can't contain '/'"},
		{HEADER + "name = \"" + "0123456789012345678901234567890123456789012345678" + "\"\n", 3, "name", "at most 48 bytes"},
		{HEADER + "name = \"́A\"\n", 3, "name", "combining mark"},
		{HEADER + "name = 5\n", 3, "name", "text in quotes"},
		// ids
		{HEADER + "name = \"A\"\nid = \"7F3A9C21D04E5B16\"\n", 4, "id", "lowercase hex"},
		{HEADER + "name = \"A\"\nid = \"7f3a9c21d04e5b1\"\n", 4, "id", "16 lowercase hex"},
		{HEADER + "name = \"A\"\nid = \"0000000000000000\"\n", 4, "id", "not all zero"},
		{HEADER + "name = \"A\"\nid = \"7f3a9c21d04e5b1g\"\n", 4, "id", "hex"},
		// order keys
		{HEADER + "name = \"A\"\norder = \"a00\"\n", 4, "order", "isn't an order key"},
		// numbers and vectors
		{HEADER + "name = \"A\"\nposition = [0, 0]\n", 4, "position", "three numbers"},
		{HEADER + "name = \"A\"\nposition = [0, true, 0]\n", 4, "position[1]", "number"},
		{HEADER + "name = \"A\"\nposition = [0, 1e39, 0]\n", 4, "position[1]", "fits in 32 bits"},
		{HEADER + "name = \"A\"\nposition = [0, NaN, 0]\n", 4, "", "finite"},
		{HEADER + "name = \"A\"\nposition = [0, Infinity, 0]\n", 4, "", "finite"},
		// syntax
		{HEADER + "name = \"A\"\nmesh = { primitive = Cube }\n", 4, "", "needs quotes"},
		{HEADER + "name = \"A\"\nmesh = {\n    primitive = \"Cube\"\n", 6, "", "never closed"},
		{HEADER + "name = \"A\"\nposition = [0, 0, 0\n", 5, "", "never closed"},
		{HEADER + "name = \"A\" @\n", 3, "", "unexpected character '@'"},
		{HEADER + "name \"A\"\n", 3, "", "expected = after name"},
		{"{\n" + HEADER + "name = \"A\"\n}\nextra = 1\n", 6, "", "after the closing }"},
		{HEADER + "/* never closed\nname = \"A\"\n", 3, "", "comment is never closed"},
	}
	for test_case, case_index in cases {
		_, error := read_test_entity(test_case.text)
		if _, failed := error.?; !failed {
			testing.expectf(test, false, "case %d should be refused: %q", case_index, test_case.text)
			continue
		}
		expect_file_error(test, error, test_case.line, test_case.key, test_case.message_part)
	}

	// Nesting deeper than MAX_SJSON_DEPTH is refused before it can exhaust the stack.
	deep := strings.concatenate({HEADER, "name = \"A\"\nextra = ", strings.repeat("[", 10_000, context.temp_allocator), "\n"}, context.temp_allocator)
	_, error := read_test_entity(deep)
	expect_file_error(test, error, 4, "", "nested too deeply")
	free_all(context.temp_allocator)
}

@(private = "file")
entity_text :: proc(id: u64, name: string, order: string = "") -> string {
	id_line := fmt.tprintf("id = \"%016x\"\n", id) if id != 0 else ""
	order_line := fmt.tprintf("order = \"%s\"\n", order) if order != "" else ""
	return fmt.tprintf("type = \"entity\"\nversion = 1\n%sname = \"%s\"\n%s", id_line, name, order_line)
}

@(private = "file")
entity_test_file :: proc(id: u64, name: string, order: string = "") -> Entity_File {
	file_name := entity_file_name(id, context.temp_allocator) if id != 0 else "copied by hand.entity"
	return {name = file_name, text = entity_text(id, name, order)}
}

@(test)
test_read_entity_files_orders_and_fixes :: proc(test: ^testing.T) {
	files := []Entity_File {
		entity_test_file(0x30, "Cube", "a2"),
		entity_test_file(0x10, "Cube", "a1"),
		entity_test_file(0x20, "Cube (1)", "a1"), // same key as 0x10: the id decides
		entity_test_file(0x40, "Lamp"),           // no key: goes last
		entity_test_file(0, "Cube"),              // no id and no key
	}
	records, error := read_entity_files(files, context.temp_allocator)
	expect_no_file_error(test, error)
	if !testing.expect_value(test, len(records), 5) {
		return
	}
	// Hierarchy order: (order, id), with the entities that had no key after the rest.
	testing.expect(test, records[0].id == 0x10 && records[1].id == 0x20 && records[2].id == 0x30, "sorted by key, then id")
	testing.expect(test, records[3].id == 0x40, "an entity without a key comes after those with one")
	testing.expect(test, records[4].id != 0 && .New_Id in records[4].fixes, "an entity without an id gets one")
	testing.expect_value(test, records[3].order, "a3")
	testing.expect_value(test, records[4].order, "a4")
	testing.expect(test, .New_Order in records[3].fixes && !(.New_Order in records[0].fixes), "only made keys are fixes")

	// Names: the first "Cube" in Hierarchy order keeps it; "Cube (1)" is already taken, so the
	// next ones become "Cube (2)" and "Cube (3)".
	testing.expect_value(test, records[0].name, "Cube")
	testing.expect_value(test, records[1].name, "Cube (1)")
	testing.expect_value(test, records[2].name, "Cube (2)")
	testing.expect_value(test, records[4].name, "Cube (3)")
	testing.expect(test, .Renamed in records[2].fixes && .Renamed in records[4].fixes && !(.Renamed in records[0].fixes), "renamed records say so")
	free_all(context.temp_allocator)
}

@(test)
test_read_entity_files_refuses_bad_scenes :: proc(test: ^testing.T) {
	// The file name must be the id.
	files := []Entity_File{{name = "cube.entity", text = entity_text(0x10, "Cube")}}
	_, error := read_entity_files(files, context.temp_allocator)
	expect_file_error(test, error, 0, "", "rename it to 0000000000000010.entity")

	// Two files with one id: usually a copy, refused with the way out.
	files = []Entity_File{entity_test_file(0x10, "Cube"), {name = entity_file_name(0x10, context.temp_allocator), text = entity_text(0x10, "Copy")}}
	_, error = read_entity_files(files, context.temp_allocator)
	expect_file_error(test, error, 0, "id", "delete its id line")

	// All or nothing: one bad file and no records come back, with that file named.
	files = []Entity_File{entity_test_file(0x10, "Cube"), {name = entity_file_name(0x20, context.temp_allocator), text = "type = \"entity\"\nversion = 1\nname = \"Bad\"\nscale = 2\n"}}
	records: []Entity_Record
	records, error = read_entity_files(files, context.temp_allocator)
	testing.expect(test, records == nil, "a refused scene gives no records")
	if file_error, failed := error.?; failed {
		testing.expect_value(test, file_error.file_name, "0000000000000020.entity")
	}

	// More entities than the pool holds.
	too_many := make([]Entity_File, MAX_ENTITIES, context.temp_allocator)
	_, error = read_entity_files(too_many, context.temp_allocator)
	expect_file_error(test, error, 0, "", "at most 4095")
	free_all(context.temp_allocator)
}

@(test)
test_read_entity_files_renumbers_when_a_key_is_full :: proc(test: ^testing.T) {
	// A hand-edited key of the full 32 bytes leaves no room after it for an entity without a key;
	// then every entity gets a short key again, in the same order.
	longest := strings.concatenate({"z", strings.repeat("z", 26, context.temp_allocator), "zzzzz"}, context.temp_allocator)
	testing.expect(test, core.order_key_is_valid(longest) && len(longest) == core.ORDER_KEY_MAX_BYTES, "the test key is valid and full length")
	files := []Entity_File{entity_test_file(0x10, "First", "a5"), entity_test_file(0x20, "Second", longest), entity_test_file(0x30, "Third")}
	records, error := read_entity_files(files, context.temp_allocator)
	expect_no_file_error(test, error)
	if !testing.expect_value(test, len(records), 3) {
		return
	}
	testing.expect(test, records[0].order == "a0" && records[1].order == "a1" && records[2].order == "a2", "short keys in the same order")
	testing.expect(test, records[0].id == 0x10 && records[2].id == 0x30, "the order is kept")
	for record in records {
		testing.expect(test, .New_Order in record.fixes, "every renumbered record needs saving")
	}
	free_all(context.temp_allocator)
}

@(test)
test_scene_file :: proc(test: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	write_scene_file(&builder)
	testing.expect_value(test, strings.to_string(builder), "type = \"scene\"\nversion = 1\n")
	expect_no_file_error(test, read_scene_file("demo.scene", strings.to_string(builder), context.temp_allocator))
	expect_file_error(test, read_scene_file("demo.scene", "type = \"scene\"\nversion = 1\ngravity = 9.8\n", context.temp_allocator), 3, "gravity", "unknown key")
	expect_file_error(test, read_scene_file("demo.scene", entity_text(0x10, "Cube"), context.temp_allocator), 1, "type", "expected type = \"scene\"")
	free_all(context.temp_allocator)
}
