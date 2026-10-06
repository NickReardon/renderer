// Widgets. Containers (panel, section) are used as `if` blocks and close themselves at the end
// of the block (Odin's deferred attributes):
//
//     if ui.panel(&state, "Inspector", 300) {
//         if ui.section(&state, "Camera", &camera_section_open) {
//             ui.number_field(&state, "Distance", &camera.distance, 0.05, 0.1, 1000)
//         }
//     }
//
// Widget ids are hashed from labels relative to the enclosing element, so the same label may
// appear in different sections but not twice in one (Clay reports duplicates).
package ui

import "core:fmt"
import "core:strconv"
import "engine:platform"
import clay "engine:third_party/clay"

// Takes the remaining space in the parent's layout direction. Put one before a panel to push
// it to the right edge of the window. Name it to ask for its rectangle with `area_rect` after
// end_frame (the editor uses this for the 3D viewport).
flexible_space :: proc(state: ^Ui_State, name: string = "") {
	if name != "" {
		clay._OpenElementWithId(clay.ID(name))
	} else {
		clay._OpenElement()
	}
	clay.ConfigureOpenElement({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}})
	clay._CloseElement()
}

// Where a named element ended up in this frame's layout, in pixels. Valid after end_frame.
area_rect :: proc(state: ^Ui_State, name: string) -> (rect_min, rect_max: [2]f32, found: bool) {
	element := clay.GetElementData(clay.ID(name))
	if !element.found {
		return
	}
	box := element.boundingBox
	return {box.x, box.y}, {box.x + box.width, box.y + box.height}, true
}

// Like flexible_space, but a container: content inside it (a toolbar) is laid over the area.
// The area itself doesn't take the mouse; the 3D view underneath keeps it.
@(deferred_none = close_element)
area :: proc(state: ^Ui_State, name: string) -> bool {
	clay._OpenElementWithId(clay.ID(name))
	clay.ConfigureOpenElement({
		layout = {
			sizing          = {width = clay.SizingGrow(), height = clay.SizingGrow()},
			padding         = clay.PaddingAll(points_u16(state, 8)),
			childGap        = points_u16(state, CHILD_GAP),
			layoutDirection = .TopToBottom,
		},
	})
	return true
}

// A compact row of controls, e.g. over the 3D view. It takes the mouse like a panel, so a
// click on it never reaches the view underneath.
@(deferred_none = close_element)
toolbar :: proc(state: ^Ui_State, id_text: string) -> bool {
	id := clay.ID_LOCAL(id_text)
	register_mouse_area(state, id)
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingFit(), height = clay.SizingFit()},
			padding        = clay.PaddingAll(points_u16(state, 3)),
			childGap       = points_u16(state, 2),
			childAlignment = {y = .Center},
		},
		backgroundColor = state.theme.panel_background,
		cornerRadius    = clay.CornerRadiusAll(points(state, CORNER_RADIUS + 2)),
		border          = {color = state.theme.panel_border, width = clay.BorderOutside(points_u16(state, 1))},
	})
	return true
}

// A button that shows whether it's selected (tool buttons, mode switches). Sized to its label.
toggle_button :: proc(state: ^Ui_State, label_text: string, selected: bool) -> (clicked: bool) {
	id := clay.ID_LOCAL(label_text)
	interaction := interact(state, id)
	background: clay.Color
	switch {
	case selected:
		background = state.theme.selection
	case interaction.held && interaction.hovered:
		background = state.theme.button_pressed
	case interaction.hovered:
		background = state.theme.button_hover
	}
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingFit(), height = clay.SizingFixed(points(state, ROW_HEIGHT))},
			padding        = {left = points_u16(state, 10), right = points_u16(state, 10)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = background,
		cornerRadius    = clay.CornerRadiusAll(points(state, CORNER_RADIUS)),
	})
	text(state, label_text, .Semibold if selected else .Regular, FONT_SIZE, state.theme.text if selected || interaction.hovered else state.theme.text_dim)
	clay._CloseElement()
	return interaction.clicked
}

// Marks an element as UI for mouse routing: while the pointer is over it, the 3D view
// doesn't get the mouse (ui.wants_mouse).
@(private)
register_mouse_area :: proc(state: ^Ui_State, id: clay.ElementId) {
	if state.panel_count < MAX_PANELS {
		state.panel_ids[state.panel_count] = id.id
		state.panel_count += 1
	}
}

