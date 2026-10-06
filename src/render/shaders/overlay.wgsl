// 2D overlay (UI and gizmos): each instance is one shape in pixel coordinates, origin top-left.
//   mode 0 (shape):    a rounded rectangle, filled or outlined
//   mode 1 (glyph):    coverage sampled from the single-channel atlas (font glyphs)
//   mode 2 (segment):  a thick line with rounded ends
//   mode 3 (triangle): a filled triangle
// Shapes are anti-aliased with signed distance functions (distance from the pixel to the
// shape's edge), so edges stay smooth at any size with no extra geometry. Colors arrive in
// sRGB, as written in UI themes, and are converted to linear here so blending and the sRGB
// surface agree with how the colors were chosen.

@group(1) @binding(0) var atlas_texture: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct Vertex_Output {
	@builtin(position) clip_position: vec4f,
	@location(0) pixel_position: vec2f,
	@location(1) uv: vec2f,
	@location(2) color: vec4f,
	@location(3) @interpolate(flat) point_a: vec2f, // rect_min, segment start, triangle corner
	@location(4) @interpolate(flat) point_b: vec2f, // rect_max, segment end, triangle corner
	@location(5) @interpolate(flat) corner_radius: f32,
	@location(6) @interpolate(flat) border_width: f32, // segments: thickness
	@location(7) @interpolate(flat) mode: u32,
	@location(8) @interpolate(flat) point_c: vec2f, // triangle's third corner
}

const MODE_SHAPE: u32 = 0u;
const MODE_GLYPH: u32 = 1u;
const MODE_SEGMENT: u32 = 2u;
const MODE_TRIANGLE: u32 = 3u;

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

	// The quad to cover: the rectangle itself, or the bounding box of a segment or triangle
	// grown by its half-thickness plus one pixel for the anti-aliased edge.
	var quad_min = rect_min;
	var quad_max = rect_max;
	if (mode == MODE_SEGMENT) {
		let margin = border_width * 0.5 + 1.0;
		quad_min = min(rect_min, rect_max) - margin;
		quad_max = max(rect_min, rect_max) + margin;
	} else if (mode == MODE_TRIANGLE) {
		quad_min = min(min(rect_min, rect_max), uv_min) - 1.0;
		quad_max = max(max(rect_min, rect_max), uv_min) + 1.0;
	}
	let pixel_position = mix(quad_min, quad_max, corner);
	// Pixels (y down) to clip space (y up).
	let normalized = pixel_position / frame.viewport_size;

	var output: Vertex_Output;
	output.clip_position = vec4f(normalized.x * 2.0 - 1.0, 1.0 - normalized.y * 2.0, 0.0, 1.0);
	output.pixel_position = pixel_position;
	output.uv = mix(uv_min, uv_max, corner);
	output.color = color;
	output.point_a = rect_min;
	output.point_b = rect_max;
	output.corner_radius = corner_radius;
	output.border_width = border_width;
	output.mode = mode;
	output.point_c = uv_min;
	return output;
}

// Signed distance from `position` to a rounded box centred on the origin: negative inside,
// positive outside, in pixels. (Inigo Quilez's rounded-box distance.)
fn rounded_box_distance(position: vec2f, half_size: vec2f, radius: f32) -> f32 {
	let corner_offset = abs(position) - half_size + radius;
	return length(max(corner_offset, vec2f(0.0))) + min(max(corner_offset.x, corner_offset.y), 0.0) - radius;
}

// Distance from `position` to the segment start..end (unsigned).
fn segment_distance(position: vec2f, start: vec2f, end: vec2f) -> f32 {
	let along = end - start;
	let from_start = position - start;
	let fraction = clamp(dot(from_start, along) / max(dot(along, along), 1e-6), 0.0, 1.0);
	return length(from_start - along * fraction);
}

// Signed distance to a triangle: negative inside (Inigo Quilez's sdTriangle).
fn triangle_distance(position: vec2f, corner_0: vec2f, corner_1: vec2f, corner_2: vec2f) -> f32 {
	let edge_0 = corner_1 - corner_0;
	let edge_1 = corner_2 - corner_1;
	let edge_2 = corner_0 - corner_2;
	let to_0 = position - corner_0;
	let to_1 = position - corner_1;
	let to_2 = position - corner_2;
	let nearest_0 = to_0 - edge_0 * clamp(dot(to_0, edge_0) / dot(edge_0, edge_0), 0.0, 1.0);
	let nearest_1 = to_1 - edge_1 * clamp(dot(to_1, edge_1) / dot(edge_1, edge_1), 0.0, 1.0);
	let nearest_2 = to_2 - edge_2 * clamp(dot(to_2, edge_2) / dot(edge_2, edge_2), 0.0, 1.0);
	let winding = sign(edge_0.x * edge_2.y - edge_0.y * edge_2.x);
	let distances = min(min(
		vec2f(dot(nearest_0, nearest_0), winding * (to_0.x * edge_0.y - to_0.y * edge_0.x)),
		vec2f(dot(nearest_1, nearest_1), winding * (to_1.x * edge_1.y - to_1.y * edge_1.x))),
		vec2f(dot(nearest_2, nearest_2), winding * (to_2.x * edge_2.y - to_2.y * edge_2.x)));
	return -sqrt(distances.x) * sign(distances.y);
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
	if (fragment.mode == MODE_SHAPE) {
		let half_size = (fragment.point_b - fragment.point_a) * 0.5;
		let center = (fragment.point_a + fragment.point_b) * 0.5;
		let radius = min(fragment.corner_radius, min(half_size.x, half_size.y));
		let distance = rounded_box_distance(fragment.pixel_position - center, half_size, radius);
		coverage = clamp(0.5 - distance, 0.0, 1.0);
		if (fragment.border_width > 0.0) {
			// Outline: keep only the band between the outer edge and the edge shrunk inward.
			coverage *= clamp(0.5 + distance + fragment.border_width, 0.0, 1.0);
		}
	} else if (fragment.mode == MODE_SEGMENT) {
		let distance = segment_distance(fragment.pixel_position, fragment.point_a, fragment.point_b) - fragment.border_width * 0.5;
		coverage = clamp(0.5 - distance, 0.0, 1.0);
	} else if (fragment.mode == MODE_TRIANGLE) {
		let distance = triangle_distance(fragment.pixel_position, fragment.point_a, fragment.point_b, fragment.point_c);
		coverage = clamp(0.5 - distance, 0.0, 1.0);
	}

	let linear_color = srgb_to_linear(fragment.color.rgb);
	return vec4f(encode_output(linear_color), fragment.color.a * coverage);
}
