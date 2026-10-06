// Undo and redo (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z, as in Unity on Windows).
//
// How it works: diffing against a copy, not commands.
//   - The history keeps `committed`, a copy of the entity pool as it was after the last undo
//     step. Once per frame, when no edit is in progress, `commit_undo_step` compares the live
//     pool with that copy. The slots that differ become one step: the whole Entity before and
//     after, for each changed slot.
//   - Undo writes the "before" values back; redo writes the "after" values.
//   - Nothing that edits entities knows about undo. The Inspector, the gizmo, Create, Delete and
//     Ctrl+D are all recorded the same way, and a new tagged field is undoable for free. That
//     works because the editor's data is one flat pool of plain structs (docs/ENTITIES.md).
//
// What counts as one step:
//   - Changes are only committed while the left mouse button is up and no text field is being
//     typed into, so a whole gizmo or number-field drag becomes one step, recorded on release.
//   - Selection-only changes don't make a step (clicking around shouldn't fill the history),
//     but a step stores each touched entity's selection, and applying it restores the selection
//     to exactly the touched entities that were selected then. Undoing a move reselects what
//     was moved; undoing a duplicate reselects the originals.
//
// Memory: fixed arrays inside Game_Memory, so the history survives hot reload with no
// allocator involved. When it's full, the oldest steps are dropped.
package game

import "core:fmt"
import "core:mem"

MAX_UNDO_STEPS   :: 256
MAX_UNDO_RECORDS :: 8192 // changed entities across all steps; one Delete of N objects uses N

Undo_Record :: struct {
	slot_index: u32,
	before:     Entity,
	after:      Entity,
}

Undo_Step :: struct {
	first_record: int,
	record_count: int,
}

Undo_History :: struct {
	committed:     [MAX_ENTITIES]Entity, // the pool as of the last step (or the last undo/redo)
	steps:         [MAX_UNDO_STEPS]Undo_Step,
	step_count:    int, // steps recorded, including undone ones that redo can bring back
	applied_count: int, // steps currently applied; steps[applied_count:step_count] are redoable
	records:       [MAX_UNDO_RECORDS]Undo_Record,
	record_count:  int,
}

// Forgets all steps and takes the scene as it is now as the starting point. Call it after
// building the starting scene, or that whole scene would become the first undoable step.
reset_undo_history :: proc(history: ^Undo_History, scene: ^Scene) {
	history.step_count = 0
	history.applied_count = 0
	history.record_count = 0
	history.committed = scene.entities
}

// Records everything that changed since the last step as one new step. Returns true if a step
// was recorded. Call once per frame, only when no edit is in progress.
commit_undo_step :: proc(history: ^Undo_History, scene: ^Scene) -> (recorded: bool) {
	// First pass: does anything differ, and does anything besides selection differ?
	changed_count := 0
	any_change_besides_selection := false
	for slot_index in 1 ..= scene.highest_entity_slot {
		live := &scene.entities[slot_index]
		committed := &history.committed[slot_index]
		if entities_equal(live, committed) {
			continue
		}
		changed_count += 1
		if !entities_equal_ignoring_selection(live, committed) {
			any_change_besides_selection = true
		}
	}
	if changed_count == 0 {
		return false
	}
	if !any_change_besides_selection {
		// Only the selection changed: take it in without making a step.
		copy(history.committed[1:scene.highest_entity_slot + 1], scene.entities[1:scene.highest_entity_slot + 1])
		return false
	}

	// A new edit ends the redo branch, as in every editor.
	history.step_count = history.applied_count
	history.record_count = 0
	if history.step_count > 0 {
		last_step := history.steps[history.step_count - 1]
		history.record_count = last_step.first_record + last_step.record_count
	}

	if changed_count > MAX_UNDO_RECORDS {
		// Too big to record. The edit stays, but the history before it no longer matches the
		// scene, so it's dropped.
		fmt.eprintfln("game: an edit changed %d objects, more than undo can hold (%d); the undo history was cleared", changed_count, MAX_UNDO_RECORDS)
		reset_undo_history(history, scene)
		return false
	}
	for history.step_count == MAX_UNDO_STEPS || history.record_count + changed_count > MAX_UNDO_RECORDS {
		drop_oldest_undo_step(history)
	}

	// Second pass: record every changed slot (selection changes included, so applying the step
	// can restore the selection), and bring the committed copy up to date.
	step := Undo_Step{first_record = history.record_count, record_count = changed_count}
	for slot_index in 1 ..= scene.highest_entity_slot {
		live := &scene.entities[slot_index]
		committed := &history.committed[slot_index]
		if entities_equal(live, committed) {
			continue
		}
		history.records[history.record_count] = {slot_index = u32(slot_index), before = committed^, after = live^}
		history.record_count += 1
		committed^ = live^
	}
	ensure(history.record_count == step.first_record + step.record_count, "undo: the two passes disagree on what changed")
	history.steps[history.step_count] = step
	history.step_count += 1
	history.applied_count = history.step_count
	return true
}