// A full-height side panel with a title. Scrolls with the mouse wheel when its contents are
// taller than the window.
@(deferred_none = close_element)
panel :: proc(state: ^Ui_State, title: string, width_points: f32) -> bool {
	id := clay.ID(title)
	register_mouse_area(state, id)
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing          = {width = clay.SizingFixed(points(state, width_points)), height = clay.SizingGrow()},
			padding         = clay.PaddingAll(points_u16(state, PANEL_PADDING)),
			childGap        = points_u16(state, CHILD_GAP),
			layoutDirection = .TopToBottom,
		},
		backgroundColor = state.theme.panel_background,
		border          = {color = state.theme.panel_border, width = {left = points_u16(state, 1)}},
		clip            = {vertical = true, childOffset = clay.GetScrollOffset()},
	})
	text(state, title, .Semibold, TITLE_FONT_SIZE)
	return true
}

// A collapsible group: a clickable header, then the contents while `open` is true.
// Returns `open^`; the caller's block holds the contents.
@(deferred_none = close_element)
section :: proc(state: ^Ui_State, label: string, open: ^bool) -> bool {
	clay._OpenElementWithId(clay.ID_LOCAL(label))
	clay.ConfigureOpenElement({
		layout = {
			sizing          = {width = clay.SizingGrow()},
			childGap        = points_u16(state, CHILD_GAP),
			layoutDirection = .TopToBottom,
		},
	})

	header_id := clay.ID_LOCAL("header")
	interaction := interact(state, header_id)
	if interaction.clicked {
		open^ = !open^
	}
	clay._OpenElementWithId(header_id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow(), height = clay.SizingFixed(points(state, ROW_HEIGHT))},
			padding        = {left = points_u16(state, 8), right = points_u16(state, 8)},
			childGap       = points_u16(state, 8),
			childAlignment = {y = .Center},
		},
		backgroundColor = state.theme.section_hover if interaction.hovered else state.theme.section_header,
		cornerRadius    = clay.CornerRadiusAll(points(state, CORNER_RADIUS)),
	})
	text(state, "−" if open^ else "+", .Semibold, FONT_SIZE, state.theme.text_dim)
	text(state, label, .Semibold)
	clay._CloseElement()
	return open^
}

label :: proc(state: ^Ui_State, content: string, font: Font = .Regular, color: clay.Color = {}) {
	text(state, content, font, FONT_SIZE, color, .Words) // wraps at the panel width
}

button :: proc(state: ^Ui_State, label_text: string) -> (clicked: bool) {
	id := clay.ID_LOCAL(label_text)
	interaction := interact(state, id)
	background := state.theme.button
	if interaction.held && interaction.hovered {
		background = state.theme.button_pressed
	} else if interaction.hovered {
		background = state.theme.button_hover
	}
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow(), height = clay.SizingFixed(points(state, ROW_HEIGHT))},
			padding        = {left = points_u16(state, 8), right = points_u16(state, 8)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = background,
		cornerRadius    = clay.CornerRadiusAll(points(state, CORNER_RADIUS)),
	})
	text(state, label_text)
	clay._CloseElement()
	return interaction.clicked
}

