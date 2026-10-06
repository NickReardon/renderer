// Scene render targets, the post passes that scale the scene into the viewport (FSR 1 or
// bilinear), and GPU frame timing.
//
// Dynamic resolution without reallocation: the scene targets are allocated once at the window
// size times MAX_RENDER_SCALE, and each frame renders into the top-left `render_size` part of
// them. Changing the scale changes a viewport, not a texture. (Unreal and most console engines
// do the same.) Targets are only rebuilt when the window size changes.
//
// GPU timing: the first pass writes a timestamp when it starts and the window pass one when it
// ends. The pair is resolved into a buffer and copied into one of a few readback buffers, which
// is mapped asynchronously and read a frame or two later, so measuring never stalls the CPU.
package render

import "core:fmt"
import "vendor:wgpu"

SCENE_COLOR_FORMAT         :: wgpu.TextureFormat.RGBA8UnormSrgb
SCENE_COLOR_ENCODED_FORMAT :: wgpu.TextureFormat.RGBA8Unorm // same bytes, no sRGB decode on read
UPSCALED_FORMAT            :: wgpu.TextureFormat.RGBA8Unorm // EASU output: encoded values, read by RCAS
TIMESTAMP_BYTES            :: 2 * size_of(u64)

POST_WGSL    :: #load("shaders/post.wgsl", string)
RESOLVE_WGSL :: #load("shaders/resolve.wgsl", string)

// Constants for FSR EASU (con0 of FsrEasuCon in ffx_fsr1.h): map an output pixel to the input
// texel position it samples, at pixel centres. render_size: pixels actually rendered;
// output_size: viewport size the image is scaled to. AMD's con1..con3 hold texture coordinates
// for four gathers; our port loads each tap as a texel clamped to the rendered region instead
// (see post.wgsl), so those stay zero.
easu_constants :: proc(render_size, output_size: [2]f32) -> (constants: [4][4]f32) {
	input_per_output := render_size / output_size
	constants[0] = {input_per_output.x, input_per_output.y, 0.5 * input_per_output.x - 0.5, 0.5 * input_per_output.y - 0.5}
	return
}

// (Re)creates the scene targets and the EASU output for a new window size, and the bind groups
// that point at them.
@(private)
create_scene_targets :: proc(renderer: ^Renderer, window_size: [2]i32) {
	release_scene_targets(renderer)
	maximum := renderer.max_texture_size if renderer.max_texture_size > 0 else 8192
	renderer.scene_target_size = {
		clamp(i32(f32(window_size.x) * MAX_RENDER_SCALE + 0.5), 1, maximum),
		clamp(i32(f32(window_size.y) * MAX_RENDER_SCALE + 0.5), 1, maximum),
	}
	scene_extent := wgpu.Extent3D{u32(renderer.scene_target_size.x), u32(renderer.scene_target_size.y), 1}

	encoded_format := SCENE_COLOR_ENCODED_FORMAT
	renderer.scene_color_texture = wgpu.DeviceCreateTexture(renderer.device, &{
		label           = "scene color",
		usage           = {.RenderAttachment, .TextureBinding},
		dimension       = ._2D,
		size            = scene_extent,
		format          = SCENE_COLOR_FORMAT,
		mipLevelCount   = 1,
		sampleCount     = 1,
		viewFormatCount = 1,
		viewFormats     = &encoded_format,
	})
	renderer.scene_color_view = wgpu.TextureCreateView(renderer.scene_color_texture, nil)
	renderer.scene_color_encoded_view = wgpu.TextureCreateView(renderer.scene_color_texture, &{
		label           = "scene color (encoded)",
		format          = SCENE_COLOR_ENCODED_FORMAT,
		dimension       = ._2D,
		mipLevelCount   = 1,
		arrayLayerCount = 1,
		aspect          = .All,
	})
	renderer.scene_depth_texture = wgpu.DeviceCreateTexture(renderer.device, &{
		label         = "scene depth",
		usage         = {.RenderAttachment},
		dimension     = ._2D,
		size          = scene_extent,
		format        = DEPTH_FORMAT,
		mipLevelCount = 1,
		sampleCount   = 1,
	})
	renderer.scene_depth_view = wgpu.TextureCreateView(renderer.scene_depth_texture, nil)

	renderer.upscaled_texture = wgpu.DeviceCreateTexture(renderer.device, &{
		label         = "upscaled",
		usage         = {.RenderAttachment, .TextureBinding},
		dimension     = ._2D,
		size          = {u32(window_size.x), u32(window_size.y), 1},
		format        = UPSCALED_FORMAT,
		mipLevelCount = 1,
		sampleCount   = 1,
	})
	renderer.upscaled_view = wgpu.TextureCreateView(renderer.upscaled_texture, nil)

	renderer.easu_group = create_post_group(renderer, "easu", renderer.scene_color_encoded_view)
	renderer.rcas_group = create_post_group(renderer, "rcas", renderer.upscaled_view)
	renderer.resample_group = create_post_group(renderer, "resample", renderer.scene_color_view)
}

