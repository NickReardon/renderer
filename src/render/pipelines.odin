// Bind groups, shaders and pipelines.
//
// Bindings (layouts, buffers, bind groups) are created once. Pipelines are rebuilt whenever
// the game DLL is hot-reloaded, because the WGSL source is embedded in the DLL with #load: edit
// a .wgsl file, run `build.bat game`, and the new shaders appear without restarting. Pipelines
// are built inside a validation error scope, so a shader with errors is reported and the
// previous working pipelines stay in use.
//
// Bind group 0 (all pipelines):      frame uniforms (camera, light, viewport size)
// Bind group 1 (mesh pipeline):      instance records, one per draw
// Bind group 1 (overlay pipeline):   overlay atlas texture + sampler
package render

import "base:runtime"
import "core:fmt"
import "vendor:wgpu"

// The shared declarations go *after* each shader's own source. WGSL allows module-scope
// declarations in any order, and appending keeps error line numbers matching the .wgsl file.
COMMON_WGSL :: #load("shaders/common.wgsl", string)
MESH_WGSL   :: #load("shaders/mesh.wgsl", string) + "\n" + COMMON_WGSL
LINE_WGSL   :: #load("shaders/line.wgsl", string) + "\n" + COMMON_WGSL
GRID_WGSL   :: #load("shaders/grid.wgsl", string) + "\n" + COMMON_WGSL
OVERLAY_WGSL :: #load("shaders/overlay.wgsl", string) + "\n" + COMMON_WGSL

// Called after a hot reload: rebuilds pipelines from the newly loaded shader source.
reload_shaders :: proc(renderer: ^Renderer) {
	if create_pipelines(renderer) {
		fmt.println("render: shaders reloaded")
	} else {
		fmt.eprintln("render: shader reload failed, keeping the previous pipelines")
	}
}

@(private)
create_bindings :: proc(renderer: ^Renderer) {
	frame_layout_entry := wgpu.BindGroupLayoutEntry{
		binding    = 0,
		visibility = {.Vertex, .Fragment},
		buffer     = {type = .Uniform, minBindingSize = size_of(Frame_Uniforms)},
	}
	renderer.frame_layout = wgpu.DeviceCreateBindGroupLayout(renderer.device, &{label = "frame", entryCount = 1, entries = &frame_layout_entry})

	instance_layout_entry := wgpu.BindGroupLayoutEntry{
		binding    = 0,
		visibility = {.Vertex},
		buffer     = {type = .ReadOnlyStorage, minBindingSize = size_of(Instance_Data)},
	}
	renderer.instance_layout = wgpu.DeviceCreateBindGroupLayout(renderer.device, &{label = "instances", entryCount = 1, entries = &instance_layout_entry})

	instance_buffer_size := u64(MAX_DRAWS * size_of(Instance_Data))
	line_buffer_size := u64(len(renderer.line_vertices) * size_of(Debug_Vertex))
	renderer.frame_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{label = "frame uniforms", usage = {.Uniform, .CopyDst}, size = size_of(Frame_Uniforms)})
	renderer.instance_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{label = "instances", usage = {.Storage, .CopyDst}, size = instance_buffer_size})
	renderer.line_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{label = "debug lines", usage = {.Vertex, .CopyDst}, size = line_buffer_size})

	frame_group_entry := wgpu.BindGroupEntry{binding = 0, buffer = renderer.frame_buffer, size = size_of(Frame_Uniforms)}
	renderer.frame_group = wgpu.DeviceCreateBindGroup(renderer.device, &{label = "frame", layout = renderer.frame_layout, entryCount = 1, entries = &frame_group_entry})

	instance_group_entry := wgpu.BindGroupEntry{binding = 0, buffer = renderer.instance_buffer, size = instance_buffer_size}
	renderer.instance_group = wgpu.DeviceCreateBindGroup(renderer.device, &{label = "instances", layout = renderer.instance_layout, entryCount = 1, entries = &instance_group_entry})

	// Overlay: atlas texture + sampler in group 1; quads are per-instance vertex data.
	overlay_layout_entries := [2]wgpu.BindGroupLayoutEntry{
		{binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	renderer.overlay_layout = wgpu.DeviceCreateBindGroupLayout(renderer.device, &{
		label      = "overlay",
		entryCount = len(overlay_layout_entries),
		entries    = &overlay_layout_entries[0],
	})
	renderer.overlay_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{
		label = "overlay quads",
		usage = {.Vertex, .CopyDst},
		size  = u64(MAX_OVERLAY_QUADS * size_of(Overlay_Quad)),
	})
	renderer.overlay_sampler = wgpu.DeviceCreateSampler(renderer.device, &{
		label         = "overlay atlas",
		addressModeU  = .ClampToEdge,
		addressModeV  = .ClampToEdge,
		addressModeW  = .ClampToEdge,
		magFilter     = .Linear,
		minFilter     = .Linear,
		mipmapFilter  = .Nearest,
		lodMaxClamp   = 32,
		maxAnisotropy = 1,
	})

	create_post_bindings(renderer)
}

