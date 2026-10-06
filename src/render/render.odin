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

MAX_MESHES      :: 1024
MAX_DRAWS       :: 16 * 1024
MAX_DEBUG_LINES :: 16 * 1024

// Slot index into Renderer.meshes plus the slot's generation when the handle was made. A handle
// whose generation no longer matches refers to a destroyed mesh and is ignored. Index 0 is never
// used, so the zero value means "no mesh".
Mesh_Handle :: struct {
	index:      u32,
	generation: u32,
}

Camera :: struct {
	view:       matrix[4, 4]f32,
	projection: matrix[4, 4]f32,
	position:   [3]f32,
}

Frame_Settings :: struct {
	clear_color: [4]f32, // linear
	show_grid:   bool,
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
}
#assert(size_of(Frame_Uniforms) == 96)

Instance_Data :: struct {
	world:         matrix[4, 4]f32,
	normal_matrix: matrix[4, 4]f32,
	color:         [4]f32,
}
#assert(size_of(Instance_Data) == 144)

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
	gamma_correct:     bool, // surface isn't sRGB, so shaders encode output themselves
	surface_size:      [2]i32,
	depth_texture:     wgpu.Texture,
	depth_view:        wgpu.TextureView,

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

	// Resources and per-frame lists (this file)
	meshes:            [MAX_MESHES]Gpu_Mesh,
	draws:             [MAX_DRAWS]Draw,
	draw_count:        int,
	line_vertices:     [MAX_DEBUG_LINES * 2]Debug_Vertex,
	line_vertex_count: int,
	dropped_lines:     int, // debug lines past capacity are dropped and counted, not fatal
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

// Starts a frame: clears the draw and line lists and resizes the surface if the window changed.
begin_frame :: proc(renderer: ^Renderer, window_size: [2]i32) {
	renderer.draw_count = 0
	renderer.line_vertex_count = 0
	renderer.dropped_lines = 0
	if window_size != renderer.surface_size && window_size.x > 0 && window_size.y > 0 {
		configure_surface(renderer, window_size)
	}
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

// Sorts the draw list, uploads this frame's data and records one render pass:
// opaque meshes, then debug lines, then the transparent grid.
end_frame :: proc(renderer: ^Renderer, camera: Camera, settings: Frame_Settings) {
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

	// 1. Sort so draws of the same mesh are adjacent.
	draws := renderer.draws[:renderer.draw_count]
	slice.sort_by_key(draws, proc(draw: Draw) -> u64 {return draw.sort_key})

	// 2. Upload per-frame data: camera, one instance record per draw, debug lines.
	frame_uniforms := Frame_Uniforms{
		view_projection = camera.projection * camera.view,
		camera_position = camera.position,
		gamma_correct   = 1 if renderer.gamma_correct else 0,
		light_direction = linalg.normalize([3]f32{-0.4, -1, -0.3}),
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

	// 3. Record the pass. Depth clears to 0 because depth is reversed (near = 1, far = 0).
	clear_color := settings.clear_color
	if renderer.gamma_correct {
		for channel in 0 ..< 3 {
			clear_color[channel] = math.pow(clear_color[channel], 1 / 2.2)
		}
	}
	encoder := wgpu.DeviceCreateCommandEncoder(renderer.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)
	pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
		colorAttachmentCount   = 1,
		colorAttachments       = &wgpu.RenderPassColorAttachment{
			view       = target_view,
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = {f64(clear_color.r), f64(clear_color.g), f64(clear_color.b), f64(clear_color.a)},
		},
		depthStencilAttachment = &wgpu.RenderPassDepthStencilAttachment{
			view            = renderer.depth_view,
			depthLoadOp     = .Clear,
			depthStoreOp    = .Store,
			depthClearValue = 0,
		},
	})

	if renderer.mesh_pipeline != nil && len(draws) > 0 {
		wgpu.RenderPassEncoderSetPipeline(pass, renderer.mesh_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.frame_group)
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, renderer.instance_group)
		for run_start := 0; run_start < len(draws); {
			// A run of draws using the same mesh becomes one instanced draw. Instance i of the
			// run reads instance record run_start + i, because instance_index counts from
			// firstInstance.
			run_end := run_start + 1
			for run_end < len(draws) && draws[run_end].mesh == draws[run_start].mesh {
				run_end += 1
			}
			if mesh, found := get_mesh(renderer, draws[run_start].mesh); found {
				wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, mesh.position_buffer, 0, wgpu.WHOLE_SIZE)
				wgpu.RenderPassEncoderSetVertexBuffer(pass, 1, mesh.normal_buffer, 0, wgpu.WHOLE_SIZE)
				wgpu.RenderPassEncoderSetIndexBuffer(pass, mesh.index_buffer, .Uint32, 0, wgpu.WHOLE_SIZE)
				wgpu.RenderPassEncoderDrawIndexed(
					pass,
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
		wgpu.RenderPassEncoderSetPipeline(pass, renderer.line_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.frame_group)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.line_buffer, 0, line_bytes)
		wgpu.RenderPassEncoderDraw(pass, vertexCount = u32(renderer.line_vertex_count), instanceCount = 1, firstVertex = 0, firstInstance = 0)
	}

	// The grid is transparent, so it goes last, depth-tested against everything opaque.
	if renderer.grid_pipeline != nil && settings.show_grid {
		wgpu.RenderPassEncoderSetPipeline(pass, renderer.grid_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.frame_group)
		wgpu.RenderPassEncoderDraw(pass, vertexCount = 6, instanceCount = 1, firstVertex = 0, firstInstance = 0)
	}

	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	command_buffer := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(command_buffer)
	wgpu.QueueSubmit(renderer.queue, {command_buffer})
	wgpu.SurfacePresent(renderer.surface)
}

@(private)
create_buffer_with_data :: proc(renderer: ^Renderer, label: string, usage: wgpu.BufferUsageFlags, data: []byte) -> wgpu.Buffer {
	// Buffer writes must be a multiple of 4 bytes; every vertex and index type here already is.
	assert(len(data) % 4 == 0)
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &{label = label, usage = usage + {.CopyDst}, size = u64(len(data))})
	wgpu.QueueWriteBuffer(renderer.queue, buffer, 0, raw_data(data), uint(len(data)))
	return buffer
}
