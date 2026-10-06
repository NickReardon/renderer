// Text: fonts, measuring (for Clay's layout) and drawing (glyph quads for the overlay).
//
// fontstash rasterizes glyphs on demand into a single-channel atlas the first time each
// glyph is used at each size, so any size is available without baking. The atlas lives on the
// CPU; end_frame uploads the region that changed to the renderer.
//
// Limits (see docs/DESIGN.md): no shaping, so Latin, Greek, Cyrillic and CJK work, but Arabic,
// Indic scripts and right-to-left text need kb_text_shape later. Everything goes through
// measure_text and draw_text, so that upgrade stays inside this file.
package ui

import "core:math"
import "core:slice"
import fontstash "vendor:fontstash"
import "engine:render"
import clay "engine:third_party/clay"

Font :: enum u16 {
	Regular,
	Semibold,
	Monospace,
}

// Embedded into the DLL at compile time, then copied to the heap so fontstash owns its copy.
INTER_REGULAR_TTF        :: #load("../../assets/fonts/Inter-Regular.ttf")
INTER_SEMIBOLD_TTF       :: #load("../../assets/fonts/Inter-SemiBold.ttf")
JETBRAINS_MONO_REGULAR_TTF :: #load("../../assets/fonts/JetBrainsMono-Regular.ttf")

INITIAL_ATLAS_SIZE :: 1024

// Declares a text element. Sizes are in points.
text :: proc(state: ^Ui_State, content: string, font: Font = .Regular, size_points: f32 = FONT_SIZE, color: clay.Color = {}) {
	text_color := color if color != {} else state.theme.text
	clay.TextDynamic(content, {
		fontId    = u16(font),
		fontSize  = points_u16(state, size_points),
		textColor = text_color,
		wrapMode  = .None,
	})
}

@(private)
load_fonts :: proc(state: ^Ui_State) {
	fontstash.Init(&state.font_context, INITIAL_ATLAS_SIZE, INITIAL_ATLAS_SIZE, .TOPLEFT)
	state.font_indices[.Regular] = fontstash.AddFontMem(&state.font_context, "Inter Regular", slice.clone(INTER_REGULAR_TTF), true)
	state.font_indices[.Semibold] = fontstash.AddFontMem(&state.font_context, "Inter SemiBold", slice.clone(INTER_SEMIBOLD_TTF), true)
	state.font_indices[.Monospace] = fontstash.AddFontMem(&state.font_context, "JetBrains Mono", slice.clone(JETBRAINS_MONO_REGULAR_TTF), true)
}

@(private)
set_font :: proc(state: ^Ui_State, font: Font, size_pixels: f32, letter_spacing: f32) {
	fontstash.SetFont(&state.font_context, state.font_indices[font])
	fontstash.SetSize(&state.font_context, size_pixels)
	fontstash.SetSpacing(&state.font_context, letter_spacing)
	fontstash.SetAlignHorizontal(&state.font_context, .LEFT)
	fontstash.SetAlignVertical(&state.font_context, .TOP)
}

// Clay calls this while laying out text elements.
@(private)
measure_text :: proc "c" (text_slice: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	state := (^Ui_State)(user_data)
	context = state.callback_context
	content := string(text_slice.chars[:text_slice.length])
	set_font(state, Font(config.fontId), f32(config.fontSize), f32(config.letterSpacing))
	width := fontstash.TextBounds(&state.font_context, content)
	_, _, line_height := fontstash.VerticalMetrics(&state.font_context)
	height := f32(config.lineHeight) if config.lineHeight > 0 else line_height
	return {width, height}
}

@(private)
draw_text :: proc(state: ^Ui_State, renderer: ^render.Renderer, text_data: clay.TextRenderData, box: clay.BoundingBox) {
	content := string(text_data.stringContents.chars[:text_data.stringContents.length])
	set_font(state, Font(text_data.fontId), f32(text_data.fontSize), f32(text_data.letterSpacing))

	// Centre the glyphs vertically in the line box Clay gave us, and snap to whole pixels so
	// glyph bitmaps aren't resampled.
	ascender, descender, _ := fontstash.VerticalMetrics(&state.font_context)
	glyph_height := ascender - descender
	start_x := math.round(box.x)
	start_y := math.round(box.y + (box.height - glyph_height) * 0.5)

	color := color_from_clay(text_data.textColor)
	iterator := fontstash.TextIterInit(&state.font_context, start_x, start_y, content)
	quad: fontstash.Quad
	for fontstash.TextIterNext(&state.font_context, &iterator, &quad) {
		render.overlay_glyph(renderer, {quad.x0, quad.y0}, {quad.x1, quad.y1}, {quad.s0, quad.t0}, {quad.s1, quad.t1}, color)
	}
}

// Sends new glyphs to the GPU: the changed region, or everything if the atlas grew.
@(private)
upload_glyph_atlas :: proc(state: ^Ui_State, renderer: ^render.Renderer) {
	font_context := &state.font_context
	atlas_size := [2]i32{i32(font_context.width), i32(font_context.height)}
	dirty_rectangle: [4]f32
	has_new_glyphs := fontstash.ValidateTexture(font_context, &dirty_rectangle)
	if atlas_size != state.uploaded_atlas_size {
		render.set_overlay_atlas(renderer, font_context.textureData, atlas_size, {0, 0}, atlas_size)
		state.uploaded_atlas_size = atlas_size
	} else if has_new_glyphs {
		dirty_min := [2]i32{i32(dirty_rectangle[0]), i32(dirty_rectangle[1])}
		dirty_max := [2]i32{i32(math.ceil(dirty_rectangle[2])), i32(math.ceil(dirty_rectangle[3]))}
		render.set_overlay_atlas(renderer, font_context.textureData, atlas_size, dirty_min, dirty_max)
	}
}