@(private)
create_post_group :: proc(renderer: ^Renderer, label: string, source_view: wgpu.TextureView) -> wgpu.BindGroup {
	entries := [3]wgpu.BindGroupEntry{
		{binding = 0, buffer = renderer.post_buffer, size = size_of(Post_Uniforms)},
		{binding = 1, textureView = source_view},
		{binding = 2, sampler = renderer.overlay_sampler}, // linear filtering, clamp to edge
	}
	return wgpu.DeviceCreateBindGroup(renderer.device, &{label = label, layout = renderer.post_layout, entryCount = len(entries), entries = &entries[0]})
}

@(private)
release_scene_targets :: proc(renderer: ^Renderer) {
	if renderer.easu_group != nil do wgpu.BindGroupRelease(renderer.easu_group)
	if renderer.rcas_group != nil do wgpu.BindGroupRelease(renderer.rcas_group)
	if renderer.resample_group != nil do wgpu.BindGroupRelease(renderer.resample_group)
	if renderer.upscaled_view != nil do wgpu.TextureViewRelease(renderer.upscaled_view)
	if renderer.upscaled_texture != nil do wgpu.TextureRelease(renderer.upscaled_texture)
	if renderer.scene_depth_view != nil do wgpu.TextureViewRelease(renderer.scene_depth_view)
	if renderer.scene_depth_texture != nil do wgpu.TextureRelease(renderer.scene_depth_texture)
	if renderer.scene_color_encoded_view != nil do wgpu.TextureViewRelease(renderer.scene_color_encoded_view)
	if renderer.scene_color_view != nil do wgpu.TextureViewRelease(renderer.scene_color_view)
	if renderer.scene_color_texture != nil do wgpu.TextureRelease(renderer.scene_color_texture)
	renderer.easu_group, renderer.rcas_group, renderer.resample_group = nil, nil, nil
	renderer.upscaled_view, renderer.upscaled_texture = nil, nil
	renderer.scene_depth_view, renderer.scene_depth_texture = nil, nil
	renderer.scene_color_encoded_view, renderer.scene_color_view, renderer.scene_color_texture = nil, nil, nil
	renderer.scene_target_size = {}
}

// Makes sure the multisampled targets can hold `render_size`. They only grow (rounded up to
// 256-pixel steps), so dynamic resolution doesn't reallocate on every adjustment; they're
// released when the window resizes or MSAA changes, and memory then follows actual use.
@(private)
ensure_msaa_targets :: proc(renderer: ^Renderer, render_size: [2]i32) {
	if renderer.msaa_color_texture != nil && render_size.x <= renderer.msaa_target_size.x && render_size.y <= renderer.msaa_target_size.y {
		return
	}
	MSAA_SIZE_STEP :: 256
	maximum := renderer.max_texture_size if renderer.max_texture_size > 0 else 8192
	new_size: [2]i32
	for axis in 0 ..< 2 {
		wanted := max(render_size[axis], renderer.msaa_target_size[axis])
		new_size[axis] = min((wanted + MSAA_SIZE_STEP - 1) / MSAA_SIZE_STEP * MSAA_SIZE_STEP, maximum)
	}
	release_msaa_targets(renderer)
	renderer.msaa_target_size = new_size
	extent := wgpu.Extent3D{u32(new_size.x), u32(new_size.y), 1}

	renderer.msaa_color_texture = wgpu.DeviceCreateTexture(renderer.device, &{
		label         = "scene color (msaa)",
		usage         = {.RenderAttachment, .TextureBinding},
		dimension     = ._2D,
		size          = extent,
		format        = SCENE_COLOR_FORMAT,
		mipLevelCount = 1,
		sampleCount   = renderer.msaa_sample_count,
	})
	renderer.msaa_color_view = wgpu.TextureCreateView(renderer.msaa_color_texture, nil)
	renderer.msaa_depth_texture = wgpu.DeviceCreateTexture(renderer.device, &{
		label         = "scene depth (msaa)",
		usage         = {.RenderAttachment},
		dimension     = ._2D,
		size          = extent,
		format        = DEPTH_FORMAT,
		mipLevelCount = 1,
		sampleCount   = renderer.msaa_sample_count,
	})
	renderer.msaa_depth_view = wgpu.TextureCreateView(renderer.msaa_depth_texture, nil)

	resolve_entry := wgpu.BindGroupEntry{binding = 0, textureView = renderer.msaa_color_view}
	renderer.resolve_group = wgpu.DeviceCreateBindGroup(renderer.device, &{label = "msaa resolve", layout = renderer.resolve_layout, entryCount = 1, entries = &resolve_entry})
}

