// Tests for scene bookkeeping that needs no GPU: entity handles and names.
// Run with `build.bat test`.
package game

import "core:fmt"
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
	// The smallest free number is used, so a gap is filled.
	create_entity(scene, "Cube (3)")
	testing.expect_value(test, unique_entity_name(scene, "Cube"), "Cube (2)")
	// Only a suffix written as a candidate would be takes a number: "Cube (02)" isn't "Cube (2)".
	create_entity(scene, "Cube (02)")
	testing.expect_value(test, unique_entity_name(scene, "Cube"), "Cube (2)")
	// A base that itself ends in a number suffix: "Box (1)" is its unsuffixed candidate.
	create_entity(scene, "Box (1)")
	testing.expect_value(test, unique_entity_name(scene, "Box (1) (5)"), "Box (1) (1)")
	// The entity being renamed doesn't take its own name.
	own_handle, _ := create_entity(scene, "Lamp")
	testing.expect_value(test, unique_entity_name(scene, "Lamp", own_handle), "Lamp")
	// Many numbered names: the next one after them all.
	for number in 4 ..< 1000 {
		create_entity(scene, fmt.tprintf("Cube (%d)", number))
	}
	create_entity(scene, "Cube (2)")
	testing.expect_value(test, unique_entity_name(scene, "Cube (500)"), "Cube (1000)")

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

@(test)
test_rename_is_one_undo_step :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)
	history := new(Undo_History)
	defer free(history)

	handle, entity := create_entity(scene, "Cube (1)")
	reset_undo_history(history, scene)

	// A shorter name clears the old tail, so renaming back gives the original bytes: undo sees
	// no difference, and a round trip leaves nothing to record.
	set_entity_name(entity, "Cu")
	testing.expect_value(test, entity_name(entity), "Cu")
	testing.expect(test, entity.name_bytes[2] == 0, "the old name's tail is cleared")
	set_entity_name(entity, "Cube (1)")
	testing.expect(test, !commit_undo_step(history, scene), "renaming back and forth is no change")

	set_entity_name(entity, "Crate")
	testing.expect(test, commit_undo_step(history, scene), "a rename is an undo step")
	undo(history, scene)
	renamed, _ := get_entity(scene, handle)
	testing.expect_value(test, entity_name(renamed), "Cube (1)")
	redo(history, scene)
	testing.expect_value(test, entity_name(renamed), "Crate")
}

@(test)
test_check_entity_name :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)
	cube_handle, _ := create_entity(scene, "Cube")
	sphere_handle, _ := create_entity(scene, "Sphere")

	check :: proc(scene: ^Scene, entity: Entity_Handle, typed: string) -> (final_name: string, message: string, blocked: bool) {
		return check_entity_name(scene, entity, typed)
	}

	// Spaces at either end are dropped quietly.
	final_name, message, blocked := check(scene, sphere_handle, "  Ball  ")
	testing.expect(test, final_name == "Ball" && message == "" && !blocked, "trimmed, no message")

	// Empty, or only spaces: can't be used.
	_, message, blocked = check(scene, sphere_handle, "")
	testing.expect(test, blocked && message != "", "an empty name is blocked, with a reason")
	_, _, blocked = check(scene, sphere_handle, "   ")
	testing.expect(test, blocked, "a name of only spaces is blocked")

	// Letters of any script, digits, spaces and _ - . ( ) are fine; anything else is blocked and
	// named in the message.
	final_name, _, blocked = check(scene, sphere_handle, "Café_2-b.(old)")
	testing.expect(test, final_name == "Café_2-b.(old)" && !blocked, "allowed characters pass, accents included")
	_, message, blocked = check(scene, sphere_handle, "Ball/2")
	testing.expectf(test, blocked && strings.contains(message, "\"/\""), "a slash is blocked and named (%q)", message)
	_, _, blocked = check(scene, sphere_handle, "Ball\t2")
	testing.expect(test, blocked, "a tab inside the name is blocked")

	// Another entity's name gets the next free suffix, said in a note that doesn't block.
	final_name, message, blocked = check(scene, sphere_handle, "Cube")
	testing.expect(test, final_name == "Cube (1)" && !blocked && strings.contains(message, "Cube (1)"), "a taken name becomes unique, with a note")

	// Keeping one's own name (or typing it again with spaces) isn't a clash.
	final_name, message, blocked = check(scene, cube_handle, " Cube ")
	testing.expect(test, final_name == "Cube" && message == "" && !blocked, "an entity's own name isn't taken")

	// The suffix search skips the renamed entity too: renaming the Cube to "Sphere" gives
	// "Sphere (1)", and nothing counts the Cube's old name.
	final_name, _, _ = check(scene, cube_handle, "Sphere")
	testing.expect_value(test, final_name, "Sphere (1)")
	free_all(context.temp_allocator)
}
