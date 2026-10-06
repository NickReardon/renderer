// Renderer: the only package that talks to the GPU (wgpu).
//
// The engine only sees handles and plain structs:
//   - meshes are uploaded once with `create_mesh` and referred to by `Mesh_Handle`;
//   - each frame the engine calls `begin_frame`, adds draws with `draw_mesh` and lines with
//     `debug_line` (immediate mode: nothing carries over to the next frame), then `end_frame`;
//   - `end_frame` sorts the draw list by key, so draws of the same mesh end up next to each
//     other and are submitted as one instanced draw call. (Ericson, "Order your graphics draw
//     calls around!", docs/REFERENCES.md)
//
// All storage is fixed-capacity arrays inside `Renderer`, so the renderer is one block of plain
// data that lives in Game_Memory and survives hot reload. wgpu objects are opaque handles owned
// by wgpu_native.dll, which stays loaded across reloads.
//
// Files: render.odin (API and frame submission), device.odin (instance, device, surface),
// pipelines.odin (bind groups, shaders, pipelines), shaders/*.wgsl.
package render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "vendor:wgpu"

MAX_MESHES          :: 1024
MAX_DRAWS           :: 16 * 1024
MAX_DEBUG_LINES     :: 64 * 1024
MAX_OVERLAY_QUADS   :: 32 * 1024
MAX_OVERLAY_BATCHES :: 512

// Slot index into Renderer.meshes plus the slot's generation when the handle was made. A handle
// whose generation no longer matches refers to a destroyed mesh and is ignored. Index 0 is never
// used, so the zero value means "no mesh".
Mesh_Handle :: struct {
	index:      u32,
	generation: u32,
}

Camera :: struct {
	view:         matrix[4, 4]f32,
	projection:   matrix[4, 4]f32,
	position:     [3]f32,
	viewport_min: [2]f32, // pixels; the part of the window the 3D scene is drawn into.
	viewport_max: [2]f32, // Both zero = the whole window.
}

Frame_Settings :: struct {
	clear_color:     [4]f32,   // linear
	show_grid:       bool,
	capture:         bool,     // read this frame back to the CPU; end_frame returns the pixels
	render_scale:    f32,      // scene resolution / viewport resolution, MIN..MAX_RENDER_SCALE; 0 = 1
	upscaler:        Upscaler, // used when render_scale < 1
	sharpness_stops: f32,      // FSR RCAS: 0 = strongest sharpening, each stop halves it
	vsync:           bool,
	msaa_samples:    u32,      // 1 (off) or 4; anything else means 1
}

MIN_RENDER_SCALE :: 0.25
MAX_RENDER_SCALE :: 2.0

Upscaler :: enum {
	Fsr,      // AMD FSR 1: EASU edge-adaptive upscale + RCAS sharpening
	Bilinear, // plain bilinear filtering, for comparison
}

Draw :: struct {
	sort_key: u64,
	mesh:     Mesh_Handle,
	world:    matrix[4, 4]f32,
	color:    [4]f32, // linear
}

Debug_Vertex :: struct {
	position: [3]f32,
	color:    [4]f32,
}

// GPU-side layouts. These must match the WGSL structs byte for byte; the asserts catch drift.
Frame_Uniforms :: struct {
	view_projection: matrix[4, 4]f32,
	camera_position: [3]f32,
	gamma_correct:   f32,
	light_direction: [3]f32,
	padding:         f32,
	viewport_size:   [2]f32, // pixels
	padding_2:       [2]f32,
}
#assert(size_of(Frame_Uniforms) == 112)

// One 2D overlay element in pixel coordinates (origin top-left): a rounded rectangle, a
// rectangle outline, or a glyph sampled from the overlay atlas. Overlay colors are sRGB, as
// authored in UI themes. Uploaded as per-instance vertex data; must match overlay.wgsl.
Overlay_Quad :: struct {
	rect_min:      [2]f32,
	rect_max:      [2]f32,
	uv_min:        [2]f32,
	uv_max:        [2]f32,
	color:         [4]f32,
	corner_radius: f32,
	border_width:  f32, // 0 = filled
	mode:          Overlay_Mode,
	padding:       f32,
}
#assert(size_of(Overlay_Quad) == 64)

Overlay_Mode :: enum u32 {
	Shape = 0,
	Glyph = 1,
}

// A run of overlay quads that share one scissor rectangle.
Overlay_Batch :: struct {
	first_quad:  u32,
	quad_count:  u32,
	scissor_min: [2]f32,
	scissor_max: [2]f32,
}

Instance_Data :: struct {
	world:         matrix[4, 4]f32,
	normal_matrix: matrix[4, 4]f32,
	color:         [4]f32,
}
#assert(size_of(Instance_Data) == 144)

// Must match `Post_Uniforms` in shaders/post.wgsl.
Post_Uniforms :: struct {
	easu_constants:  [4][4]f32,
	output_offset:   [2]f32,
	output_size:     [2]f32,
	source_uv_scale: [2]f32,
	rcas_sharpness:  f32,
	surface_is_srgb: f32,
}
#assert(size_of(Post_Uniforms) == 96)

