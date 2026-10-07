// Single-line text editing, shared by every widget that takes typing (text boxes and number
// boxes). Only one widget edits at a time, so the text being edited lives in Ui_State, not in
// the widget: `edit_buffer[:edit_length]`, with a caret and a selection.
//
// Caret and selection are two byte offsets into the buffer, the way most editors store them:
//   - `edit_caret` is where typing goes and where the blinking line is drawn;
//   - `edit_anchor` is the other end of the selection. Equal to the caret: nothing selected.
// Shift+arrows move only the caret, so the selection grows from the anchor; plain arrows move
// both. Selecting everything is anchor 0, caret at the end.
//
// Offsets are in bytes of UTF-8 and always sit on a character boundary: the caret steps over
// whole characters, and inserted text is whole characters. (One "character" here is one Unicode
// code point; combining accents and emoji sequences take several steps, as in simple editors.)
//
// Keys: Left / Right, Home / End (with Shift to select), Backspace / Delete, Ctrl+A select all.
// The mouse: a press in the text puts the caret there, and dragging selects.
// Not yet: clipboard (Ctrl+C / X / V needs the host to pass clipboard text), word jumps
// (Ctrl+arrows), double-click to select a word, and scrolling text longer than its box.
package ui

import "core:unicode/utf8"
import fontstash "vendor:fontstash"
import "engine:platform"
import clay "engine:third_party/clay"

// The element holding the text being edited. Only one widget edits at a time, so one fixed id
// is enough; the widget's mouse handling asks for its rectangle from the last layout.
EDIT_TEXT_ID :: "ui edited text"

// Starts editing with `initial_text` (cut to fit), all of it selected.
@(private)
begin_text_edit :: proc(state: ^Ui_State, widget_id: u32, initial_text: string, maximum_bytes: int) {
	state.edit_id = widget_id
	state.edit_maximum_bytes = clamp(maximum_bytes, 0, MAX_EDIT_BYTES)
	fitted := truncate_to_character(initial_text, state.edit_maximum_bytes)
	state.edit_length = copy(state.edit_buffer[:], fitted)
	state.edit_anchor = 0
	state.edit_caret = state.edit_length
	state.scroll_to_edit = true
	state.edit_widget_drawn = true // Shift+Tab starts an already drawn box; it counts as drawn
}

// The text being edited. Valid until the next edit; copy it to keep it.
edited_text :: proc(state: ^Ui_State) -> string {
	return string(state.edit_buffer[:state.edit_length])
}

// The selected byte range, start <= end (equal when nothing is selected).
selection_range :: proc(state: ^Ui_State) -> (start, end: int) {
	return min(state.edit_anchor, state.edit_caret), max(state.edit_anchor, state.edit_caret)
}

all_text_selected :: proc(state: ^Ui_State) -> bool {
	start, end := selection_range(state)
	return start == 0 && end == state.edit_length && end > 0
}

// Applies this frame's typing and editing keys to the text being edited. `numbers_only` accepts
// only characters that can appear in a number. Returns Enter (apply) and Escape (cancel).
@(private)
edit_text :: proc(state: ^Ui_State, numbers_only: bool) -> (commit, cancel: bool) {
	keys := &state.input.keys
	shift_held := keys[.Left_Shift].down || keys[.Right_Shift].down
	ctrl_held := keys[.Left_Ctrl].down || keys[.Right_Ctrl].down
	key_fired :: proc(key: platform.Button) -> bool {
		return key.pressed || key.repeated // held keys repeat at the OS's rate
	}

	for character in platform.input_text(&state.input) {
		accepted: bool
		if numbers_only {
			accepted = (character >= '0' && character <= '9') || character == '.' || character == '-' || character == '+' || character == 'e' || character == 'E'
		} else {
			accepted = character >= ' ' && character != 0x7F // no control characters
		}
		if accepted {
			insert_character(state, character)
		}
	}

	if key_fired(keys[.Backspace]) {
		start, end := selection_range(state)
		if start == end {
			start = previous_character_start(state, start)
		}
		delete_bytes(state, start, end)
	}
	if key_fired(keys[.Delete]) {
		start, end := selection_range(state)
		if start == end {
			end = next_character_start(state, end)
		}
		delete_bytes(state, start, end)
	}

	// Moving the caret. Without Shift, an arrow with a selection goes to that end of it.
	new_caret := state.edit_caret
	moved := false
	start, end := selection_range(state)
	if key_fired(keys[.Left]) {
		new_caret = start if start != end && !shift_held else previous_character_start(state, state.edit_caret)
		moved = true
	}
	if key_fired(keys[.Right]) {
		new_caret = end if start != end && !shift_held else next_character_start(state, state.edit_caret)
		moved = true
	}
	if key_fired(keys[.Home]) {
		new_caret = 0
		moved = true
	}
	if key_fired(keys[.End]) {
		new_caret = state.edit_length
		moved = true
	}
	if moved {
		state.edit_caret = new_caret
		if !shift_held {
			state.edit_anchor = new_caret
		}
	}
	if ctrl_held && keys[.A].pressed {
		state.edit_anchor = 0
		state.edit_caret = state.edit_length
	}

	commit = keys[.Enter].pressed
	cancel = keys[.Escape].pressed
	return
}

