// Immediate-mode debug lines: world-space positions with a color per vertex.

struct Vertex_Output {
	@builtin(position) clip_position: vec4f,
	@location(0) color: vec4f,
}

@vertex
fn vertex_main(@location(0) position: vec3f, @location(1) color: vec4f) -> Vertex_Output {
	var output: Vertex_Output;
	output.clip_position = frame.view_projection * vec4f(position, 1.0);
	output.color = color;
	return output;
}

@fragment
fn fragment_main(fragment: Vertex_Output) -> @location(0) vec4f {
	return vec4f(encode_output(fragment.color.rgb), fragment.color.a);
}