TIMESTAMP_READBACK_COUNT :: 4

Timestamp_Readback :: struct {
	buffer: wgpu.Buffer,
	state:  Readback_State,
}

Readback_State :: enum {
	Free,    // can receive this frame's timestamps
	Pending, // copy submitted, waiting for the map to finish
	Ready,   // mapped, values can be read
	Failed,
}

Gpu_Mesh :: struct {
	generation:       u32,
	alive:            bool,
	index_count:      u32,
	position_buffer:  wgpu.Buffer,
	normal_buffer:    wgpu.Buffer,
	index_buffer:     wgpu.Buffer,
}

Renderer :: struct {
	// Device and window surface (device.odin)
	instance:          wgpu.Instance,
	surface:           wgpu.Surface,
	adapter:           wgpu.Adapter,
	device:            wgpu.Device,
	queue:             wgpu.Queue,
	surface_format:    wgpu.TextureFormat,
	surface_copyable:  bool, // surface textures can be copied from (needed for frame capture)
	gamma_correct:     bool, // surface isn't sRGB, so shaders encode output themselves
	surface_size:      [2]i32,
	max_texture_size:  i32,
	vsync:             bool,
	immediate_present_supported: bool,
	mailbox_present_supported:   bool,

	// Scene render targets and post passes (post.odin). The scene renders into scene_color at
	// render resolution, then a post pass scales it into the window's viewport.
	scene_target_size:        [2]i32, // allocated size: the window times MAX_RENDER_SCALE
	scene_color_texture:      wgpu.Texture,
	scene_color_view:         wgpu.TextureView, // sRGB view: render into it, filtered reads decode to linear
	scene_color_encoded_view: wgpu.TextureView, // RGBA8Unorm view of the same bytes: FSR reads encoded values
	scene_depth_texture:      wgpu.Texture,
	scene_depth_view:         wgpu.TextureView,
	upscaled_texture:         wgpu.Texture,     // EASU output at window size, read by RCAS
	upscaled_view:            wgpu.TextureView,
	post_layout:              wgpu.BindGroupLayout,
	post_buffer:              wgpu.Buffer,
	easu_group:               wgpu.BindGroup,
	rcas_group:               wgpu.BindGroup,
	resample_group:           wgpu.BindGroup,
	easu_pipeline:            wgpu.RenderPipeline,
	rcas_pipeline:            wgpu.RenderPipeline,
	resample_pipeline:        wgpu.RenderPipeline,
	render_size:              [2]i32, // scene resolution used for the last frame
	render_scale:             f32,    // render_size / viewport size for the last frame

	// MSAA (post.odin): multisampled color and depth the scene renders into when enabled, then
	// averaged into scene_color by the resolve pass. Allocated only while MSAA is on, grown as
	// the render size needs, and released when the window resizes or MSAA changes.
	msaa_sample_count:        u32, // 1 = off
	msaa_target_size:         [2]i32,
	msaa_color_texture:       wgpu.Texture,
	msaa_color_view:          wgpu.TextureView,
	msaa_depth_texture:       wgpu.Texture,
	msaa_depth_view:          wgpu.TextureView,
	resolve_layout:           wgpu.BindGroupLayout,
	resolve_group:            wgpu.BindGroup,
	resolve_pipeline:         wgpu.RenderPipeline,

	// GPU timing (post.odin): two timestamps per frame, read back a few frames later.
	timestamps_supported:     bool,
	timestamp_period:         f32,    // nanoseconds per timestamp tick
	timestamp_query_set:      wgpu.QuerySet,
	timestamp_resolve_buffer: wgpu.Buffer,
	timestamp_readbacks:      [TIMESTAMP_READBACK_COUNT]Timestamp_Readback,
	gpu_frame_milliseconds:   f32,    // most recent measurement; 0 until one arrives

	// Bindings and pipelines (pipelines.odin)
	frame_layout:      wgpu.BindGroupLayout,
	instance_layout:   wgpu.BindGroupLayout,
	frame_buffer:      wgpu.Buffer,
	instance_buffer:   wgpu.Buffer,
	line_buffer:       wgpu.Buffer,
	frame_group:       wgpu.BindGroup,
	instance_group:    wgpu.BindGroup,
	mesh_pipeline:     wgpu.RenderPipeline,
	line_pipeline:     wgpu.RenderPipeline,
	grid_pipeline:     wgpu.RenderPipeline,
	overlay_pipeline:  wgpu.RenderPipeline,

	// Overlay atlas: a single-channel texture the UI fills (glyphs) through set_overlay_atlas
	overlay_layout:    wgpu.BindGroupLayout,
	overlay_buffer:    wgpu.Buffer,
	overlay_sampler:   wgpu.Sampler,
	atlas_texture:     wgpu.Texture,
	atlas_view:        wgpu.TextureView,
	atlas_size:        [2]i32,
	overlay_group:     wgpu.BindGroup,

	// Resources and per-frame lists (this file)
	meshes:              [MAX_MESHES]Gpu_Mesh,
	draws:               [MAX_DRAWS]Draw,
	draw_count:          int,
	line_vertices:       [MAX_DEBUG_LINES * 2]Debug_Vertex,
	line_vertex_count:   int,
	dropped_lines:       int, // debug lines past capacity are dropped and counted, not fatal
	overlay_quads:       [MAX_OVERLAY_QUADS]Overlay_Quad,
	overlay_quad_count:  int,
	overlay_batches:     [MAX_OVERLAY_BATCHES]Overlay_Batch,
	overlay_batch_count: int,
	dropped_overlay:     int, // overlay quads or batches past capacity
}

