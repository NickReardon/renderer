// Appended to every shader in this folder (see pipelines.odin).
// Frame must match `Frame_Uniforms` in render.odin byte for byte.

struct Frame {
	view_projection: mat4x4f,
	camera_position: vec3f,
	gamma_correct:   f32,   // 1 when the surface isn't sRGB and we must encode manually
	light_direction: vec3f, // direction light travels, normalized
	padding:         f32,
	viewport_size:   vec2f, // pixels
	padding_2:       vec2f,
	grid_opacity:    vec4f, // per grid plane: x = XZ (ground), y = XY, z = YZ
}

@group(0) @binding(0) var<uniform> frame: Frame;

// Lighting is computed in linear space. An sRGB surface converts to display encoding in
// hardware; otherwise approximate it here.
fn encode_output(linear_color: vec3f) -> vec3f {
	if (frame.gamma_correct > 0.5) {
		return pow(max(linear_color, vec3f(0.0)), vec3f(1.0 / 2.2));
	}
	return linear_color;
}