// A box and a label; the whole row toggles the value.
checkbox :: proc(state: ^Ui_State, label_text: string, value: ^bool) -> (changed: bool) {
	row_id := clay.ID_LOCAL(label_text)
	interaction := interact(state, row_id)
	if interaction.clicked {
		value^ = !value^
		changed = true
	}
	box_size := points(state, 16)
	clay._OpenElementWithId(row_id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow(), height = clay.SizingFixed(points(state, ROW_HEIGHT))},
			childGap       = points_u16(state, 8),
			childAlignment = {y = .Center},
		},
	})
	{
		clay._OpenElement()
		box_color := state.theme.accent if value^ else (state.theme.field_hover if interaction.hovered else state.theme.field)
		clay.ConfigureOpenElement({
			layout = {
				sizing         = {width = clay.SizingFixed(box_size), height = clay.SizingFixed(box_size)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = box_color,
			cornerRadius    = clay.CornerRadiusAll(points(state, 3)),
			border          = {color = state.theme.panel_border, width = clay.BorderOutside(points_u16(state, 1))},
		})
		if value^ {
			// A light inner square marks "on".
			clay._OpenElement()
			clay.ConfigureOpenElement({
				layout          = {sizing = {width = clay.SizingFixed(box_size * 0.45), height = clay.SizingFixed(box_size * 0.45)}},
				backgroundColor = {240, 244, 250, 255},
				cornerRadius    = clay.CornerRadiusAll(points(state, 1.5)),
			})
			clay._CloseElement()
		}
		clay._CloseElement()
	}
	text(state, label_text)
	clay._CloseElement()
	return
}

// A labelled number. Drag sideways to change it (`drag_speed` per point moved); click without
// dragging to type a value, then Enter or click elsewhere to apply, Escape to cancel. Tab and
// Shift+Tab apply it and move to the next or previous number box.
number_field :: proc(
	state: ^Ui_State,
	label_text: string,
	value: ^f32,
	drag_speed: f32 = 0.01,
	minimum: f32 = -max(f32),
	maximum: f32 = max(f32),
	display_format: string = "%.3f",
) -> (changed: bool) {
	open_field_row(state, label_text)
	changed = number_box(state, "field", value, drag_speed, minimum, maximum, display_format)
	clay._CloseElement() // row
	return
}

AXIS_LABELS :: [3]string{"X", "Y", "Z"}
AXIS_COLORS :: [3]clay.Color{{232, 96, 88, 255}, {124, 200, 92, 255}, {84, 140, 236, 255}} // X red, Y green, Z blue

// Three numbers side by side with X, Y, Z markers (positions, rotations, scales).
vector3_field :: proc(
	state: ^Ui_State,
	label_text: string,
	value: ^[3]f32,
	drag_speed: f32 = 0.01,
	display_format: string = "%.2f",
) -> (changed: bool) {
	open_field_row(state, label_text)
	axis_labels := AXIS_LABELS
	axis_colors := AXIS_COLORS
	for axis in 0 ..< 3 {
		if number_box(state, axis_labels[axis], &value[axis], drag_speed, -max(f32), max(f32), display_format, axis_labels[axis], axis_colors[axis]) {
			changed = true
		}
	}
	clay._CloseElement() // row
	return
}

// Opens a row with a label column; the caller adds the value widgets and closes the row.
@(private)
open_field_row :: proc(state: ^Ui_State, label_text: string) {
	clay._OpenElementWithId(clay.ID_LOCAL(label_text))
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow(), height = clay.SizingFixed(points(state, ROW_HEIGHT))},
			childGap       = points_u16(state, 4),
			childAlignment = {y = .Center},
		},
	})
	clay._OpenElement()
	clay.ConfigureOpenElement({layout = {sizing = {width = clay.SizingPercent(LABEL_WIDTH_RATIO)}}})
	text(state, label_text, .Regular, FONT_SIZE, state.theme.text_dim)
	clay._CloseElement()
}

// The value box on its own: drag to change, click to type. `id_text` must be unique within the
// enclosing element. An optional marker (e.g. "X" in red) is drawn before the number.
number_box :: proc(
	state: ^Ui_State,
	id_text: string,
	value: ^f32,
	drag_speed: f32,
	minimum: f32,
	maximum: f32,
	display_format: string,
	marker: string = "",
	marker_color: clay.Color = {},
) -> (changed: bool) {
	field_id := clay.ID_LOCAL(id_text)
	interaction := interact(state, field_id)
	editing := state.edit_id == field_id.id
	mouse_x := state.input.mouse_position.x

	if !editing {
		if interaction.pressed {
			state.drag_start_mouse_x = mouse_x
			state.drag_start_value = value^
			state.drag_moved = false
		}
		if interaction.held {
			drag_distance := mouse_x - state.drag_start_mouse_x
			if abs(drag_distance) > points(state, DRAG_THRESHOLD_POINTS) {
				state.drag_moved = true
			}
			if state.drag_moved {
				dragged_value := clamp(state.drag_start_value + drag_distance / state.scale * drag_speed, minimum, maximum)
				if dragged_value != value^ {
					value^ = dragged_value
					changed = true
				}
			}
		}
		// A click without a drag starts typing. So does Tab from the box drawn before this one.
		if (interaction.clicked && !state.drag_moved) || state.focus_request == .Next {
			start_editing(state, field_id.id, value^)
			state.focus_request = .None
			editing = true
		}
	} else {
		commit, cancel := edit_number_text(state)
		clicked_elsewhere := state.input.mouse[.Left].pressed && !clay.PointerOver(field_id)
		tab := state.input.keys[.Tab].pressed || state.input.keys[.Tab].repeated
		if commit || tab || clicked_elsewhere {
			if parsed_value, parsed := strconv.parse_f32(string(state.edit_buffer[:state.edit_length])); parsed {
				value^ = clamp(parsed_value, minimum, maximum)
				changed = true
				state.typed_value_applied = true
			}
			state.edit_id = 0
			editing = false
			if tab {
				// Tab moves the typing to the next box, Shift+Tab to the previous one, as in Unity
				// and Godot. Boxes are visited in the order they are drawn. The previous box was
				// drawn already, so it can start now; the next one hasn't been, so it picks up the
				// request when it is (or finish_layout wraps around to the first box).
				shift_held := state.input.keys[.Left_Shift].down || state.input.keys[.Right_Shift].down
				if !shift_held {
					state.focus_request = .Next
				} else if state.previous_box_id != 0 {
					start_editing(state, state.previous_box_id, state.previous_box_value)
				} else {
					state.focus_request = .Last // this is the first box: wrap around to the last
				}
			}
		} else if cancel {
			state.edit_id = 0
			editing = false
		}
	}

	background := state.theme.field
	if editing {
		background = state.theme.field_editing
	} else if interaction.hovered || interaction.held {
		background = state.theme.field_hover
	}
	displayed_text := fmt.tprintf(display_format, value^)
	if editing {
		// Selected text shows in brackets until typing replaces it; otherwise a caret at the end.
		edit_text := string(state.edit_buffer[:state.edit_length])
		displayed_text = fmt.tprintf("[%s]", edit_text) if state.edit_all_selected else fmt.tprintf("%s|", edit_text)
	}

	clay._OpenElementWithId(field_id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow(), height = clay.SizingFixed(points(state, ROW_HEIGHT))},
			padding        = {left = points_u16(state, 6), right = points_u16(state, 6)},
			childGap       = points_u16(state, 5),
			childAlignment = {y = .Center},
		},
		backgroundColor = background,
		cornerRadius    = clay.CornerRadiusAll(points(state, CORNER_RADIUS)),
		border          = {color = state.theme.accent if editing else state.theme.panel_border, width = clay.BorderOutside(points_u16(state, 1))},
		// Clip instead of growing: a long number is cut off inside its box rather than pushing the
		// row (and the other boxes) past the panel edge.
		clip            = {horizontal = true},
	})
	if marker != "" {
		text(state, marker, .Semibold, FONT_SIZE, marker_color)
	}
	text(state, displayed_text, .Monospace)
	clay._CloseElement()

	// Remember the box for Shift+Tab from the next one, and the first box for Tab from the last.
	if state.first_box_id == 0 {
		state.first_box_id = field_id.id
		state.first_box_value = value^
	}
	state.previous_box_id = field_id.id
	state.previous_box_value = value^
	return
}