// Uploads a triangle mesh. `positions` and `normals` are parallel arrays (one entry per vertex)
// and stay separate on the GPU too: two vertex buffers, struct-of-arrays.
create_mesh :: proc(renderer: ^Renderer, positions, normals: [][3]f32, indices: []u32) -> Mesh_Handle {
	assert(len(positions) > 0 && len(positions) == len(normals))
	assert(len(indices) > 0 && len(indices) % 3 == 0)

	// Linear search for a free slot; fine at this capacity. Slot 0 stays unused.
	for slot_index in 1 ..< MAX_MESHES {
		slot := &renderer.meshes[slot_index]
		if slot.alive {
			continue
		}
		slot.generation += 1
		slot.alive = true
		slot.index_count = u32(len(indices))
		slot.position_buffer = create_buffer_with_data(renderer, "mesh positions", {.Vertex}, slice.to_bytes(positions))
		slot.normal_buffer = create_buffer_with_data(renderer, "mesh normals", {.Vertex}, slice.to_bytes(normals))
		slot.index_buffer = create_buffer_with_data(renderer, "mesh indices", {.Index}, slice.to_bytes(indices))
		return {index = u32(slot_index), generation = slot.generation}
	}
	fmt.eprintln("render: out of mesh slots, raise MAX_MESHES")
	return {}
}

destroy_mesh :: proc(renderer: ^Renderer, handle: Mesh_Handle) {
	mesh, found := get_mesh(renderer, handle)
	if !found {
		return
	}
	wgpu.BufferRelease(mesh.position_buffer)
	wgpu.BufferRelease(mesh.normal_buffer)
	wgpu.BufferRelease(mesh.index_buffer)
	mesh^ = {generation = mesh.generation} // keep the generation so old handles stay invalid
}

get_mesh :: proc(renderer: ^Renderer, handle: Mesh_Handle) -> (^Gpu_Mesh, bool) {
	if handle.index == 0 || handle.index >= MAX_MESHES {
		return nil, false
	}
	mesh := &renderer.meshes[handle.index]
	if !mesh.alive || mesh.generation != handle.generation {
		return nil, false
	}
	return mesh, true
}

// Starts a frame: clears the draw, line and overlay lists and resizes the surface if the
// window changed.
begin_frame :: proc(renderer: ^Renderer, window_size: [2]i32) {
	renderer.draw_count = 0
	renderer.line_vertex_count = 0
	renderer.dropped_lines = 0
	renderer.overlay_quad_count = 0
	renderer.overlay_batch_count = 0
	renderer.dropped_overlay = 0
	if window_size != renderer.surface_size && window_size.x > 0 && window_size.y > 0 {
		configure_surface(renderer, window_size)
	}
	overlay_clear_scissor(renderer)
}

draw_mesh :: proc(renderer: ^Renderer, mesh: Mesh_Handle, world: matrix[4, 4]f32, color: [4]f32) {
	assert(renderer.draw_count < MAX_DRAWS, "render: draw list full, raise MAX_DRAWS")
	if renderer.draw_count >= MAX_DRAWS {
		return // release builds (asserts disabled): drop the draw
	}
	// Sort key: mesh slot in the high 32 bits groups draws of the same mesh; submission order in
	// the low bits keeps the order deterministic. Later, pass and material get bits here too.
	sort_key := u64(mesh.index) << 32 | u64(renderer.draw_count)
	renderer.draws[renderer.draw_count] = {sort_key = sort_key, mesh = mesh, world = world, color = color}
	renderer.draw_count += 1
}

debug_line :: proc(renderer: ^Renderer, start, end: [3]f32, color: [4]f32) {
	if renderer.line_vertex_count + 2 > len(renderer.line_vertices) {
		renderer.dropped_lines += 1
		return
	}
	renderer.line_vertices[renderer.line_vertex_count + 0] = {start, color}
	renderer.line_vertices[renderer.line_vertex_count + 1] = {end, color}
	renderer.line_vertex_count += 2
}

// 2D overlay, immediate mode: everything added here is drawn on top of the 3D scene, in the
// order added, and forgotten at the next begin_frame.