// (Re)creates the overlay atlas texture and the bind group that points at it.
@(private)
create_atlas_texture :: proc(renderer: ^Renderer, size: [2]i32) {
	release_atlas_texture(renderer)
	renderer.atlas_size = size
	renderer.atlas_texture = wgpu.DeviceCreateTexture(renderer.device, &{
		label         = "overlay atlas",
		usage         = {.TextureBinding, .CopyDst},
		dimension     = ._2D,
		size          = {u32(size.x), u32(size.y), 1},
		format        = .R8Unorm,
		mipLevelCount = 1,
		sampleCount   = 1,
	})
	renderer.atlas_view = wgpu.TextureCreateView(renderer.atlas_texture, nil)
	overlay_group_entries := [2]wgpu.BindGroupEntry{
		{binding = 0, textureView = renderer.atlas_view},
		{binding = 1, sampler = renderer.overlay_sampler},
	}
	renderer.overlay_group = wgpu.DeviceCreateBindGroup(renderer.device, &{
		label      = "overlay",
		layout     = renderer.overlay_layout,
		entryCount = len(overlay_group_entries),
		entries    = &overlay_group_entries[0],
	})
}

@(private)
release_atlas_texture :: proc(renderer: ^Renderer) {
	if renderer.overlay_group != nil do wgpu.BindGroupRelease(renderer.overlay_group)
	if renderer.atlas_view != nil do wgpu.TextureViewRelease(renderer.atlas_view)
	if renderer.atlas_texture != nil do wgpu.TextureRelease(renderer.atlas_texture)
	renderer.overlay_group = nil
	renderer.atlas_view = nil
	renderer.atlas_texture = nil
	renderer.atlas_size = {}
}

