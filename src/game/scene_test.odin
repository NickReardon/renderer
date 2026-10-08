// Tests for scene bookkeeping that needs no GPU: entity handles, names, ids and order keys.
// Run with `build.bat test`.
package game

import "core:fmt"
import "core:strings"
import "core:testing"
import "engine:core"

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
	// Combining marks after a letter are part of it (found in review of #24): a Hindi vowel sign
	// (U+093F, a spacing mark) and a decomposed accent (U+0301, a nonspacing mark).
	final_name, _, blocked = check(scene, sphere_handle, "किरण") // किरण
	testing.expect(test, final_name == "किरण" && !blocked, "a Hindi name with a vowel sign passes")
	final_name, _, blocked = check(scene, sphere_handle, "Café")
	testing.expect(test, final_name == "Café" && !blocked, "a decomposed accent passes")
	_, message, blocked = check(scene, sphere_handle, "́Cafe")
	testing.expectf(test, blocked && strings.contains(message, "start"), "a name can't start with a mark (%q)", message)
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

@(test)
test_entity_ids_and_order_keys :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)

	first_handle, first := create_entity(scene, "First")
	second_handle, second := create_entity(scene, "Second")
	_, third := create_entity(scene, "Third")
	testing.expect(test, first.id != 0 && second.id != 0 && third.id != 0, "ids are never 0")
	testing.expect(test, first.id != second.id && second.id != third.id && first.id != third.id, "every entity has its own id")
	testing.expect_value(test, entity_order_key(first), "a0")
	testing.expect_value(test, entity_order_key(second), "a1")
	testing.expect_value(test, entity_order_key(third), "a2")

	// A new entity goes last in the Hierarchy, even into the slot a deleted one freed.
	destroy_entity(scene, second_handle)
	reused_handle, reused := create_entity(scene, "Fourth")
	testing.expect(test, reused_handle.index == second_handle.index, "the freed slot is reused")
	testing.expect_value(test, entity_order_key(reused), "a3")

	// Duplicate makes a new entity: its own id, last in the Hierarchy, the rest copied.
	first.position = {1, 2, 3}
	copy_handle := duplicate_entity(scene, first_handle)
	copy_entity, _ := get_entity(scene, copy_handle)
	testing.expect(test, copy_entity.id != 0 && copy_entity.id != first.id, "a duplicate gets a fresh id")
	testing.expect_value(test, entity_order_key(copy_entity), "a4")
	testing.expect_value(test, copy_entity.position, [3]f32{1, 2, 3})
	testing.expect_value(test, entity_name(copy_entity), "First (1)")
}

@(test)
test_undo_keeps_entity_ids :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)
	history := new(Undo_History)
	defer free(history)

	handle, entity := create_entity(scene, "Cube")
	id := entity.id
	reset_undo_history(history, scene)

	// Undoing a delete brings the entity back with the same id and key, not new ones.
	destroy_entity(scene, handle)
	testing.expect(test, commit_undo_step(history, scene), "a delete is an undo step")
	undo(history, scene)
	restored, found := get_entity(scene, handle)
	testing.expect(test, found && restored.id == id, "undoing a delete restores the original id")
	testing.expect_value(test, entity_order_key(restored), "a0")

	// Redoing a create brings back the id the entity was created with.
	created_handle, created := create_entity(scene, "Sphere")
	created_id := created.id
	testing.expect(test, commit_undo_step(history, scene), "a create is an undo step")
	undo(history, scene)
	redo(history, scene)
	redone, redone_found := get_entity(scene, created_handle)
	testing.expect(test, redone_found && redone.id == created_id, "redoing a create restores its id")
}

@(test)
test_order_keys_renumber_when_there_is_no_room :: proc(test: ^testing.T) {
	scene := new(Scene)
	defer free(scene)

	_, first := create_entity(scene, "First")
	_, second := create_entity(scene, "Second")
	// A hand-edited file can hold a key with no room after it in 32 bytes: the largest integer
	// with a fraction of all 'z's. Then every entity gets a short key again, in the same order.
	longest := strings.concatenate({"z", strings.repeat("z", 26, context.temp_allocator), "zzzzz"}, context.temp_allocator)
	testing.expect(test, len(longest) == core.ORDER_KEY_MAX_BYTES && core.order_key_is_valid(longest), "the test key is valid and as long as allowed")
	set_entity_order_key(second, longest)
	_, third := create_entity(scene, "Third")
	testing.expect_value(test, entity_order_key(first), "a0")
	testing.expect_value(test, entity_order_key(second), "a1")
	testing.expect_value(test, entity_order_key(third), "a2")
	free_all(context.temp_allocator)
}
