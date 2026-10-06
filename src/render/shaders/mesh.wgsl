// Opaque meshes, drawn instanced: per-draw data comes from a storage buffer indexed by
// instance_index, so consecutive draws of the same mesh collapse into one draw call.
// Instance must match `Instance_Data` in render.odin.

struct Instance {
	world:         mat4x4f,
	normal_matrix: mat4x4f, // inverse transpose of world, keeps normals right under non-uniform scale
	color:         vec4f,
}

@group(1) @binding(0) var<storage, read> instances: array<Instance>;

struct Vertex_Output {
	@builtin(position) clip_position: vec4f,
	@location(0) normal: vec3f,
	@location(1) color: vec4f,
}

@vertex
fn vertex_main(
	@location(0) position: vec3f,
	@location(1) normal: vec3f,
	@builtin(instance_index) instance_index: u32,
) -> Vertex_Output {
	let instance = instances[instance_index];
	var output: Vertex_Output;
	output.clip_position = frame.view_projection * instance.world * vec4f(position, 1.0);
	output.normal = (instance.normal_matrix * vec4f(normal, 0.0)).xyz;
	output.color = instance.color;
	return output;
}

@fragment
fn fragment_main(fragment: Vertex_Output) -> @location(0) vec4f {
	let normal = normalize(fragment.normal);
	let diffuse = max(dot(normal, -frame.light_direction), 0.0);
	// Hemisphere ambient: a cool sky above (+Y), warm ground below, so faces turned away from
	// the light still show their shape.
	let ground_color = vec3f(0.07, 0.06, 0.05);
	let sky_color = vec3f(0.16, 0.18, 0.22);
	let ambient = mix(ground_color, sky_color, normal.y * 0.5 + 0.5);
	let lit_color = fragment.color.rgb * (ambient + diffuse * vec3f(1.0, 0.96, 0.9));
	return vec4f(encode_output(lit_color), fragment.color.a);
}