// Builds all pipelines. On success they replace the current ones; on failure nothing changes.
@(private)
create_pipelines :: proc(renderer: ^Renderer) -> bool {
	wgpu.DevicePushErrorScope(renderer.device, .Validation)

	mesh_module := create_shader_module(renderer, "mesh.wgsl", MESH_WGSL)
	line_module := create_shader_module(renderer, "line.wgsl", LINE_WGSL)
	grid_module := create_shader_module(renderer, "grid.wgsl", GRID_WGSL)
	overlay_module := create_shader_module(renderer, "overlay.wgsl", OVERLAY_WGSL)
	defer wgpu.ShaderModuleRelease(mesh_module)
	defer wgpu.ShaderModuleRelease(line_module)
	defer wgpu.ShaderModuleRelease(grid_module)
	defer wgpu.ShaderModuleRelease(overlay_module)

	frame_only_layout := wgpu.DeviceCreatePipelineLayout(renderer.device, &{
		label                = "frame only",
		bindGroupLayoutCount = 1,
		bindGroupLayouts     = &renderer.frame_layout,
	})
	defer wgpu.PipelineLayoutRelease(frame_only_layout)
	mesh_group_layouts := [2]wgpu.BindGroupLayout{renderer.frame_layout, renderer.instance_layout}
	frame_and_instances_layout := wgpu.DeviceCreatePipelineLayout(renderer.device, &{
		label                = "frame and instances",
		bindGroupLayoutCount = len(mesh_group_layouts),
		bindGroupLayouts     = &mesh_group_layouts[0],
	})
	defer wgpu.PipelineLayoutRelease(frame_and_instances_layout)
	overlay_group_layouts := [2]wgpu.BindGroupLayout{renderer.frame_layout, renderer.overlay_layout}
	frame_and_overlay_layout := wgpu.DeviceCreatePipelineLayout(renderer.device, &{
		label                = "frame and overlay atlas",
		bindGroupLayoutCount = len(overlay_group_layouts),
		bindGroupLayouts     = &overlay_group_layouts[0],
	})
	defer wgpu.PipelineLayoutRelease(frame_and_overlay_layout)

	// The scene renders into the sRGB scene texture; the overlay renders straight into the window.
	scene_opaque_target := wgpu.ColorTargetState{format = SCENE_COLOR_FORMAT, writeMask = wgpu.ColorWriteMaskFlags_All}
	alpha_blend := wgpu.BlendState{
		color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
	scene_blended_target := wgpu.ColorTargetState{format = SCENE_COLOR_FORMAT, blend = &alpha_blend, writeMask = wgpu.ColorWriteMaskFlags_All}
	window_blended_target := wgpu.ColorTargetState{format = renderer.surface_format, blend = &alpha_blend, writeMask = wgpu.ColorWriteMaskFlags_All}

	// Reverse-Z: nearer fragments have *greater* depth.
	depth_test_and_write := wgpu.DepthStencilState{format = DEPTH_FORMAT, depthWriteEnabled = .True, depthCompare = .Greater}
	depth_test_only := wgpu.DepthStencilState{format = DEPTH_FORMAT, depthWriteEnabled = .False, depthCompare = .Greater}
	single_sample := wgpu.MultisampleState{count = 1, mask = 0xFFFF_FFFF}

	// Meshes: positions and normals in two separate vertex buffers (struct-of-arrays).
	position_attribute := wgpu.VertexAttribute{format = .Float32x3, offset = 0, shaderLocation = 0}
	normal_attribute := wgpu.VertexAttribute{format = .Float32x3, offset = 0, shaderLocation = 1}
	mesh_vertex_buffers := [2]wgpu.VertexBufferLayout{
		{stepMode = .Vertex, arrayStride = size_of([3]f32), attributeCount = 1, attributes = &position_attribute},
		{stepMode = .Vertex, arrayStride = size_of([3]f32), attributeCount = 1, attributes = &normal_attribute},
	}
	mesh_pipeline := wgpu.DeviceCreateRenderPipeline(renderer.device, &{
		label        = "mesh",
		layout       = frame_and_instances_layout,
		vertex       = {
			module      = mesh_module,
			entryPoint  = "vertex_main",
			bufferCount = len(mesh_vertex_buffers),
			buffers     = &mesh_vertex_buffers[0],
		},
		primitive    = {topology = .TriangleList, frontFace = .CCW, cullMode = .Back},
		depthStencil = &depth_test_and_write,
		multisample  = single_sample,
		fragment     = &wgpu.FragmentState{module = mesh_module, entryPoint = "fragment_main", targetCount = 1, targets = &scene_opaque_target},
	})

	// Debug lines: one interleaved buffer of position + color.
	line_attributes := [2]wgpu.VertexAttribute{
		{format = .Float32x3, offset = u64(offset_of(Debug_Vertex, position)), shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Debug_Vertex, color)), shaderLocation = 1},
	}
	line_vertex_buffer := wgpu.VertexBufferLayout{
		stepMode       = .Vertex,
		arrayStride    = size_of(Debug_Vertex),
		attributeCount = len(line_attributes),
		attributes     = &line_attributes[0],
	}
	line_pipeline := wgpu.DeviceCreateRenderPipeline(renderer.device, &{
		label        = "debug lines",
		layout       = frame_only_layout,
		vertex       = {module = line_module, entryPoint = "vertex_main", bufferCount = 1, buffers = &line_vertex_buffer},
		primitive    = {topology = .LineList},
		depthStencil = &depth_test_and_write,
		multisample  = single_sample,
		fragment     = &wgpu.FragmentState{module = line_module, entryPoint = "fragment_main", targetCount = 1, targets = &scene_opaque_target},
	})

	// Grid: no vertex buffers, the quad comes from vertex_index. Blended, no depth writes.
	grid_pipeline := wgpu.DeviceCreateRenderPipeline(renderer.device, &{
		label        = "grid",
		layout       = frame_only_layout,
		vertex       = {module = grid_module, entryPoint = "vertex_main"},
		primitive    = {topology = .TriangleList, cullMode = .None},
		depthStencil = &depth_test_only,
		multisample  = single_sample,
		fragment     = &wgpu.FragmentState{module = grid_module, entryPoint = "fragment_main", targetCount = 1, targets = &scene_blended_target},
	})

	// Overlay: one quad per instance, six generated vertices each, drawn into the window pass
	// (which has no depth buffer).
	overlay_attributes := [8]wgpu.VertexAttribute{
		{format = .Float32x2, offset = u64(offset_of(Overlay_Quad, rect_min)), shaderLocation = 0},
		{format = .Float32x2, offset = u64(offset_of(Overlay_Quad, rect_max)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Overlay_Quad, uv_min)), shaderLocation = 2},
		{format = .Float32x2, offset = u64(offset_of(Overlay_Quad, uv_max)), shaderLocation = 3},
		{format = .Float32x4, offset = u64(offset_of(Overlay_Quad, color)), shaderLocation = 4},
		{format = .Float32, offset = u64(offset_of(Overlay_Quad, corner_radius)), shaderLocation = 5},
		{format = .Float32, offset = u64(offset_of(Overlay_Quad, border_width)), shaderLocation = 6},
		{format = .Uint32, offset = u64(offset_of(Overlay_Quad, mode)), shaderLocation = 7},
	}
	overlay_vertex_buffer := wgpu.VertexBufferLayout{
		stepMode       = .Instance,
		arrayStride    = size_of(Overlay_Quad),
		attributeCount = len(overlay_attributes),
		attributes     = &overlay_attributes[0],
	}
	overlay_pipeline := wgpu.DeviceCreateRenderPipeline(renderer.device, &{
		label        = "overlay",
		layout       = frame_and_overlay_layout,
		vertex       = {module = overlay_module, entryPoint = "vertex_main", bufferCount = 1, buffers = &overlay_vertex_buffer},
		primitive    = {topology = .TriangleList, cullMode = .None},
		multisample  = single_sample,
		fragment     = &wgpu.FragmentState{module = overlay_module, entryPoint = "fragment_main", targetCount = 1, targets = &window_blended_target},
	})

	easu_pipeline, rcas_pipeline, resample_pipeline := create_post_pipelines(renderer)

	if !pop_error_scope(renderer) {
		for pipeline in ([]wgpu.RenderPipeline{mesh_pipeline, line_pipeline, grid_pipeline, overlay_pipeline, easu_pipeline, rcas_pipeline, resample_pipeline}) {
			if pipeline != nil do wgpu.RenderPipelineRelease(pipeline)
		}
		return false
	}

	release_pipelines(renderer)
	renderer.mesh_pipeline = mesh_pipeline
	renderer.line_pipeline = line_pipeline
	renderer.grid_pipeline = grid_pipeline
	renderer.overlay_pipeline = overlay_pipeline
	renderer.easu_pipeline = easu_pipeline
	renderer.rcas_pipeline = rcas_pipeline
	renderer.resample_pipeline = resample_pipeline
	return true
}

