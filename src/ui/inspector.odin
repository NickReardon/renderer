// Generated property panels. `inspect` draws an editable widget for every field of a struct
// that carries an `inspect` tag, so new data appears in the editor without writing UI code.
// (Godot builds its Inspector from ClassDB property lists and Blender from RNA; Odin keeps type
// information and struct tags at runtime, through core:reflect.)
//
//     Transform :: struct {
//         position: [3]f32 `inspect:"Position" step:"0.01"`,
//         rotation: [3]f32 `inspect:"Rotation" step:"0.5" format:"%.1f°"`,
//         visible:  bool   `inspect:"Visible"`,
//         color:    [4]f32 `inspect:"Color" hint:"color"`,
//     }
//
// Tag keys:
//   inspect  the label; fields without it are not shown
//   step     drag speed per point moved (default 0.01)
//   min, max limits for f32 fields
//   format   printf format for the displayed number (default %.2f)
//   hint     "color" for [4]f32 / [3]f32 fields holding a linear RGB(A) color
//
// Supported field types: f32, [3]f32, [4]f32 (as a color), bool. Others show a note.
package ui

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import clay "engine:third_party/clay"

// Draws widgets for the tagged fields of the struct of type `type` at `data` (pass a pointer, so
// edits change the real value), e.g. `ui.inspect(&state, entity, Entity)`. Returns true if any
// field changed this frame.
inspect :: proc(state: ^Ui_State, data: rawptr, type: typeid) -> (changed: bool) {
	if !reflect.is_struct(type_info_of(type)) {
		label(state, fmt.tprintf("(inspect needs a struct, got %v)", type))
		return
	}
	for field in reflect.struct_fields_zipped(type) {
		label_text, shown := reflect.struct_tag_lookup(field.tag, "inspect")
		if !shown {
			continue
		}
		field_pointer := rawptr(uintptr(data) + field.offset)
		step := tag_f32(field.tag, "step", 0.01)
		format := tag_string(field.tag, "format", "%.2f")
		is_color := tag_string(field.tag, "hint", "") == "color"

		field_changed := false
		switch field.type.id {
		case f32:
			minimum := tag_f32(field.tag, "min", -max(f32))
			maximum := tag_f32(field.tag, "max", max(f32))
			field_changed = number_field(state, label_text, (^f32)(field_pointer), step, minimum, maximum, format)
		case [3]f32:
			if is_color {
				field_changed = color_field(state, label_text, (^[3]f32)(field_pointer))
			} else {
				field_changed = vector3_field(state, label_text, (^[3]f32)(field_pointer), step, format)
			}
		case [4]f32:
			field_changed = color_field(state, label_text, (^[3]f32)(field_pointer)) // alpha not edited yet
		case bool:
			field_changed = checkbox(state, label_text, (^bool)(field_pointer))
		case:
			label(state, fmt.tprintf("%s: %v (not editable yet)", label_text, field.type.id), .Regular, state.theme.text_dim)
		}
		changed = changed || field_changed
	}
	return
}

// A linear RGB color: a swatch and R, G, B number boxes (0..1).
color_field :: proc(state: ^Ui_State, label_text: string, color: ^[3]f32) -> (changed: bool) {
	open_field_row(state, label_text)
	// The swatch is drawn by the overlay in sRGB, so convert from linear for display.
	swatch_color := clay.Color{
		linear_to_srgb_byte(color.r),
		linear_to_srgb_byte(color.g),
		linear_to_srgb_byte(color.b),
		255,
	}
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout          = {sizing = {width = clay.SizingFixed(points(state, ROW_HEIGHT)), height = clay.SizingFixed(points(state, ROW_HEIGHT))}},
		backgroundColor = swatch_color,
		cornerRadius    = clay.CornerRadiusAll(points(state, CORNER_RADIUS)),
		border          = {color = state.theme.panel_border, width = clay.BorderOutside(points_u16(state, 1))},
	})
	clay._CloseElement()
	channel_names := [3]string{"R", "G", "B"}
	axis_colors := AXIS_COLORS
	for channel in 0 ..< 3 {
		if number_box(state, channel_names[channel], &color[channel], 0.005, 0, 1, "%.2f", channel_names[channel], axis_colors[channel]) {
			changed = true
		}
	}
	clay._CloseElement() // row
	return
}

@(private)
linear_to_srgb_byte :: proc(linear: f32) -> f32 {
	clamped := clamp(linear, 0, 1)
	encoded := clamped * 12.92 if clamped <= 0.0031308 else 1.055 * math.pow(clamped, 1 / 2.4) - 0.055
	return encoded * 255
}

@(private)
tag_f32 :: proc(tag: reflect.Struct_Tag, key: string, default_value: f32) -> f32 {
	if text_value, found := reflect.struct_tag_lookup(tag, key); found {
		if parsed_value, parsed := strconv.parse_f32(text_value); parsed {
			return parsed_value
		}
	}
	return default_value
}

@(private)
tag_string :: proc(tag: reflect.Struct_Tag, key: string, default_value: string) -> string {
	if text_value, found := reflect.struct_tag_lookup(tag, key); found {
		return text_value
	}
	return default_value
}