overlay_rect :: proc(renderer: ^Renderer, rect_min, rect_max: [2]f32, color: [4]f32, corner_radius: f32 = 0, border_width: f32 = 0) {
	append_overlay_quad(renderer, {
		rect_min      = rect_min,
		rect_max      = rect_max,
		color         = color,
		corner_radius = corner_radius,
		border_width  = border_width,
		mode          = .Shape,
	})
}

// A glyph (or any image) sampled from the overlay atlas; the atlas supplies coverage, `color`
// supplies the color.
overlay_glyph :: proc(renderer: ^Renderer, rect_min, rect_max, uv_min, uv_max: [2]f32, color: [4]f32) {
	append_overlay_quad(renderer, {
		rect_min = rect_min,
		rect_max = rect_max,
		uv_min   = uv_min,
		uv_max   = uv_max,
		color    = color,
		mode     = .Glyph,
	})
}

// Clips the following overlay quads to a rectangle (pixels) until the next scissor change.
overlay_set_scissor :: proc(renderer: ^Renderer, scissor_min, scissor_max: [2]f32) {
	current := &renderer.overlay_batches[max(renderer.overlay_batch_count - 1, 0)]
	if renderer.overlay_batch_count > 0 && current.quad_count == 0 {
		// Nothing drawn with the current scissor yet: just change it.
		current.scissor_min, current.scissor_max = scissor_min, scissor_max
		return
	}
	if renderer.overlay_batch_count == MAX_OVERLAY_BATCHES {
		renderer.dropped_overlay += 1
		return
	}
	renderer.overlay_batches[renderer.overlay_batch_count] = {
		first_quad  = u32(renderer.overlay_quad_count),
		scissor_min = scissor_min,
		scissor_max = scissor_max,
	}
	renderer.overlay_batch_count += 1
}

overlay_clear_scissor :: proc(renderer: ^Renderer) {
	overlay_set_scissor(renderer, {0, 0}, {f32(renderer.surface_size.x), f32(renderer.surface_size.y)})
}

// Uploads the overlay atlas (single channel, one byte per pixel, rows tightly packed).
// Only the region between dirty_min and dirty_max (pixels, max exclusive) is sent, unless the
// atlas size changed, in which case the texture is recreated and filled completely.
set_overlay_atlas :: proc(renderer: ^Renderer, pixels: []u8, size: [2]i32, dirty_min, dirty_max: [2]i32) {
	assert(len(pixels) == int(size.x * size.y))
	upload_min, upload_max := dirty_min, dirty_max
	if size != renderer.atlas_size {
		create_atlas_texture(renderer, size)
		upload_min, upload_max = {0, 0}, size
	}
	for axis in 0 ..< 2 {
		upload_min[axis] = clamp(upload_min[axis], 0, size[axis])
		upload_max[axis] = clamp(upload_max[axis], 0, size[axis])
	}
	upload_size := upload_max - upload_min
	if upload_size.x <= 0 || upload_size.y <= 0 {
		return
	}
	first_byte := int(upload_min.y * size.x + upload_min.x)
	bytes_from_first := len(pixels) - first_byte
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = renderer.atlas_texture, origin = {u32(upload_min.x), u32(upload_min.y), 0}},
		&pixels[first_byte],
		uint(bytes_from_first),
		&{bytesPerRow = u32(size.x), rowsPerImage = u32(size.y)},
		&{u32(upload_size.x), u32(upload_size.y), 1},
	)
}

@(private)
append_overlay_quad :: proc(renderer: ^Renderer, quad: Overlay_Quad) {
	if renderer.overlay_quad_count == MAX_OVERLAY_QUADS || renderer.overlay_batch_count == 0 {
		renderer.dropped_overlay += 1
		return
	}
	renderer.overlay_quads[renderer.overlay_quad_count] = quad
	renderer.overlay_quad_count += 1
	renderer.overlay_batches[renderer.overlay_batch_count - 1].quad_count += 1
}

