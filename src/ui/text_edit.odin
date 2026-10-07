// Single-line text editing, shared by every widget that takes typing (text boxes and number
// boxes). Only one widget edits at a time, so the text being edited lives in Ui_State, not in
// the widget.
//
// Two halves:
//
// Editing (what keys and the mouse do to the text and the selection) is Odin's core:text/edit,
// which follows rxi's "Textbox behaviour" and "A simple undo system" (docs/REFERENCES.md). We
// translate our input into its commands:
//   Left / Right, Home / End          move; with Shift, select; with Ctrl, by word
//   Backspace / Delete                delete a character, or the selection; with Ctrl, a word
//   Ctrl+A                            select all
//   Ctrl+C / Ctrl+X / Ctrl+V          copy / cut / paste (through the host; see platform.Output)
//   Ctrl+Z / Ctrl+Y (Ctrl+Shift+Z)    undo / redo inside the box; typing within 0.3 s is one step
//   the mouse                         press: caret; drag: select; double-click: a word (drag
//                                     extends by words); triple-click: everything
// The selection is two byte offsets, `selection[0]` (the head, where the caret is) and
// `selection[1]` (the anchor); equal means nothing is selected. Offsets stay on character
// boundaries: the text's capacity is fixed (edit_buffer, the box's own limit), and core:text/edit
// never cuts a character in half when the text is full.
//
// Drawing and hit testing: Clay lays out the box with one empty "custom" element where the text
// goes. Its contents are drawn here (draw_edited_text, called from end_frame), from one list of
// character positions, `edit_caret_x`, measured with the same fontstash calls that place the
// glyphs. The text, the selection highlight, the caret, mouse clicks and scrolling all read that
// one list, so they can't disagree. (The first version laid the text out as separate Clay
// pieces around the selection and caret, each snapped to whole pixels: letters shifted when the
// selection moved, and clicks could land a character off.) Text wider than the box scrolls
// sideways to keep the caret in view.
//
// Hot reload: core:text/edit's State and the strings.Builder hold allocators, which contain
// procedure pointers, and Ui_State lives in Game_Memory, which survives a reload. So they're
// refreshed at the start of every use (refresh_edit_pointers) and never trusted from a previous
// frame. The allocator for undo history is the context's, which the host provides and which
// doesn't unload.
package ui

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:strings"
import text_edit "core:text/edit"
import "core:unicode/utf8"
import fontstash "vendor:fontstash"
import "engine:platform"
import "engine:render"
import clay "engine:third_party/clay"

// The element holding the text being edited. Only one widget edits at a time, so one fixed id
// is enough; the widget's mouse handling asks for its rectangle from the last layout.
EDIT_TEXT_ID :: "ui edited text"

CARET_BLINK_SECONDS  :: 0.53 // on, then off for as long (Windows' default)
DOUBLE_CLICK_SECONDS :: 0.4
DOUBLE_CLICK_POINTS  :: 4    // the second press must be this close to the first

// Starts editing with `initial_text` (cut to fit `maximum_bytes`), all of it selected.
@(private)
begin_text_edit :: proc(state: ^Ui_State, widget_id: u32, initial_text: string, maximum_bytes: int, font: Font) {
	if state.edit_id != 0 {
		finish_text_edit(state) // another box was being typed into
	}
	limit := clamp(maximum_bytes, 0, MAX_EDIT_BYTES)
	state.edit_builder = strings.builder_from_bytes(state.edit_buffer[:limit])
	strings.write_string(&state.edit_builder, truncate_to_character(initial_text, limit))
	state.edit_id = widget_id
	refresh_edit_pointers(state)
	text_edit.begin(&state.edit_state, u64(widget_id), &state.edit_builder) // selects all, clears undo
	// The first change in this box is always its own undo step, however soon after typing in another
	// box it comes (core:text/edit groups changes less than 0.3 s apart, and would count from there).
	state.edit_state.last_edit_time = {}
	state.edit_font = font
	state.edit_scroll_x = 0
	state.edit_blink_seconds = 0
	state.scroll_to_edit = true
	state.edit_widget_drawn = true // Shift+Tab starts an already drawn box; it counts as drawn
}

// Stops editing and frees the box's undo history.
@(private)
finish_text_edit :: proc(state: ^Ui_State) {
	refresh_edit_pointers(state)
	text_edit.undo_clear(&state.edit_state, &state.edit_state.undo)
	text_edit.undo_clear(&state.edit_state, &state.edit_state.redo)
	text_edit.end(&state.edit_state)
	state.edit_id = 0
}