@(private)
release_msaa_targets :: proc(renderer: ^Renderer) {
	if renderer.resolve_group != nil do wgpu.BindGroupRelease(renderer.resolve_group)
	if renderer.msaa_depth_view != nil do wgpu.TextureViewRelease(renderer.msaa_depth_view)
	if renderer.msaa_depth_texture != nil do wgpu.TextureRelease(renderer.msaa_depth_texture)
	if renderer.msaa_color_view != nil do wgpu.TextureViewRelease(renderer.msaa_color_view)
	if renderer.msaa_color_texture != nil do wgpu.TextureRelease(renderer.msaa_color_texture)
	renderer.resolve_group = nil
	renderer.msaa_depth_view, renderer.msaa_depth_texture = nil, nil
	renderer.msaa_color_view, renderer.msaa_color_texture = nil, nil
	renderer.msaa_target_size = {}
}

// Creates the post-pass and resolve bind group layouts and the post uniform buffer (once).
@(private)
create_post_bindings :: proc(renderer: ^Renderer) {
	resolve_entry := wgpu.BindGroupLayoutEntry{
		binding    = 0,
		visibility = {.Fragment},
		texture    = {sampleType = .UnfilterableFloat, viewDimension = ._2D, multisampled = true},
	}
	renderer.resolve_layout = wgpu.DeviceCreateBindGroupLayout(renderer.device, &{label = "msaa resolve", entryCount = 1, entries = &resolve_entry})

	layout_entries := [3]wgpu.BindGroupLayoutEntry{
		{binding = 0, visibility = {.Fragment}, buffer = {type = .Uniform, minBindingSize = size_of(Post_Uniforms)}},
		{binding = 1, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 2, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	renderer.post_layout = wgpu.DeviceCreateBindGroupLayout(renderer.device, &{label = "post", entryCount = len(layout_entries), entries = &layout_entries[0]})
	renderer.post_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{label = "post uniforms", usage = {.Uniform, .CopyDst}, size = size_of(Post_Uniforms)})
}

@(private)
release_post_bindings :: proc(renderer: ^Renderer) {
	if renderer.post_buffer != nil do wgpu.BufferRelease(renderer.post_buffer)
	if renderer.post_layout != nil do wgpu.BindGroupLayoutRelease(renderer.post_layout)
	if renderer.resolve_layout != nil do wgpu.BindGroupLayoutRelease(renderer.resolve_layout)
	renderer.post_buffer, renderer.post_layout, renderer.resolve_layout = nil, nil, nil
}

// Builds the EASU, RCAS, resample and MSAA resolve pipelines. Called inside create_pipelines'
// error scope.
@(private)
create_post_pipelines :: proc(renderer: ^Renderer) -> (easu_pipeline, rcas_pipeline, resample_pipeline, resolve_pipeline: wgpu.RenderPipeline) {
	post_module := create_shader_module(renderer, "post.wgsl", POST_WGSL)
	defer wgpu.ShaderModuleRelease(post_module)
	post_pipeline_layout := wgpu.DeviceCreatePipelineLayout(renderer.device, &{label = "post", bindGroupLayoutCount = 1, bindGroupLayouts = &renderer.post_layout})
	defer wgpu.PipelineLayoutRelease(post_pipeline_layout)

	create :: proc(renderer: ^Renderer, label: string, module: wgpu.ShaderModule, layout: wgpu.PipelineLayout, entry_point: string, format: wgpu.TextureFormat) -> wgpu.RenderPipeline {
		target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
		return wgpu.DeviceCreateRenderPipeline(renderer.device, &{
			label       = label,
			layout      = layout,
			vertex      = {module = module, entryPoint = "fullscreen_vertex_main"},
			primitive   = {topology = .TriangleList, cullMode = .None},
			multisample = {count = 1, mask = 0xFFFF_FFFF},
			fragment    = &wgpu.FragmentState{module = module, entryPoint = entry_point, targetCount = 1, targets = &target},
		})
	}
	easu_pipeline = create(renderer, "fsr easu", post_module, post_pipeline_layout, "easu_fragment_main", UPSCALED_FORMAT)
	rcas_pipeline = create(renderer, "fsr rcas", post_module, post_pipeline_layout, "rcas_fragment_main", renderer.surface_format)
	resample_pipeline = create(renderer, "resample", post_module, post_pipeline_layout, "resample_fragment_main", renderer.surface_format)

	resolve_module := create_shader_module(renderer, "resolve.wgsl", RESOLVE_WGSL)
	defer wgpu.ShaderModuleRelease(resolve_module)
	resolve_pipeline_layout := wgpu.DeviceCreatePipelineLayout(renderer.device, &{label = "msaa resolve", bindGroupLayoutCount = 1, bindGroupLayouts = &renderer.resolve_layout})
	defer wgpu.PipelineLayoutRelease(resolve_pipeline_layout)
	resolve_pipeline = create(renderer, "msaa resolve", resolve_module, resolve_pipeline_layout, "resolve_fragment_main", SCENE_COLOR_FORMAT)
	return
}

// --- GPU timing ---------------------------------------------------------------------------------

@(private)
create_timestamp_resources :: proc(renderer: ^Renderer) {
	if !renderer.timestamps_supported {
		return
	}
	renderer.timestamp_period = wgpu.QueueGetTimestampPeriod(renderer.queue)
	renderer.timestamp_query_set = wgpu.DeviceCreateQuerySet(renderer.device, &{label = "frame timestamps", type = .Timestamp, count = 2})
	renderer.timestamp_resolve_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{label = "timestamp resolve", usage = {.QueryResolve, .CopySrc}, size = TIMESTAMP_BYTES})
	for &readback in renderer.timestamp_readbacks {
		readback.buffer = wgpu.DeviceCreateBuffer(renderer.device, &{label = "timestamp readback", usage = {.MapRead, .CopyDst}, size = TIMESTAMP_BYTES})
		readback.state = .Free
	}
}

