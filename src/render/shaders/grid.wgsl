// Anti-aliased ground grid on the horizontal plane (y = 0), after Ben Golus, "The Best Darn
// Grid Shader (Yet)" (docs/REFERENCES.md). Lines are computed per pixel from screen-space
// derivatives instead of drawn as geometry, so they stay one pixel sharp at any distance and
// fade out before they alias.

const GRID_EXTENT: f32 = 500.0; // half-size of the quad, in world units

struct Vertex_Output {
	@builtin(position) clip_position: vec4f,
	@location(0) ground_position: vec2f, // world (x, z)
}

@vertex
fn vertex_main(@builtin(vertex_index) vertex_index: u32) -> Vertex_Output {
	// Two triangles forming a large square, re-centred under the camera every frame so the
	// grid never visibly ends.
	var corners = array<vec2f, 6>(
		vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
		vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(-1.0, 1.0),
	);
	let ground_position = frame.camera_position.xz + corners[vertex_index] * GRID_EXTENT;
	var output: Vertex_Output;
	output.clip_position = frame.view_projection * vec4f(ground_position.x, 0.0, ground_position.y, 1.0);
	output.ground_position = ground_position;
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
	let minor_lines = pristine_grid(fragment.ground_position, vec2f(0.02));        // every unit
	let major_lines = pristine_grid(fragment.ground_position / 10.0, vec2f(0.02)); // every 10 units

	// The X axis (where z = 0) in red and the Z axis (where x = 0) in blue, ~1.5 pixels wide.
	let units_per_pixel = fwidth(fragment.ground_position);
	let on_x_axis = 1.0 - clamp(abs(fragment.ground_position.y) / (units_per_pixel.y * 1.5), 0.0, 1.0);
	let on_z_axis = 1.0 - clamp(abs(fragment.ground_position.x) / (units_per_pixel.x * 1.5), 0.0, 1.0);

	var color = vec3f(0.45);
	var alpha = max(minor_lines * 0.3, major_lines * 0.55);
	color = mix(color, vec3f(0.85, 0.2, 0.2), on_x_axis);
	alpha = max(alpha, on_x_axis * 0.9);
	color = mix(color, vec3f(0.2, 0.4, 0.9), on_z_axis);
	alpha = max(alpha, on_z_axis * 0.9);

	// Fade with distance so the far grid doesn't shimmer.
	let distance_to_camera = length(fragment.ground_position - frame.camera_position.xz);
	alpha *= 1.0 - smoothstep(GRID_EXTENT * 0.2, GRID_EXTENT * 0.8, distance_to_camera);

	return vec4f(color, alpha); // linear; the sRGB scene target encodes it
}