// Mouse handling inside the widget being edited: a press puts the caret under the pointer
// (Shift+press extends the selection to it) and dragging selects. Positions come from the last
// frame's layout, like all hit testing.
@(private)
place_caret_with_mouse :: proc(state: ^Ui_State, interaction: Interaction, font: Font) {
	if !interaction.pressed && !interaction.held {
		return
	}
	text_element := clay.GetElementData(clay.ID(EDIT_TEXT_ID))
	if !text_element.found {
		return
	}
	pointer_x := state.input.mouse_position.x - text_element.boundingBox.x
	caret := caret_at_x(state, font, pointer_x)
	shift_held := state.input.keys[.Left_Shift].down || state.input.keys[.Right_Shift].down
	state.edit_caret = caret
	if interaction.pressed && !shift_held {
		state.edit_anchor = caret
	}
}

// The character boundary nearest to `x` points from the start of the text, found by measuring
// each prefix of the text with the same font the text is drawn with.
@(private)
caret_at_x :: proc(state: ^Ui_State, font: Font, x: f32) -> int {
	text := edited_text(state)
	set_font(state, font, points(state, FONT_SIZE), 0)
	best_offset, best_distance := 0, abs(x)
	for offset in 1 ..= len(text) {
		if offset < len(text) && !utf8.rune_start(text[offset]) {
			continue
		}
		distance := abs(fontstash.TextBounds(&state.font_context, text[:offset]) - x)
		if distance < best_distance {
			best_offset, best_distance = offset, distance
		}
	}
	return best_offset
}

// Draws the text being edited: the part before the selection, the selection on a highlight,
// the part after, and the caret at its end of the selection. The pieces sit side by side with
// no gap, so they read as one string.
@(private)
draw_edited_text :: proc(state: ^Ui_State, font: Font) {
	text := edited_text(state)
	start, end := selection_range(state)
	clay._OpenElementWithId(clay.ID(EDIT_TEXT_ID))
	clay.ConfigureOpenElement({layout = {sizing = {width = clay.SizingFit(), height = clay.SizingGrow()}, childAlignment = {y = .Center}}})
	if state.edit_caret == start {
		draw_caret(state)
	}
	if start > 0 {
		text_piece(state, text[:start], font)
	}
	if end > start {
		clay._OpenElement()
		clay.ConfigureOpenElement({
			layout          = {sizing = {height = clay.SizingFixed(points(state, FONT_SIZE + 4))}, childAlignment = {y = .Center}},
			backgroundColor = state.theme.text_selection,
		})
		text_piece(state, text[start:end], font)
		clay._CloseElement()
		if state.edit_caret == end {
			draw_caret(state)
		}
	}
	if end < len(text) {
		text_piece(state, text[end:], font)
	}
	clay._CloseElement()

	text_piece :: proc(state: ^Ui_State, piece: string, font: Font) {
		// Clay keeps a pointer to the string until end_frame; the edit buffer may change before
		// then (a later widget can start editing), so draw a per-frame copy.
		text(state, clone_for_frame(piece), font)
	}
	draw_caret :: proc(state: ^Ui_State) {
		clay._OpenElement()
		clay.ConfigureOpenElement({
			layout          = {sizing = {width = clay.SizingFixed(max(points(state, 1), 1)), height = clay.SizingFixed(points(state, FONT_SIZE + 2))}},
			backgroundColor = state.theme.text,
		})
		clay._CloseElement()
	}
}

@(private)
insert_character :: proc(state: ^Ui_State, character: rune) {
	start, end := selection_range(state)
	delete_bytes(state, start, end)
	encoded, encoded_length := utf8.encode_rune(character)
	if state.edit_length + encoded_length > state.edit_maximum_bytes {
		return // full: the character doesn't fit
	}
	caret := state.edit_caret
	copy(state.edit_buffer[caret + encoded_length:], state.edit_buffer[caret:state.edit_length])
	copy(state.edit_buffer[caret:], encoded[:encoded_length])
	state.edit_length += encoded_length
	state.edit_caret += encoded_length
	state.edit_anchor = state.edit_caret
}

// Removes bytes [start, end) and leaves the caret where they were.
@(private)
delete_bytes :: proc(state: ^Ui_State, start, end: int) {
	assert(0 <= start && start <= end && end <= state.edit_length)
	copy(state.edit_buffer[start:], state.edit_buffer[end:state.edit_length])
	state.edit_length -= end - start
	state.edit_caret = start
	state.edit_anchor = start
}

// UTF-8 continuation bytes look like 10xxxxxx; a character starts at any other byte.
@(private)
previous_character_start :: proc(state: ^Ui_State, offset: int) -> int {
	offset := offset
	for offset > 0 {
		offset -= 1
		if utf8.rune_start(state.edit_buffer[offset]) {
			break
		}
	}
	return offset
}

@(private)
next_character_start :: proc(state: ^Ui_State, offset: int) -> int {
	offset := offset
	for offset < state.edit_length {
		offset += 1
		if offset == state.edit_length || utf8.rune_start(state.edit_buffer[offset]) {
			break
		}
	}
	return offset
}

// The longest prefix of `text` that fits in `maximum_bytes` without cutting a character apart.
@(private)
truncate_to_character :: proc(text: string, maximum_bytes: int) -> string {
	if len(text) <= maximum_bytes {
		return text
	}
	end := maximum_bytes
	for end > 0 && !utf8.rune_start(text[end]) {
		end -= 1
	}
	return text[:end]
}

@(private)
clone_for_frame :: proc(text: string) -> string {
	bytes := make([]u8, len(text), context.temp_allocator)
	copy(bytes, text)
	return string(bytes)
}