// Records and submits the frame in three passes:
//   1. scene:  meshes, debug lines and grid into scene_color, at render resolution
//   2. EASU:   (FSR, render scale < 1 only) edge-adaptive upscale into the upscaled texture
//   3. window: RCAS sharpening or bilinear resampling into the viewport, then the 2D overlay
// Below 100% the scene is upscaled; above 100% (supersampling) the same bilinear pass filters
// it down. With settings.capture, also returns the finished frame as RGBA8 rows (top row
// first, temp-allocated, size = surface_size), or nil if capture isn't possible.
end_frame :: proc(renderer: ^Renderer, camera: Camera, settings: Frame_Settings) -> (captured_pixels: []u8) {
	collect_gpu_timings(renderer)
	if settings.vsync != renderer.vsync {
		renderer.vsync = settings.vsync
		configure_surface(renderer, renderer.surface_size)
	}
	if renderer.surface_size.x <= 0 || renderer.surface_size.y <= 0 {
		return // minimized
	}

	surface_texture := wgpu.SurfaceGetCurrentTexture(renderer.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		// The swapchain no longer matches the window: rebuild it and skip this frame.
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		configure_surface(renderer, renderer.surface_size)
		return
	case .Occluded:
		return
	case .Error:
		fmt.eprintln("render: failed to get the surface texture")
		return
	}
	defer wgpu.TextureRelease(surface_texture.texture)
	target_view := wgpu.TextureCreateView(surface_texture.texture, nil)
	defer wgpu.TextureViewRelease(target_view)

	// Sort so draws of the same mesh are adjacent.
	draws := renderer.draws[:renderer.draw_count]
	slice.sort_by_key(draws, proc(draw: Draw) -> u64 {return draw.sort_key})

	// Upload per-frame data: camera, one instance record per draw, debug lines, overlay quads.
	surface_size := [2]f32{f32(renderer.surface_size.x), f32(renderer.surface_size.y)}
	frame_uniforms := Frame_Uniforms{
		view_projection = camera.projection * camera.view,
		camera_position = camera.position,
		gamma_correct   = 1 if renderer.gamma_correct else 0,
		light_direction = linalg.normalize([3]f32{-0.4, -1, -0.3}),
		viewport_size   = surface_size,
	}
	wgpu.QueueWriteBuffer(renderer.queue, renderer.frame_buffer, 0, &frame_uniforms, size_of(frame_uniforms))

	if len(draws) > 0 {
		instances := make([]Instance_Data, len(draws), context.temp_allocator)
		for draw, draw_index in draws {
			instances[draw_index] = {
				world         = draw.world,
				normal_matrix = linalg.transpose(linalg.inverse(draw.world)),
				color         = draw.color,
			}
		}
		instance_bytes := uint(len(instances) * size_of(Instance_Data))
		wgpu.QueueWriteBuffer(renderer.queue, renderer.instance_buffer, 0, raw_data(instances), instance_bytes)
	}
	if renderer.line_vertex_count > 0 {
		line_bytes := uint(renderer.line_vertex_count * size_of(Debug_Vertex))
		wgpu.QueueWriteBuffer(renderer.queue, renderer.line_buffer, 0, &renderer.line_vertices[0], line_bytes)
	}
	if renderer.overlay_quad_count > 0 {
		overlay_bytes := uint(renderer.overlay_quad_count * size_of(Overlay_Quad))
		wgpu.QueueWriteBuffer(renderer.queue, renderer.overlay_buffer, 0, &renderer.overlay_quads[0], overlay_bytes)
	}

	// The viewport: where in the window the scene appears, snapped to whole pixels so the post
	// passes map window pixels to scene pixels exactly.
	viewport_min, viewport_max := camera.viewport_min, camera.viewport_max
	if viewport_max == {} {
		viewport_max = surface_size
	}
	viewport_min = linalg.floor(linalg.clamp(viewport_min, [2]f32{0, 0}, surface_size))
	viewport_max = linalg.floor(linalg.clamp(viewport_max, viewport_min, surface_size))
	viewport_size := viewport_max - viewport_min
	scene_visible := viewport_size.x >= 1 && viewport_size.y >= 1

	// Render resolution: the viewport times the render scale, within the allocated targets.
	render_scale := clamp(settings.render_scale if settings.render_scale > 0 else 1, MIN_RENDER_SCALE, MAX_RENDER_SCALE)
	render_size := [2]i32{
		clamp(i32(math.round(viewport_size.x * render_scale)), 1, renderer.scene_target_size.x),
		clamp(i32(math.round(viewport_size.y * render_scale)), 1, renderer.scene_target_size.y),
	}
	renderer.render_size = render_size if scene_visible else {}
	renderer.render_scale = render_scale
	upscaling := f32(render_size.x) < viewport_size.x || f32(render_size.y) < viewport_size.y
	use_fsr := settings.upscaler == .Fsr && upscaling && renderer.easu_pipeline != nil && renderer.rcas_pipeline != nil

	// MSAA: changing the sample count rebuilds the scene pipelines (their sample count is part of
	// the pipeline) and drops the old multisampled targets.
	msaa_samples: u32 = 4 if settings.msaa_samples == 4 else 1
	if msaa_samples != renderer.msaa_sample_count {
		renderer.msaa_sample_count = msaa_samples
		release_msaa_targets(renderer)
		if !create_pipelines(renderer) {
			fmt.eprintln("render: rebuilding pipelines for the new MSAA setting failed")
		}
	}
	use_msaa := renderer.msaa_sample_count > 1 && scene_visible && renderer.resolve_pipeline != nil
	if use_msaa {
		ensure_msaa_targets(renderer, render_size)
	}

	scene_target_size := [2]f32{f32(renderer.scene_target_size.x), f32(renderer.scene_target_size.y)}
	render_size_float := [2]f32{f32(render_size.x), f32(render_size.y)}
	post_uniforms := Post_Uniforms{
		easu_constants  = easu_constants(render_size_float, scene_target_size, viewport_size),
		output_offset   = viewport_min,
		output_size     = viewport_size,
		source_uv_scale = render_size_float / scene_target_size,
		rcas_sharpness  = math.pow(2, -max(settings.sharpness_stops, 0)), // stops to a linear amount
		surface_is_srgb = 0 if renderer.gamma_correct else 1,
	}
	wgpu.QueueWriteBuffer(renderer.queue, renderer.post_buffer, 0, &post_uniforms, size_of(post_uniforms))

	encoder := wgpu.DeviceCreateCommandEncoder(renderer.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	// GPU timing: a timestamp at the start of the first pass and one at the end of the last,
	// when a readback buffer is free to receive them.
	timing_slot := -1
	if renderer.timestamps_supported {
		for readback, readback_index in renderer.timestamp_readbacks {
			if readback.state == .Free {
				timing_slot = readback_index
				break
			}
		}
	}
	timing_this_frame := timing_slot >= 0

	// --- Pass 1: the scene, at render resolution, into the top-left of scene_color (or of the
	// multisampled targets, resolved into scene_color right after).
	if scene_visible {
		scene_timestamps := wgpu.PassTimestampWrites{
			querySet                  = renderer.timestamp_query_set,
			beginningOfPassWriteIndex = 0,
			endOfPassWriteIndex       = wgpu.QUERY_SET_INDEX_UNDEFINED,
		}
		clear_color := settings.clear_color // linear; the sRGB target encodes it
		scene_color_target := renderer.msaa_color_view if use_msaa else renderer.scene_color_view
		scene_depth_target := renderer.msaa_depth_view if use_msaa else renderer.scene_depth_view
		scene_pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
			colorAttachmentCount   = 1,
			colorAttachments       = &wgpu.RenderPassColorAttachment{
				view       = scene_color_target,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				loadOp     = .Clear,
				storeOp    = .Store,
				clearValue = {f64(clear_color.r), f64(clear_color.g), f64(clear_color.b), f64(clear_color.a)},
			},
			// Depth clears to 0 because depth is reversed (near = 1, far = 0).
			depthStencilAttachment = &wgpu.RenderPassDepthStencilAttachment{
				view            = scene_depth_target,
				depthLoadOp     = .Clear,
				depthStoreOp    = .Discard,
				depthClearValue = 0,
			},
			timestampWrites        = &scene_timestamps if timing_this_frame else nil,
		})
		wgpu.RenderPassEncoderSetViewport(scene_pass, 0, 0, render_size_float.x, render_size_float.y, 0, 1)
		wgpu.RenderPassEncoderSetScissorRect(scene_pass, 0, 0, u32(render_size.x), u32(render_size.y))

		if renderer.mesh_pipeline != nil && len(draws) > 0 {
			wgpu.RenderPassEncoderSetPipeline(scene_pass, renderer.mesh_pipeline)
			wgpu.RenderPassEncoderSetBindGroup(scene_pass, 0, renderer.frame_group)
			wgpu.RenderPassEncoderSetBindGroup(scene_pass, 1, renderer.instance_group)
			for run_start := 0; run_start < len(draws); {
				// A run of draws using the same mesh becomes one instanced draw. Instance i of the
				// run reads instance record run_start + i, because instance_index counts from
				// firstInstance.
				run_end := run_start + 1
				for run_end < len(draws) && draws[run_end].mesh == draws[run_start].mesh {
					run_end += 1
				}
				if mesh, found := get_mesh(renderer, draws[run_start].mesh); found {
					wgpu.RenderPassEncoderSetVertexBuffer(scene_pass, 0, mesh.position_buffer, 0, wgpu.WHOLE_SIZE)
					wgpu.RenderPassEncoderSetVertexBuffer(scene_pass, 1, mesh.normal_buffer, 0, wgpu.WHOLE_SIZE)
					wgpu.RenderPassEncoderSetIndexBuffer(scene_pass, mesh.index_buffer, .Uint32, 0, wgpu.WHOLE_SIZE)
					wgpu.RenderPassEncoderDrawIndexed(
						scene_pass,
						indexCount = mesh.index_count,
						instanceCount = u32(run_end - run_start),
						firstIndex = 0,
						baseVertex = 0,
						firstInstance = u32(run_start),
					)
				}
				run_start = run_end
			}
		}

		if renderer.line_pipeline != nil && renderer.line_vertex_count > 0 {
			line_bytes := u64(renderer.line_vertex_count * size_of(Debug_Vertex))
			wgpu.RenderPassEncoderSetPipeline(scene_pass, renderer.line_pipeline)
			wgpu.RenderPassEncoderSetBindGroup(scene_pass, 0, renderer.frame_group)
			wgpu.RenderPassEncoderSetVertexBuffer(scene_pass, 0, renderer.line_buffer, 0, line_bytes)
			wgpu.RenderPassEncoderDraw(scene_pass, vertexCount = u32(renderer.line_vertex_count), instanceCount = 1, firstVertex = 0, firstInstance = 0)
		}

		// The grid is transparent, so it goes last, depth-tested against everything opaque.
		if renderer.grid_pipeline != nil && settings.show_grid {
			wgpu.RenderPassEncoderSetPipeline(scene_pass, renderer.grid_pipeline)
			wgpu.RenderPassEncoderSetBindGroup(scene_pass, 0, renderer.frame_group)
			wgpu.RenderPassEncoderDraw(scene_pass, vertexCount = 6, instanceCount = 1, firstVertex = 0, firstInstance = 0)
		}

		wgpu.RenderPassEncoderEnd(scene_pass)
		wgpu.RenderPassEncoderRelease(scene_pass)
	}

	// --- Pass 1b: MSAA resolve, averaging the samples of the rendered area into scene_color.
	if use_msaa {
		resolve_pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
			colorAttachmentCount = 1,
			colorAttachments     = &wgpu.RenderPassColorAttachment{
				view       = renderer.scene_color_view,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				loadOp     = .Load, // only the rendered area is written; no need to clear the rest
				storeOp    = .Store,
			},
		})
		wgpu.RenderPassEncoderSetViewport(resolve_pass, 0, 0, render_size_float.x, render_size_float.y, 0, 1)
		wgpu.RenderPassEncoderSetPipeline(resolve_pass, renderer.resolve_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(resolve_pass, 0, renderer.resolve_group)
		wgpu.RenderPassEncoderDraw(resolve_pass, vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0)
		wgpu.RenderPassEncoderEnd(resolve_pass)
		wgpu.RenderPassEncoderRelease(resolve_pass)
	}

	// --- Pass 2: FSR EASU, upscaling the scene to viewport size.
	if scene_visible && use_fsr {
		easu_pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
			colorAttachmentCount = 1,
			colorAttachments     = &wgpu.RenderPassColorAttachment{
				view       = renderer.upscaled_view,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				loadOp     = .Clear,
				storeOp    = .Store,
			},
		})
		wgpu.RenderPassEncoderSetViewport(easu_pass, 0, 0, viewport_size.x, viewport_size.y, 0, 1)
		wgpu.RenderPassEncoderSetPipeline(easu_pass, renderer.easu_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(easu_pass, 0, renderer.easu_group)
		wgpu.RenderPassEncoderDraw(easu_pass, vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0)
		wgpu.RenderPassEncoderEnd(easu_pass)
		wgpu.RenderPassEncoderRelease(easu_pass)
	}

	// --- Pass 3: the window. The scene image goes into the viewport, then the overlay on top.
	window_clear := settings.clear_color
	if renderer.gamma_correct {
		for channel in 0 ..< 3 {
			window_clear[channel] = math.pow(window_clear[channel], 1 / 2.2)
		}
	}
	window_timestamps := wgpu.PassTimestampWrites{
		querySet                  = renderer.timestamp_query_set,
		beginningOfPassWriteIndex = wgpu.QUERY_SET_INDEX_UNDEFINED if scene_visible else 0,
		endOfPassWriteIndex       = 1,
	}
	pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
		colorAttachmentCount = 1,
		colorAttachments     = &wgpu.RenderPassColorAttachment{
			view       = target_view,
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = {f64(window_clear.r), f64(window_clear.g), f64(window_clear.b), f64(window_clear.a)},
		},
		timestampWrites      = &window_timestamps if timing_this_frame else nil,
	})

	if scene_visible {
		wgpu.RenderPassEncoderSetViewport(pass, viewport_min.x, viewport_min.y, viewport_size.x, viewport_size.y, 0, 1)
		wgpu.RenderPassEncoderSetScissorRect(pass, u32(viewport_min.x), u32(viewport_min.y), u32(viewport_size.x), u32(viewport_size.y))
		present_pipeline, present_group := renderer.resample_pipeline, renderer.resample_group
		if use_fsr {
			present_pipeline, present_group = renderer.rcas_pipeline, renderer.rcas_group
		}
		if present_pipeline != nil {
			wgpu.RenderPassEncoderSetPipeline(pass, present_pipeline)
			wgpu.RenderPassEncoderSetBindGroup(pass, 0, present_group)
			wgpu.RenderPassEncoderDraw(pass, vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0)
		}
	}

	// 2D overlay last: one instanced draw per scissor batch, six vertices per quad.
	if renderer.overlay_pipeline != nil && renderer.overlay_group != nil && renderer.overlay_quad_count > 0 {
		wgpu.RenderPassEncoderSetViewport(pass, 0, 0, surface_size.x, surface_size.y, 0, 1)
		wgpu.RenderPassEncoderSetPipeline(pass, renderer.overlay_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.frame_group)
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, renderer.overlay_group)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.overlay_buffer, 0, wgpu.WHOLE_SIZE)
		for batch in renderer.overlay_batches[:renderer.overlay_batch_count] {
			if batch.quad_count == 0 {
				continue
			}
			// Scissor rectangles must lie inside the render target.
			scissor_min := linalg.clamp(linalg.floor(batch.scissor_min), [2]f32{0, 0}, surface_size)
			scissor_max := linalg.clamp(linalg.ceil(batch.scissor_max), [2]f32{0, 0}, surface_size)
			scissor_size := scissor_max - scissor_min
			if scissor_size.x <= 0 || scissor_size.y <= 0 {
				continue
			}
			wgpu.RenderPassEncoderSetScissorRect(pass, u32(scissor_min.x), u32(scissor_min.y), u32(scissor_size.x), u32(scissor_size.y))
			wgpu.RenderPassEncoderDraw(pass, vertexCount = 6, instanceCount = batch.quad_count, firstVertex = 0, firstInstance = batch.first_quad)
		}
	}

	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	if timing_this_frame {
		wgpu.CommandEncoderResolveQuerySet(encoder, renderer.timestamp_query_set, 0, 2, renderer.timestamp_resolve_buffer, 0)
		wgpu.CommandEncoderCopyBufferToBuffer(encoder, renderer.timestamp_resolve_buffer, 0, renderer.timestamp_readbacks[timing_slot].buffer, 0, TIMESTAMP_BYTES)
	}

	// Frame capture: copy the finished image into a buffer the CPU can read.
	capture_buffer: wgpu.Buffer
	capture_bytes_per_row: u32
	if settings.capture && renderer.surface_copyable {
		// Rows in a texture-to-buffer copy must start on 256-byte boundaries.
		capture_bytes_per_row = (u32(renderer.surface_size.x) * 4 + 255) & ~u32(255)
		capture_buffer = wgpu.DeviceCreateBuffer(renderer.device, &{
			label = "frame capture",
			usage = {.MapRead, .CopyDst},
			size  = u64(capture_bytes_per_row) * u64(renderer.surface_size.y),
		})
		wgpu.CommandEncoderCopyTextureToBuffer(
			encoder,
			&{texture = surface_texture.texture},
			&{layout = {bytesPerRow = capture_bytes_per_row, rowsPerImage = u32(renderer.surface_size.y)}, buffer = capture_buffer},
			&{u32(renderer.surface_size.x), u32(renderer.surface_size.y), 1},
		)
	}

	command_buffer := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(command_buffer)
	wgpu.QueueSubmit(renderer.queue, {command_buffer})

	if timing_this_frame {
		start_timestamp_readback(renderer, timing_slot)
	}
	if capture_buffer != nil {
		captured_pixels = read_capture_buffer(renderer, capture_buffer, capture_bytes_per_row)
		wgpu.BufferRelease(capture_buffer)
	} else if settings.capture {
		fmt.eprintln("render: this surface doesn't allow copying, so frames can't be captured")
	}
	wgpu.SurfacePresent(renderer.surface)
	return
}