// Points the edit state's allocators and builder at this frame's code and data (see the hot
// reload note at the top of the file).
@(private)
refresh_edit_pointers :: proc(state: ^Ui_State) {
	(^runtime.Raw_Dynamic_Array)(&state.edit_builder.buf).allocator = runtime.nil_allocator() // fixed capacity
	edit := &state.edit_state
	edit.builder = &state.edit_builder if state.edit_id != 0 else nil
	edit.undo_text_allocator = context.allocator
	edit.undo.allocator = context.allocator
	edit.redo.allocator = context.allocator
	if edit.undo_timeout <= 0 {
		edit.undo_timeout = text_edit.DEFAULT_UNDO_TIMEOUT
	}
}

// The text being edited. Valid until the next edit; copy it to keep it.
edited_text :: proc(state: ^Ui_State) -> string {
	return strings.to_string(state.edit_builder)
}

// The selected byte range, start <= end (equal when nothing is selected).
selection_range :: proc(state: ^Ui_State) -> (start, end: int) {
	head, anchor := state.edit_state.selection[0], state.edit_state.selection[1]
	return min(head, anchor), max(head, anchor)
}

// Where the caret is: a byte offset.
edit_caret :: proc(state: ^Ui_State) -> int {
	return state.edit_state.selection[0]
}

all_text_selected :: proc(state: ^Ui_State) -> bool {
	start, end := selection_range(state)
	return start == 0 && end == len(edited_text(state)) && end > 0
}

// Applies this frame's typing and editing keys to the text being edited. `numbers_only` accepts
// only characters that can appear in a number. Returns Enter (apply) and Escape (cancel).
@(private)
edit_text :: proc(state: ^Ui_State, numbers_only: bool) -> (commit, cancel: bool) {
	refresh_edit_pointers(state)
	edit := &state.edit_state
	text_edit.update_time(edit)
	keys := &state.input.keys
	shift_held := keys[.Left_Shift].down || keys[.Right_Shift].down
	ctrl_held := keys[.Left_Ctrl].down || keys[.Right_Ctrl].down
	fired :: proc(key: platform.Button) -> bool {
		return key.pressed || key.repeated // held keys repeat at the OS's rate
	}
	acted := false
	run :: proc(edit: ^text_edit.State, command: text_edit.Command, acted: ^bool) {
		text_edit.perform_command(edit, command)
		acted^ = true
	}

	for character in platform.input_text(&state.input) {
		if character_accepted(character, numbers_only) {
			text_edit.input_rune(edit, character)
			acted = true
		}
	}

	// Each key picks a command from the modifiers held: Shift selects, Ctrl goes by word.
	if fired(keys[.Left]) {
		run(edit, by_modifiers(shift_held, ctrl_held, .Left, .Word_Left, .Select_Left, .Select_Word_Left), &acted)
	}
	if fired(keys[.Right]) {
		run(edit, by_modifiers(shift_held, ctrl_held, .Right, .Word_Right, .Select_Right, .Select_Word_Right), &acted)
	}
	if fired(keys[.Home]) {
		run(edit, .Select_Start if shift_held else .Start, &acted)
	}
	if fired(keys[.End]) {
		run(edit, .Select_End if shift_held else .End, &acted)
	}
	if fired(keys[.Backspace]) {
		run(edit, .Delete_Word_Left if ctrl_held else .Backspace, &acted)
	}
	if fired(keys[.Delete]) {
		run(edit, .Delete_Word_Right if ctrl_held else .Delete, &acted)
	}
	if ctrl_held {
		if keys[.A].pressed {
			run(edit, .Select_All, &acted)
		}
		if fired(keys[.Z]) && !shift_held {
			run(edit, .Undo, &acted)
		}
		if fired(keys[.Y]) || (fired(keys[.Z]) && shift_held) {
			run(edit, .Redo, &acted)
		}
		// Copy, cut and paste go through the host's clipboard ourselves rather than through
		// core:text/edit's callbacks, which would be procedure pointers kept in Game_Memory.
		if keys[.C].pressed || keys[.X].pressed {
			if selected := text_edit.current_selected_text(edit); selected != "" {
				request_clipboard(state, selected)
				if keys[.X].pressed {
					text_edit.selection_delete(edit)
				}
				acted = true
			}
		}
		if fired(keys[.V]) {
			// One line of the clipboard, with characters this box doesn't take left out.
			pasted: [platform.MAX_CLIPBOARD_BYTES]u8
			pasted_length := 0
			for character in platform.input_clipboard_text(&state.input) {
				if character == '\n' || character == '\r' {
					break
				}
				if character_accepted(character, numbers_only) {
					encoded, encoded_length := utf8.encode_rune(character)
					if pasted_length + encoded_length > len(pasted) {
						break
					}
					pasted_length += copy(pasted[pasted_length:], encoded[:encoded_length])
				}
			}
			text_edit.input_text(edit, string(pasted[:pasted_length]))
			acted = true
		}
	}
	if acted {
		state.edit_blink_seconds = 0 // the caret shows at once after any change
	}

	measure_edited_text(state)
	keep_caret_visible(state)
	commit = keys[.Enter].pressed
	cancel = keys[.Escape].pressed
	return

	by_modifiers :: proc(shift_held, ctrl_held: bool, plain, word, select, select_word: text_edit.Command) -> text_edit.Command {
		if shift_held {
			return select_word if ctrl_held else select
		}
		return word if ctrl_held else plain
	}
	character_accepted :: proc(character: rune, numbers_only: bool) -> bool {
		if numbers_only {
			return (character >= '0' && character <= '9') || character == '.' || character == '-' || character == '+' || character == 'e' || character == 'E'
		}
		return character >= ' ' && character != 0x7F // no control characters
	}
}