// Returns false when there is nothing to undo.
undo :: proc(history: ^Undo_History, scene: ^Scene) -> bool {
	if history.applied_count == 0 {
		return false
	}
	history.applied_count -= 1
	apply_undo_step(history, scene, history.steps[history.applied_count], use_after = false)
	return true
}

// Returns false when there is nothing to redo.
redo :: proc(history: ^Undo_History, scene: ^Scene) -> bool {
	if history.applied_count == history.step_count {
		return false
	}
	apply_undo_step(history, scene, history.steps[history.applied_count], use_after = true)
	history.applied_count += 1
	return true
}

// Writes one side of a step into the scene (and the committed copy, so it isn't seen as a new
// edit), then sets the selection to the touched entities that were selected on that side.
@(private = "file")
apply_undo_step :: proc(history: ^Undo_History, scene: ^Scene, step: Undo_Step, use_after: bool) {
	clear_selection(scene)
	for record in history.records[step.first_record:][:step.record_count] {
		slot_index := int(record.slot_index)
		entity := record.after if use_after else record.before
		// Restored whole, generation included: an entity brought back by undo keeps its handle,
		// so references to it work again. create_entity numbers generations from
		// scene.slot_generations, so a handle is still never reused for a different entity.
		scene.entities[slot_index] = entity
		scene.highest_entity_slot = max(scene.highest_entity_slot, slot_index)
	}
	copy(history.committed[1:scene.highest_entity_slot + 1], scene.entities[1:scene.highest_entity_slot + 1])
}

@(private = "file")
drop_oldest_undo_step :: proc(history: ^Undo_History) {
	ensure(history.step_count > 0, "undo: nothing left to drop")
	dropped_records := history.steps[0].record_count
	copy(history.records[:], history.records[dropped_records:history.record_count])
	history.record_count -= dropped_records
	copy(history.steps[:], history.steps[1:history.step_count])
	history.step_count -= 1
	history.applied_count = max(history.applied_count - 1, 0)
	for &step in history.steps[:history.step_count] {
		step.first_record -= dropped_records
	}
}

// Byte comparison: exact, and it never misses a field added later. Padding bytes only change
// when a whole entity is written, which is a real change anyway.
@(private = "file")
entities_equal :: proc(first, second: ^Entity) -> bool {
	return mem.compare_ptrs(first, second, size_of(Entity)) == 0
}

// Compares in place (the bytes before `flags`, `flags` without .Selected, the bytes after), so
// no copies are made whose padding could differ.
@(private = "file")
entities_equal_ignoring_selection :: proc(first, second: ^Entity) -> bool {
	flags_start := int(offset_of(Entity, flags))
	flags_end := flags_start + size_of(first.flags)
	first_bytes := ([^]u8)(first)
	second_bytes := ([^]u8)(second)
	return mem.compare_ptrs(first_bytes, second_bytes, flags_start) == 0 &&
		first.flags - {.Selected} == second.flags - {.Selected} &&
		mem.compare_ptrs(first_bytes[flags_end:], second_bytes[flags_end:], size_of(Entity) - flags_end) == 0
}

// For the Statistics panel and tests.
undo_counts :: proc(history: ^Undo_History) -> (undoable, redoable: int) {
	return history.applied_count, history.step_count - history.applied_count
}
