// MSAA resolve: averages each pixel's samples into the single-sample scene texture.
//
// The GPU's built-in resolve needs source and destination of equal size and resolves the whole
// texture. Ours renders into a sub-rectangle of larger targets (dynamic resolution), so this
// pass resolves just the rendered area, drawn with the viewport set to the render size. Samples
// are read through the sRGB format, so they arrive linear and are averaged in linear light,
// as a hardware resolve of an sRGB target does.

@group(0) @binding(0) var multisampled_color: texture_multisampled_2d<f32>;

@vertex
fn fullscreen_vertex_main(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
	// One triangle that covers the whole viewport: (-1,-1), (3,-1), (-1,3).
	let corner = vec2f(f32((vertex_index << 1u) & 2u), f32(vertex_index & 2u));
	return vec4f(corner * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn resolve_fragment_main(@builtin(position) fragment_position: vec4f) -> @location(0) vec4f {
	let pixel = vec2i(floor(fragment_position.xy));
	let sample_count = textureNumSamples(multisampled_color);
	var sum = vec4f(0.0);
	for (var sample_index = 0u; sample_index < sample_count; sample_index += 1u) {
		sum += textureLoad(multisampled_color, pixel, sample_index);
	}
	return sum / f32(sample_count);
}