// Starts typing into a number box, with its current value as the text, all selected.
@(private)
start_editing :: proc(state: ^Ui_State, field_id: u32, value: f32) {
	state.edit_id = field_id
	initial_text := fmt.bprintf(state.edit_buffer[:], "%g", value)
	state.edit_length = len(initial_text)
	state.edit_all_selected = true
}

// Children laid out left to right, sharing the width. Use as an `if` block.
@(deferred_none = close_element)
row :: proc(state: ^Ui_State, id_text: string) -> bool {
	clay._OpenElementWithId(clay.ID_LOCAL(id_text))
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow()},
			childGap       = points_u16(state, 4),
			childAlignment = {y = .Center},
		},
	})
	return true
}

// A list row (e.g. one object in the Hierarchy): highlighted when selected, hovered or pressed.
// `index` keeps rows with the same label apart. Returns the row's mouse interaction.
selectable :: proc(state: ^Ui_State, label_text: string, selected: bool, index: u32 = 0, indent_points: f32 = 0) -> Interaction {
	id := clay.ID_LOCAL(label_text, index)
	interaction := interact(state, id)
	background: clay.Color
	if selected {
		background = state.theme.selection
	} else if interaction.hovered {
		background = state.theme.section_hover
	}
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing         = {width = clay.SizingGrow(), height = clay.SizingFixed(points(state, ROW_HEIGHT - 2))},
			padding        = {left = points_u16(state, 8 + indent_points), right = points_u16(state, 8)},
			childAlignment = {y = .Center},
		},
		backgroundColor = background,
		cornerRadius    = clay.CornerRadiusAll(points(state, 3)),
	})
	text(state, label_text, .Regular, FONT_SIZE, state.theme.text if selected || interaction.hovered else state.theme.text_dim)
	clay._CloseElement()
	return interaction
}

// Applies this frame's typing to the edit buffer. Only characters that can appear in a number
// are accepted.
@(private)
edit_number_text :: proc(state: ^Ui_State) -> (commit, cancel: bool) {
	for character in platform.input_text(&state.input) {
		is_number_character := (character >= '0' && character <= '9') || character == '.' || character == '-' || character == '+' || character == 'e' || character == 'E'
		if !is_number_character {
			continue
		}
		if state.edit_all_selected {
			state.edit_length = 0
			state.edit_all_selected = false
		}
		if state.edit_length < MAX_EDIT_BYTES {
			state.edit_buffer[state.edit_length] = u8(character)
			state.edit_length += 1
		}
	}
	backspace := state.input.keys[.Backspace]
	if backspace.pressed || backspace.repeated {
		if state.edit_all_selected {
			state.edit_length = 0
			state.edit_all_selected = false
		} else if state.edit_length > 0 {
			state.edit_length -= 1
		}
	}
	commit = state.input.keys[.Enter].pressed
	cancel = state.input.keys[.Escape].pressed
	return
}