// Waits for the GPU, maps the capture buffer and converts it to tightly packed RGBA8.
@(private)
read_capture_buffer :: proc(renderer: ^Renderer, buffer: wgpu.Buffer, bytes_per_row: u32) -> []u8 {
	Map_Result :: struct {
		done:    bool,
		success: bool,
	}
	map_result: Map_Result
	on_mapped :: proc "c" (status: wgpu.MapAsyncStatus, message: string, user_data, user_data_2: rawptr) {
		result := (^Map_Result)(user_data)
		result.done = true
		result.success = status == .Success
	}
	buffer_size := uint(bytes_per_row) * uint(renderer.surface_size.y)
	wgpu.BufferMapAsync(buffer, {.Read}, 0, buffer_size, {mode = .AllowProcessEvents, callback = on_mapped, userdata1 = &map_result})
	for !map_result.done {
		wgpu.DevicePoll(renderer.device, true)
		wgpu.InstanceProcessEvents(renderer.instance)
	}
	if !map_result.success {
		fmt.eprintln("render: mapping the frame capture failed")
		return nil
	}
	defer wgpu.BufferUnmap(buffer)

	mapped := wgpu.BufferGetConstMappedRange(buffer, 0, buffer_size)
	width, height := int(renderer.surface_size.x), int(renderer.surface_size.y)
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	swap_red_and_blue := renderer.surface_format == .BGRA8Unorm || renderer.surface_format == .BGRA8UnormSrgb
	for row in 0 ..< height {
		source_row := mapped[row * int(bytes_per_row):]
		destination_row := pixels[row * width * 4:]
		for column in 0 ..< width {
			source := source_row[column * 4:]
			destination := destination_row[column * 4:]
			destination[0] = source[2] if swap_red_and_blue else source[0]
			destination[1] = source[1]
			destination[2] = source[0] if swap_red_and_blue else source[2]
			destination[3] = 255
		}
	}
	return pixels
}

@(private)
create_buffer_with_data :: proc(renderer: ^Renderer, label: string, usage: wgpu.BufferUsageFlags, data: []byte) -> wgpu.Buffer {
	// Buffer writes must be a multiple of 4 bytes; every vertex and index type here already is.
	assert(len(data) % 4 == 0)
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &{label = label, usage = usage + {.CopyDst}, size = u64(len(data))})
	wgpu.QueueWriteBuffer(renderer.queue, buffer, 0, raw_data(data), uint(len(data)))
	return buffer
}
