// Anti-aliased grid on world planes through the origin. Lines are computed per pixel from
// screen-space derivatives instead of drawn as geometry (the idea of Ben Golus, "The Best Darn
// Grid Shader (Yet)", docs/REFERENCES.md): `dpdx`/`dpdy` say how many grid cells one pixel
// spans, which turns "distance to the nearest line" into pixels.
//
// Lines are `frame.grid_line_width` *pixels* wide at any distance (the editor's setting).
// Constant-pixel lines would merge into a solid sheet far away, so each family of lines fades
// out as its cells shrink on screen (between 12 and 4 pixels apart), as Blender's grid levels
// do: the 1-unit lines give way to the 10-unit lines, which give way to nothing.
//
// Instances: GRID_DEPTH_PASSES passes x 3 planes. instance_index % 3 is the plane (0 = XZ, the
// ground; 1 = XY; 2 = YZ), each faded by frame.grid_plane_opacity. Orthographic views that see
// the ground edge-on fade it out and fade in the vertical plane facing the view (the editor
// picks the opacities), so turning the view cross-fades the grids instead of switching them.
// instance_index / 3 is the depth pass, below.

const GRID_EXTENT: f32 = 500.0; // half-size of the quad, in world units

// Soft depth test, after Blender's grid (overlay_grid_vert.glsl): the grid is drawn
// GRID_DEPTH_PASSES times, each pushed to a slightly different depth, from just behind its true
// depth to just in front, and each with a share of the opacity. Every pass is hard depth-tested,
// so where geometry meets the grid only some passes survive:
//   - a face lying exactly in the grid's plane (a cube's bottom on the ground) keeps the front
//     half of the passes, so the grid shows on it at partial strength, steadily, instead of
//     z-fighting (both at the same depth, rounding picking a winner pixel by pixel);
//   - an object crossing the grid gets a short fade at the intersection instead of a hard,
//     jagged line.
// The passes are spread over:
//   - perspective (depth = near / distance): ±GRID_DEPTH_SPREAD_RELATIVE of the distance,
//     ±1.4 mm at 7 m, about a pixel's worth of depth at a typical angle; the passes are ~800
//     rounding steps apart (relative precision 2^-23), so each pass is stable;
//   - orthographic (depth falls linearly over 2000 units): ±GRID_DEPTH_SPREAD_ORTHOGRAPHIC of
//     depth, ±8 mm, the passes ~30 rounding steps apart there. A relative spread would be far
//     too wide there (±20 cm), since orthographic depth doesn't shrink with distance.
// Blender offsets clip-space z by fixed amounts; scaling it suits our reverse-Z depth, whose
// precision is relative. The pipeline's fixed depth bias can't do either: on a float depth
// buffer it's about one absolute amount at every distance.
const GRID_DEPTH_PASSES: u32 = 4u; // must match GRID_DEPTH_PASSES in render.odin
const GRID_DEPTH_SPREAD_RELATIVE: f32 = 0.0002;
const GRID_DEPTH_SPREAD_ORTHOGRAPHIC: f32 = 0.000004;

const AXIS_X_COLOR = vec3f(0.85, 0.2, 0.2);
const AXIS_Y_COLOR = vec3f(0.3, 0.8, 0.3);
const AXIS_Z_COLOR = vec3f(0.2, 0.4, 0.9);

struct Vertex_Output {
	@builtin(position) clip_position: vec4f,
	@location(0) plane_position: vec2f, // coordinates along the plane's first and second axes
	@location(1) @interpolate(flat) plane: u32,
}

// The world directions of the plane's two axes, as the columns of a 3x2 matrix.
fn plane_axes(plane: u32) -> mat2x3f {
	switch plane {
		case 1u: { return mat2x3f(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0)); } // XY
		case 2u: { return mat2x3f(vec3f(0.0, 0.0, 1.0), vec3f(0.0, 1.0, 0.0)); } // YZ (z across, y up)
		default: { return mat2x3f(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 0.0, 1.0)); } // XZ
	}
}

@vertex
fn vertex_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance_index: u32) -> Vertex_Output {
	let plane = instance_index % 3u;
	let depth_pass = instance_index / 3u;

	// Two triangles forming a large square, re-centred under the camera every frame so the
	// grid never visibly ends.
	var corners = array<vec2f, 6>(
		vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
		vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(-1.0, 1.0),
	);
	let axes = plane_axes(plane);
	let camera_on_plane = frame.camera_position * axes; // (dot with first axis, dot with second)
	let plane_position = camera_on_plane + corners[vertex_index] * GRID_EXTENT;
	let world_position = axes * plane_position;
	var output: Vertex_Output;
	output.clip_position = frame.view_projection * vec4f(world_position, 1.0);

	// This pass's depth offset: -1 (behind) .. +1 (in front), evenly spaced. Reverse-Z: larger
	// depth is nearer. depth = z / w, so scaling z scales the depth; adding `w * offset` to z adds
	// `offset` to it.
	let pass_offset = (f32(depth_pass) + 0.5) / f32(GRID_DEPTH_PASSES) * 2.0 - 1.0;
	if (frame.orthographic > 0.5) {
		output.clip_position.z += pass_offset * GRID_DEPTH_SPREAD_ORTHOGRAPHIC * output.clip_position.w;
	} else {
		output.clip_position.z *= 1.0 + pass_offset * GRID_DEPTH_SPREAD_RELATIVE;
	}

	output.plane_position = plane_position;
	output.plane = plane;
	if (frame.grid_plane_opacity[plane] <= 0.0) {
		output.clip_position = vec4f(0.0); // collapsed: no pixels, no cost
	}
	return output;
}

