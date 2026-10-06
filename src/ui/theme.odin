// Colors and sizes. Colors are sRGB, 0-255, as Clay expects. Sizes are in points (1/96 inch)
// and multiplied by the display scale when used, so the UI keeps its physical size on
// high-DPI screens.
package ui

import clay "engine:third_party/clay"

Theme :: struct {
	panel_background: clay.Color,
	panel_border:     clay.Color,
	section_header:   clay.Color,
	section_hover:    clay.Color,
	text:             clay.Color,
	text_dim:         clay.Color,
	field:            clay.Color,
	field_hover:      clay.Color,
	field_editing:    clay.Color,
	accent:           clay.Color,
	button:           clay.Color,
	button_hover:     clay.Color,
	button_pressed:   clay.Color,
}

DARK_THEME :: Theme{
	panel_background = {38, 40, 46, 255},
	panel_border     = {22, 23, 27, 255},
	section_header   = {48, 51, 58, 255},
	section_hover    = {58, 62, 70, 255},
	text             = {226, 228, 233, 255},
	text_dim         = {150, 154, 163, 255},
	field            = {27, 29, 34, 255},
	field_hover      = {33, 36, 42, 255},
	field_editing    = {20, 22, 26, 255},
	accent           = {74, 136, 232, 255},
	button           = {60, 64, 73, 255},
	button_hover     = {72, 77, 88, 255},
	button_pressed   = {48, 51, 58, 255},
}

FONT_SIZE          :: 13
TITLE_FONT_SIZE    :: 15
ROW_HEIGHT         :: 24
PANEL_PADDING      :: 10
CHILD_GAP          :: 6
CORNER_RADIUS      :: 4
LABEL_WIDTH_RATIO  :: 0.42 // share of a row taken by a field's label
SCROLL_POINTS_PER_WHEEL_STEP :: 40
DRAG_THRESHOLD_POINTS        :: 3 // movement before a press on a number field becomes a drag