// Mouse handling inside the widget being edited, from the last frame's layout like all hit
// testing. A press puts the caret under the pointer (Shift+press extends the selection to it),
// dragging selects. A double-click selects the word under the pointer, and dragging then extends
// by whole words; a triple-click selects everything (state.click_count, from begin_frame).
@(private)
edit_with_mouse :: proc(state: ^Ui_State, interaction: Interaction) {
	if !interaction.pressed && !interaction.held {
		return
	}
	text_element := clay.GetElementData(clay.ID(EDIT_TEXT_ID))
	if !text_element.found {
		return
	}
	measure_edited_text(state)
	edit := &state.edit_state
	text_start_x := text_element.boundingBox.x - state.edit_scroll_x
	offset := offset_at_x(state, state.input.mouse_position.x - text_start_x)
	shift_held := state.input.keys[.Left_Shift].down || state.input.keys[.Right_Shift].down

	if interaction.pressed {
		switch state.click_count {
		case 1:
			if shift_held {
				edit.selection[0] = offset
			} else {
				edit.selection = {offset, offset}
			}
		case 2:
			word_start, word_end := word_around(state, offset)
			edit.selection = {word_end, word_start}
			state.edit_drag_word = {word_start, word_end}
		case:
			edit.selection = {len(edited_text(state)), 0}
		}
	} else if state.click_count == 1 {
		edit.selection[0] = offset // dragging moves the head; the anchor stays where it was pressed
	} else if state.click_count == 2 {
		// Extend by words, keeping the double-clicked word selected.
		word_start, word_end := word_around(state, offset)
		if offset < state.edit_drag_word[0] {
			edit.selection = {word_start, state.edit_drag_word[1]}
		} else {
			edit.selection = {word_end, state.edit_drag_word[0]}
		}
	}
	state.edit_blink_seconds = 0
	keep_caret_visible(state) // dragging past an edge scrolls the text
}

// The word around a character boundary: the run of non-space characters it touches.
@(private)
word_around :: proc(state: ^Ui_State, offset: int) -> (start, end: int) {
	edit := &state.edit_state
	saved := edit.selection
	edit.selection = {offset, offset}
	start = text_edit.translate_position(edit, .Word_Start)
	end = text_edit.translate_position(edit, .Word_End)
	edit.selection = saved
	return
}

// Measures where every character boundary of the edited text falls, from the text's start, into
// edit_caret_x. The same fontstash iteration places the glyphs in draw_edited_text, so the two
// always agree. Leaves the font set up for drawing.
@(private)
measure_edited_text :: proc(state: ^Ui_State) {
	text := edited_text(state)
	set_font(state, state.edit_font, points(state, FONT_SIZE), 0)
	iterator := fontstash.TextIterInit(&state.font_context, 0, 0, text)
	quad: fontstash.Quad
	for fontstash.TextIterNext(&state.font_context, &iterator, &quad) {
		state.edit_caret_x[iterator.str] = iterator.x
	}
	state.edit_caret_x[len(text)] = iterator.nextx if len(text) > 0 else 0
}