// Coverage (0..1) of the lines every `cell_size` units at `coordinate`, frame.grid_line_width
// pixels wide.
fn grid_line_coverage(coordinate: vec2f, cell_size: f32) -> f32 {
	let cell_coordinate = coordinate / cell_size;
	let derivative_x = dpdx(cell_coordinate);
	let derivative_y = dpdy(cell_coordinate);
	let cells_per_pixel = max(vec2f(
		length(vec2f(derivative_x.x, derivative_y.x)),
		length(vec2f(derivative_x.y, derivative_y.y)),
	), vec2f(0.000001));
	// Distance to the nearest line in pixels, for each of the two families of lines.
	let distance_in_cells = abs(fract(cell_coordinate + 0.5) - 0.5);
	let distance_in_pixels = distance_in_cells / cells_per_pixel;
	// A line with a one-pixel soft edge. Lines set thinner than a pixel are drawn one pixel wide
	// and fainter instead: the same average brightness, without shimmering.
	let width = max(frame.grid_line_width, 1.0);
	var coverage = 1.0 - smoothstep(vec2f(width * 0.5 - 0.5), vec2f(width * 0.5 + 0.5), distance_in_pixels);
	coverage *= min(frame.grid_line_width, 1.0);
	// Fade a family out as its cells shrink on screen (12 down to 4 pixels apart).
	coverage *= smoothstep(vec2f(4.0), vec2f(12.0), 1.0 / cells_per_pixel);
	return max(coverage.x, coverage.y);
}

@fragment
fn fragment_main(fragment: Vertex_Output) -> @location(0) vec4f {
	let minor_lines = grid_line_coverage(fragment.plane_position, 1.0);  // every unit
	let major_lines = grid_line_coverage(fragment.plane_position, 10.0); // every 10 units

	// The world axes lying in the plane, half a pixel wider than the grid lines, in their colours.
	// The line where the second coordinate is 0 runs along the first axis, and the other way
	// round.
	var first_axis_color = AXIS_X_COLOR;
	var second_axis_color = AXIS_Z_COLOR;
	if (fragment.plane == 1u) {
		second_axis_color = AXIS_Y_COLOR;
	} else if (fragment.plane == 2u) {
		first_axis_color = AXIS_Z_COLOR;
		second_axis_color = AXIS_Y_COLOR;
	}
	let units_per_pixel = max(fwidth(fragment.plane_position), vec2f(0.000001));
	let axis_half_width = (max(frame.grid_line_width, 1.0) + 0.5) * 0.5;
	let on_first_axis = 1.0 - smoothstep(axis_half_width - 0.5, axis_half_width + 0.5, abs(fragment.plane_position.y) / units_per_pixel.y);
	let on_second_axis = 1.0 - smoothstep(axis_half_width - 0.5, axis_half_width + 0.5, abs(fragment.plane_position.x) / units_per_pixel.x);

	// The editor's colour and opacity for the 1-unit lines; the 10-unit lines are stronger.
	var color = frame.grid_color.rgb;
	var alpha = max(minor_lines * frame.grid_color.a, major_lines * min(frame.grid_color.a * 1.8, 1.0));
	color = mix(color, first_axis_color, on_first_axis);
	alpha = max(alpha, on_first_axis * 0.9);
	color = mix(color, second_axis_color, on_second_axis);
	alpha = max(alpha, on_second_axis * 0.9);

	// Fade with distance so the far grid doesn't shimmer, and by the plane's cross-fade weight.
	let distance_to_camera = length(fragment.plane_position - frame.camera_position * plane_axes(fragment.plane));
	alpha *= frame.grid_plane_opacity[fragment.plane];
	alpha *= 1.0 - smoothstep(GRID_EXTENT * 0.2, GRID_EXTENT * 0.8, distance_to_camera);

	// This pass's share: GRID_DEPTH_PASSES layers of `pass_alpha` blended over each other add up
	// to exactly `alpha` (1 - (1 - pass_alpha)^passes = alpha), and fewer surviving layers give
	// proportionally less.
	let pass_alpha = 1.0 - pow(1.0 - clamp(alpha, 0.0, 1.0), 1.0 / f32(GRID_DEPTH_PASSES));
	return vec4f(color, pass_alpha); // linear; the sRGB scene target encodes it
}
