// Anti-aliased grid on a world plane through the origin, after Ben Golus, "The Best Darn Grid
// Shader (Yet)" (docs/REFERENCES.md). Lines are computed per pixel from screen-space
// derivatives instead of drawn as geometry, so they stay one pixel sharp at any distance and
// fade out before they alias.
//
// It's drawn as one instance per plane (0 = XZ, the ground; 1 = XY; 2 = YZ), each faded by
// frame.grid_opacity. Orthographic views that see the ground edge-on fade it out and fade in
// the vertical plane facing the view (the editor picks the opacities), so turning the view
// cross-fades the grids instead of switching them. The shader works in 2D plane coordinates;
// only the plane's two world axes change.

const GRID_EXTENT: f32 = 500.0; // half-size of the quad, in world units

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
fn vertex_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) plane: u32) -> Vertex_Output {
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
	output.plane_position = plane_position;
	output.plane = plane;
	if (frame.grid_opacity[plane] <= 0.0) {
		output.clip_position = vec4f(0.0); // collapsed: no pixels, no cost
	}
	return output;
}

// Coverage (0..1) of grid lines at `grid_coordinate`, with lines `line_width` cells wide.
fn pristine_grid(grid_coordinate: vec2f, line_width: vec2f) -> f32 {
	let derivative_x = dpdx(grid_coordinate);
	let derivative_y = dpdy(grid_coordinate);
	let cells_per_pixel = vec2f(
		length(vec2f(derivative_x.x, derivative_y.x)),
		length(vec2f(derivative_x.y, derivative_y.y)),
	);
	// Never draw a line thinner than one pixel; thinner lines are faded instead, which keeps
	// their average brightness correct.
	let draw_width = clamp(line_width, cells_per_pixel, vec2f(0.5));
	let antialias_width = max(cells_per_pixel, vec2f(0.000001)) * 1.5;
	let distance_to_line = 1.0 - abs(fract(grid_coordinate) * 2.0 - 1.0);
	var coverage = 1.0 - smoothstep(draw_width - antialias_width, draw_width + antialias_width, distance_to_line);
	coverage *= clamp(line_width / draw_width, vec2f(0.0), vec2f(1.0));
	// Where cells shrink below a pixel, blend to the average coverage instead of moiré.
	coverage = mix(coverage, line_width, clamp(cells_per_pixel * 2.0 - 1.0, vec2f(0.0), vec2f(1.0)));
	return mix(coverage.x, 1.0, coverage.y);
}

@fragment
fn fragment_main(fragment: Vertex_Output) -> @location(0) vec4f {
	let minor_lines = pristine_grid(fragment.plane_position, vec2f(0.02));        // every unit
	let major_lines = pristine_grid(fragment.plane_position / 10.0, vec2f(0.02)); // every 10 units

	// The world axes lying in the plane, ~1.5 pixels wide, in their colours. The line where the
	// second coordinate is 0 runs along the first axis, and the other way round.
	var first_axis_color = AXIS_X_COLOR;
	var second_axis_color = AXIS_Z_COLOR;
	if (fragment.plane == 1u) {
		second_axis_color = AXIS_Y_COLOR;
	} else if (fragment.plane == 2u) {
		first_axis_color = AXIS_Z_COLOR;
		second_axis_color = AXIS_Y_COLOR;
	}
	let units_per_pixel = fwidth(fragment.plane_position);
	let on_first_axis = 1.0 - clamp(abs(fragment.plane_position.y) / (units_per_pixel.y * 1.5), 0.0, 1.0);
	let on_second_axis = 1.0 - clamp(abs(fragment.plane_position.x) / (units_per_pixel.x * 1.5), 0.0, 1.0);

	var color = vec3f(0.45);
	var alpha = max(minor_lines * 0.3, major_lines * 0.55);
	color = mix(color, first_axis_color, on_first_axis);
	alpha = max(alpha, on_first_axis * 0.9);
	color = mix(color, second_axis_color, on_second_axis);
	alpha = max(alpha, on_second_axis * 0.9);

	// Fade with distance so the far grid doesn't shimmer.
	let distance_to_camera = length(fragment.plane_position - frame.camera_position * plane_axes(fragment.plane));
	alpha *= frame.grid_opacity[fragment.plane];
	alpha *= 1.0 - smoothstep(GRID_EXTENT * 0.2, GRID_EXTENT * 0.8, distance_to_camera);

	return vec4f(color, alpha); // linear; the sRGB scene target encodes it
}
