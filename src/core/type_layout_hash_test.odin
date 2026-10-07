// Tests for type layout hashes. Run with `build.bat test`.
package core

import "core:testing"

// The anonymous struct types below are separate declarations, so these tests also check that
// the hash depends only on the layout, never on which declaration (or build) it came from.

@(test)
test_layout_hash_is_the_same_for_the_same_layout :: proc(test: ^testing.T) {
	first := type_layout_hash(struct {position: [3]f32, count: int, name: string})
	second := type_layout_hash(struct {position: [3]f32, count: int, name: string})
	testing.expect_value(test, first, second)
	testing.expect_value(test, type_layout_hash(int), type_layout_hash(int))

	// Two declarations with the same name and layout, like one type in two builds. (The tests
	// below rely on this: their two versions of a type differ only in layout.)
	before, after: u64
	{
		Item :: struct {x: f32, next: ^Item}
		before = type_layout_hash([dynamic]Item)
	}
	{
		Item :: struct {x: f32, next: ^Item}
		after = type_layout_hash([dynamic]Item)
	}
	testing.expect_value(test, before, after)
}

// The bug this exists for: both of these are the same size, so comparing sizes reloads one
// into the other.
@(test)
test_layout_hash_changes_when_fields_are_reordered :: proc(test: ^testing.T) {
	before := type_layout_hash(struct {width: f32, height: f32})
	after := type_layout_hash(struct {height: f32, width: f32})
	testing.expect_value(test, size_of(struct {width: f32, height: f32}), size_of(struct {height: f32, width: f32}))
	testing.expect(test, before != after, "reordered fields must change the hash")
}

@(test)
test_layout_hash_changes_when_a_field_changes_type :: proc(test: ^testing.T) {
	floats := type_layout_hash(struct {value: f32})
	signed := type_layout_hash(struct {value: i32})
	unsigned := type_layout_hash(struct {value: u32})
	testing.expect(test, floats != signed, "f32 -> i32 must change the hash")
	testing.expect(test, signed != unsigned, "i32 -> u32 must change the hash")
}

@(test)
test_layout_hash_changes_when_a_field_is_renamed :: proc(test: ^testing.T) {
	// Same layout in bytes, but swapping two names swaps their meaning.
	before := type_layout_hash(struct {minimum: f32, maximum: f32})
	after := type_layout_hash(struct {maximum: f32, minimum: f32})
	renamed := type_layout_hash(struct {low: f32, maximum: f32})
	testing.expect(test, before != after, "swapped names must change the hash")
	testing.expect(test, before != renamed, "a renamed field must change the hash")
}

@(test)
test_layout_hash_changes_with_array_counts :: proc(test: ^testing.T) {
	// [4]u16 and [2]u32 are both 8 bytes.
	testing.expect(test, type_layout_hash([4]u16) != type_layout_hash([2]u32), "element type and count are part of the layout")
	testing.expect(test, type_layout_hash([4]f32) != type_layout_hash([5]f32), "count is part of the layout")
}

// Memory reached through a pointer or a dynamic array was allocated by the old build too, so a
// change in what they point to must also force a restart, even though the pointer's own size
// doesn't change. Each version of a type is declared in its own block so both have the same
// name: only their layouts differ.
@(test)
test_layout_hash_follows_pointers_and_containers :: proc(test: ^testing.T) {
	Hashes :: struct {pointer, dynamic_array, slice, map_value: u64}
	before, after: Hashes
	{
		Item :: struct {x: f32, y: f32}
		before = {type_layout_hash(^Item), type_layout_hash([dynamic]Item), type_layout_hash([]Item), type_layout_hash(map[int]Item)}
	}
	{
		Item :: struct {y: f32, x: f32}
		after = {type_layout_hash(^Item), type_layout_hash([dynamic]Item), type_layout_hash([]Item), type_layout_hash(map[int]Item)}
	}
	testing.expect(test, before.pointer != after.pointer, "pointer target")
	testing.expect(test, before.dynamic_array != after.dynamic_array, "dynamic array element")
	testing.expect(test, before.slice != after.slice, "slice element")
	testing.expect(test, before.map_value != after.map_value, "map value")
}

@(test)
test_layout_hash_changes_when_enum_values_change :: proc(test: ^testing.T) {
	// A stored enum is a number; renumbering the members changes what every stored value means.
	before, after: u64
	{
		Mode :: enum u8 {Move, Rotate, Scale}
		before = type_layout_hash(Mode)
	}
	{
		Mode :: enum u8 {Move, Scale, Rotate}
		after = type_layout_hash(Mode)
	}
	testing.expect(test, before != after, "reordered enum members")
}

@(test)
test_layout_hash_changes_with_union_variants :: proc(test: ^testing.T) {
	testing.expect(test, type_layout_hash(union {i32, f32}) != type_layout_hash(union {f32, i32}), "the tag numbers the variants in order")
}

// A type that points to itself (a linked list) must not recurse forever.
@(test)
test_layout_hash_handles_recursive_types :: proc(test: ^testing.T) {
	first, second, changed: u64
	{
		Node :: struct {value: int, next: ^Node}
		first = type_layout_hash(Node)
		second = type_layout_hash(Node)
	}
	{
		Node :: struct {value: f64, next: ^Node}
		changed = type_layout_hash(Node)
	}
	testing.expect_value(test, first, second)
	testing.expect(test, first != changed, "recursive types still differ by layout")
}