// The character boundary nearest to `x` (pixels from the text's start).
@(private)
offset_at_x :: proc(state: ^Ui_State, x: f32) -> int {
	text := edited_text(state)
	best_offset, best_distance := 0, abs(x - state.edit_caret_x[0])
	for offset in 1 ..= len(text) {
		if offset < len(text) && !utf8.rune_start(text[offset]) {
			continue
		}
		if distance := abs(x - state.edit_caret_x[offset]); distance < best_distance {
			best_offset, best_distance = offset, distance
		}
	}
	return best_offset
}

// Scrolls the text sideways just enough to show the caret, and no further than its end.
@(private)
keep_caret_visible :: proc(state: ^Ui_State) {
	text_element := clay.GetElementData(clay.ID(EDIT_TEXT_ID))
	if !text_element.found || text_element.boundingBox.width <= 0 {
		return
	}
	visible_width := text_element.boundingBox.width
	caret_x := state.edit_caret_x[clamp(edit_caret(state), 0, len(edited_text(state)))]
	caret_width := caret_width_pixels(state)
	if caret_x + caret_width - state.edit_scroll_x > visible_width {
		state.edit_scroll_x = caret_x + caret_width - visible_width
	}
	if caret_x - state.edit_scroll_x < 0 {
		state.edit_scroll_x = caret_x
	}
	text_width := state.edit_caret_x[len(edited_text(state))]
	state.edit_scroll_x = clamp(state.edit_scroll_x, 0, max(text_width + caret_width - visible_width, 0))
}

@(private)
caret_width_pixels :: proc(state: ^Ui_State) -> f32 {
	return max(math.round(points(state, 1)), 1)
}

// Declares where the edited text goes: an empty element filling the rest of the box. Clay
// reports it back in end_frame as a custom command, and draw_edited_text fills it in.
@(private)
declare_edited_text :: proc(state: ^Ui_State) {
	clay._OpenElementWithId(clay.ID(EDIT_TEXT_ID))
	clay.ConfigureOpenElement({
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}},
		custom = {customData = state},
	})
	clay._CloseElement()
}

// Draws the edited text into its element's box, clipped to it and to the clip region it's in:
// the selection highlight, the glyphs, then the caret, all from edit_caret_x and the scroll.
@(private)
draw_edited_text :: proc(state: ^Ui_State, renderer: ^render.Renderer, box_min, box_max, clip_min, clip_max: [2]f32) {
	measure_edited_text(state)
	text := edited_text(state)
	edit := &state.edit_state
	ascender, descender, _ := fontstash.VerticalMetrics(&state.font_context)
	glyph_height := ascender - descender
	// One whole-pixel origin for the whole string, so glyphs keep their spacing; everything
	// else is measured from it.
	origin := [2]f32{math.round(box_min.x - state.edit_scroll_x), math.round(box_min.y + (box_max.y - box_min.y - glyph_height) * 0.5)}
	line_padding := math.round(points(state, 2))
	line_top, line_bottom := origin.y - line_padding, origin.y + glyph_height + line_padding

	render.overlay_set_scissor(renderer, linalg.max(box_min, clip_min), linalg.min(box_max, clip_max))
	defer render.overlay_set_scissor(renderer, clip_min, clip_max)

	start, end := selection_range(state)
	if end > start {
		render.overlay_rect(renderer, {origin.x + state.edit_caret_x[start], line_top}, {origin.x + state.edit_caret_x[end], line_bottom}, color_from_clay(state.theme.text_selection))
	}

	text_color := color_from_clay(state.theme.text)
	iterator := fontstash.TextIterInit(&state.font_context, origin.x, origin.y, text)
	quad: fontstash.Quad
	for fontstash.TextIterNext(&state.font_context, &iterator, &quad) {
		render.overlay_glyph(renderer, {quad.x0, quad.y0}, {quad.x1, quad.y1}, {quad.s0, quad.t0}, {quad.s1, quad.t1}, text_color)
	}

	// The caret blinks, and shows at once after any change (edit_blink_seconds restarts).
	caret_visible := math.mod(state.edit_blink_seconds, 2 * CARET_BLINK_SECONDS) < CARET_BLINK_SECONDS
	if caret_visible {
		caret_x := math.round(origin.x + state.edit_caret_x[clamp(edit.selection[0], 0, len(text))])
		render.overlay_rect(renderer, {caret_x, line_top}, {caret_x + caret_width_pixels(state), line_bottom}, text_color)
	}
}

// Asks the host to put `text` on the clipboard after this frame (platform.Output).
@(private)
request_clipboard :: proc(state: ^Ui_State, text: string) {
	fitted := truncate_to_character(text, len(state.clipboard_request))
	state.clipboard_request_length = copy(state.clipboard_request[:], fitted)
	state.clipboard_requested = true
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