@(private)
release_pipelines :: proc(renderer: ^Renderer) {
	pipelines := [?]^wgpu.RenderPipeline{
		&renderer.mesh_pipeline,
		&renderer.line_pipeline,
		&renderer.grid_pipeline,
		&renderer.overlay_pipeline,
		&renderer.easu_pipeline,
		&renderer.rcas_pipeline,
		&renderer.resample_pipeline,
	}
	for pipeline in pipelines {
		if pipeline^ != nil do wgpu.RenderPipelineRelease(pipeline^)
		pipeline^ = nil
	}
}

@(private)
create_shader_module :: proc(renderer: ^Renderer, label, source: string) -> wgpu.ShaderModule {
	return wgpu.DeviceCreateShaderModule(renderer.device, &{
		label       = label,
		nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = source},
	})
}

// Waits for the result of the innermost error scope. Returns false (after printing the error,
// which for shaders includes the WGSL line and column) if anything inside the scope failed.
@(private)
pop_error_scope :: proc(renderer: ^Renderer) -> bool {
	Scope_Result :: struct {
		done:   bool,
		failed: bool,
	}
	scope_result: Scope_Result
	on_pop :: proc "c" (status: wgpu.PopErrorScopeStatus, error_type: wgpu.ErrorType, message: string, user_data, user_data_2: rawptr) {
		context = runtime.default_context()
		result := (^Scope_Result)(user_data)
		result.done = true
		if status != .Success || error_type != .NoError {
			result.failed = true
			fmt.eprintfln("render: %v error:\n%s", error_type, message)
		}
	}
	wgpu.DevicePopErrorScope(renderer.device, {mode = .AllowProcessEvents, callback = on_pop, userdata1 = &scope_result})
	for !scope_result.done {
		wgpu.InstanceProcessEvents(renderer.instance)
	}
	return !scope_result.failed
}
