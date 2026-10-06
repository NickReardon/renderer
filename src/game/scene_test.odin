// Tests for scene bookkeeping that needs no GPU: entity handles and names.
// Run with `build.bat test`.
package game

import "core:strings"
import "core:testing"

@(test)
test_entity_handles :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)

	handle, entity := create_entity(scene, "Thing")
	testing.expect(test, handle.index != 0, "slot 0 is reserved for the nil entity")
	found_entity, found := get_entity(scene, handle)
	testing.expect(test, found && found_entity == entity, "a fresh handle finds its entity")

	destroy_entity(scene, handle)
	nil_entity, still_found := get_entity(scene, handle)
	testing.expect(test, !still_found && nil_entity == &scene.entities[0], "a stale handle gives the nil entity")

	reused_handle, _ := create_entity(scene, "Other")
	testing.expect(test, reused_handle.index == handle.index && reused_handle.generation != handle.generation, "a reused slot gets a new generation")
	_, old_found := get_entity(scene, handle)
	testing.expect(test, !old_found, "the old handle must not see the new entity")
}

@(test)
test_unique_names :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)

	create_entity(scene, unique_entity_name(scene, "Cube"))
	testing.expect_value(test, unique_entity_name(scene, "Cube"), "Cube (1)")
	create_entity(scene, "Cube (1)")
	// Duplicating "Cube (1)" continues the numbering instead of nesting suffixes.
	testing.expect_value(test, unique_entity_name(scene, "Cube (1)"), "Cube (2)")
	// Parentheses that aren't a number suffix are part of the name.
	testing.expect_value(test, strip_number_suffix("Lamp (old)"), "Lamp (old)")

	// A name at the 48-byte limit: repeated duplication must still give distinct names, all of
	// which fit the buffer exactly as checked.
	long_name := strings.repeat("x", ENTITY_NAME_BYTES, context.temp_allocator)
	names := make(map[string]bool, allocator = context.temp_allocator)
	for _ in 0 ..< 20 {
		name := unique_entity_name(scene, long_name)
		testing.expectf(test, len(name) <= ENTITY_NAME_BYTES, "%q is longer than the name buffer", name)
		_, entity := create_entity(scene, name)
		stored := entity_name(entity)
		testing.expectf(test, stored == name, "stored name %q differs from the checked name %q", stored, name)
		testing.expectf(test, !names[stored], "duplicate name %q", stored)
		names[strings.clone(stored, context.temp_allocator)] = true
	}

	// Truncation never splits a multi-byte character ("é" is 2 bytes).
	testing.expect_value(test, truncate_utf8("café", 4), "caf")
}