@(private)
release_timestamp_resources :: proc(renderer: ^Renderer) {
	// Let in-flight maps finish, so their callbacks don't write into released memory.
	for attempt := 0; attempt < 100 && any_timestamp_readback_pending(renderer); attempt += 1 {
		wgpu.DevicePoll(renderer.device, true)
		wgpu.InstanceProcessEvents(renderer.instance)
	}
	for &readback in renderer.timestamp_readbacks {
		if readback.state == .Ready {
			wgpu.BufferUnmap(readback.buffer)
		}
		if readback.buffer != nil do wgpu.BufferRelease(readback.buffer)
		readback = {}
	}
	if renderer.timestamp_resolve_buffer != nil do wgpu.BufferRelease(renderer.timestamp_resolve_buffer)
	if renderer.timestamp_query_set != nil do wgpu.QuerySetRelease(renderer.timestamp_query_set)
	renderer.timestamp_resolve_buffer, renderer.timestamp_query_set = nil, nil
}

@(private)
any_timestamp_readback_pending :: proc(renderer: ^Renderer) -> bool {
	for readback in renderer.timestamp_readbacks {
		if readback.state == .Pending {
			return true
		}
	}
	return false
}

// After submitting a frame whose timestamps were copied into this readback buffer.
@(private)
start_timestamp_readback :: proc(renderer: ^Renderer, slot: int) {
	readback := &renderer.timestamp_readbacks[slot]
	readback.state = .Pending
	on_mapped :: proc "c" (status: wgpu.MapAsyncStatus, message: string, user_data, user_data_2: rawptr) {
		readback := (^Timestamp_Readback)(user_data)
		readback.state = .Ready if status == .Success else .Failed
	}
	wgpu.BufferMapAsync(readback.buffer, {.Read}, 0, TIMESTAMP_BYTES, {mode = .AllowProcessEvents, callback = on_mapped, userdata1 = readback})
}

// Reads any finished measurements without waiting. Updates gpu_frame_milliseconds.
@(private)
collect_gpu_timings :: proc(renderer: ^Renderer) {
	if !renderer.timestamps_supported {
		return
	}
	wgpu.DevicePoll(renderer.device, false)
	wgpu.InstanceProcessEvents(renderer.instance)
	for &readback in renderer.timestamp_readbacks {
		switch readback.state {
		case .Ready:
			mapped := wgpu.BufferGetConstMappedRange(readback.buffer, 0, TIMESTAMP_BYTES)
			timestamps := (^[2]u64)(raw_data(mapped))^
			if timestamps[1] > timestamps[0] {
				nanoseconds := f64(timestamps[1] - timestamps[0]) * f64(renderer.timestamp_period)
				renderer.gpu_frame_milliseconds = f32(nanoseconds / 1_000_000)
			}
			wgpu.BufferUnmap(readback.buffer)
			readback.state = .Free
		case .Failed:
			readback.state = .Free
		case .Free, .Pending:
		}
	}
}

// Logged once at startup, so the log shows whether dynamic resolution can measure the GPU.
@(private)
report_timestamp_support :: proc(renderer: ^Renderer) {
	if renderer.timestamps_supported {
		fmt.printfln("render: GPU timestamps available (%.3f ns per tick)", renderer.timestamp_period)
	} else {
		fmt.println("render: GPU timestamps not available; dynamic resolution has no GPU timing")
	}
}
