// 2D overlay (UI): each instance is one quad in pixel coordinates, origin top-left.
//   mode 0 (shape): a rounded rectangle, filled or outlined, anti-aliased with a signed
//                   distance function, so corners and borders stay smooth at any size;
//   mode 1 (glyph): coverage sampled from the single-channel atlas (font glyphs).
// Colors arrive in sRGB, as written in UI themes, and are converted to linear here so blending
// and the sRGB surface agree with how the colors were chosen.

@group(1) @binding(0) var atlas_texture: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct Vertex_Output {
	@builtin(position) clip_position: vec4f,
	@location(0) pixel_position: vec2f,
	@location(1) uv: vec2f,
	@location(2) color: vec4f,
	@location(3) @interpolate(flat) rect_min: vec2f,
	@location(4) @interpolate(flat) rect_max: vec2f,
	@location(5) @interpolate(flat) corner_radius: f32,
	@location(6) @interpolate(flat) border_width: f32,
	@location(7) @interpolate(flat) mode: u32,
}

@vertex
fn vertex_main(
	@builtin(vertex_index) vertex_index: u32,
	@location(0) rect_min: vec2f,
	@location(1) rect_max: vec2f,
	@location(2) uv_min: vec2f,
	@location(3) uv_max: vec2f,
	@location(4) color: vec4f,
	@location(5) corner_radius: f32,
	@location(6) border_width: f32,
	@location(7) mode: u32,
) -> Vertex_Output {
	var corners = array<vec2f, 6>(
		vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0),
		vec2f(0.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0),
	);
	let corner = corners[vertex_index];
	let pixel_position = mix(rect_min, rect_max, corner);
	// Pixels (y down) to clip space (y up).
	let normalized = pixel_position / frame.viewport_size;

	var output: Vertex_Output;
	output.clip_position = vec4f(normalized.x * 2.0 - 1.0, 1.0 - normalized.y * 2.0, 0.0, 1.0);
	output.pixel_position = pixel_position;
	output.uv = mix(uv_min, uv_max, corner);
	output.color = color;
	output.rect_min = rect_min;
	output.rect_max = rect_max;
	output.corner_radius = corner_radius;
	output.border_width = border_width;
	output.mode = mode;
	return output;
}

// Signed distance from `position` to a rounded box centred on the origin: negative inside,
// positive outside, in pixels. (Inigo Quilez's rounded-box distance.)
fn rounded_box_distance(position: vec2f, half_size: vec2f, radius: f32) -> f32 {
	let corner_offset = abs(position) - half_size + radius;
	return length(max(corner_offset, vec2f(0.0))) + min(max(corner_offset.x, corner_offset.y), 0.0) - radius;
}

fn srgb_to_linear(srgb: vec3f) -> vec3f {
	let low = srgb / 12.92;
	let high = pow((srgb + 0.055) / 1.055, vec3f(2.4));
	return select(high, low, srgb <= vec3f(0.04045));
}

@fragment
fn fragment_main(fragment: Vertex_Output) -> @location(0) vec4f {
	// Sample unconditionally: texture sampling must happen in uniform control flow.
	let glyph_coverage = textureSample(atlas_texture, atlas_sampler, fragment.uv).r;

	var coverage = glyph_coverage;
	if (fragment.mode == 0u) {
		let half_size = (fragment.rect_max - fragment.rect_min) * 0.5;
		let center = (fragment.rect_min + fragment.rect_max) * 0.5;
		let radius = min(fragment.corner_radius, min(half_size.x, half_size.y));
		let distance = rounded_box_distance(fragment.pixel_position - center, half_size, radius);
		coverage = clamp(0.5 - distance, 0.0, 1.0);
		if (fragment.border_width > 0.0) {
			// Outline: keep only the band between the outer edge and the edge shrunk inward.
			coverage *= clamp(0.5 + distance + fragment.border_width, 0.0, 1.0);
		}
	}

	let linear_color = srgb_to_linear(fragment.color.rgb);
	return vec4f(encode_output(linear_color), fragment.color.a * coverage);
}
