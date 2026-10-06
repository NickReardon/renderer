// GPU instance, adapter, device and window surface.
//
// WebGPU's setup is asynchronous: requesting an adapter or a device takes a callback. On the
// web the browser calls it later; natively, wgpu-native calls it from InstanceProcessEvents,
// so we pump events in a loop until the callback has run.
package render

import "base:runtime"
import "core:fmt"
import "vendor:wgpu"
import "engine:platform"

DEPTH_FORMAT :: wgpu.TextureFormat.Depth32Float

init :: proc(renderer: ^Renderer, window: platform.Native_Window, window_size: [2]i32) -> bool {
	// Only the modern backends (D3D12, Vulkan, Metal). Letting wgpu also probe its OpenGL backend
	// crashed instance creation on the development machine; see CLAUDE.md, "Known problems".
	instance_extras := wgpu.InstanceExtras{
		sType    = .InstanceExtras,
		backends = wgpu.InstanceBackendFlags_Primary,
	}
	renderer.instance = wgpu.CreateInstance(&{nextInChain = &instance_extras})
	if renderer.instance == nil {
		fmt.eprintln("render: failed to create a wgpu instance")
		return false
	}

	renderer.surface = create_surface(renderer.instance, window)
	if renderer.surface == nil {
		fmt.eprintln("render: failed to create a surface for this window")
		return false
	}

	// Adapter: a physical GPU (plus backend) that can present to our surface.
	Adapter_Request :: struct {
		done:    bool,
		adapter: wgpu.Adapter,
	}
	adapter_request: Adapter_Request
	on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, user_data, user_data_2: rawptr) {
		context = runtime.default_context()
		request := (^Adapter_Request)(user_data)
		request.done = true
		if status == .Success {
			request.adapter = adapter
		} else {
			fmt.eprintfln("render: adapter request failed (%v): %s", status, message)
		}
	}
	wgpu.InstanceRequestAdapter(
		renderer.instance,
		&{compatibleSurface = renderer.surface, powerPreference = .HighPerformance},
		{mode = .AllowProcessEvents, callback = on_adapter, userdata1 = &adapter_request},
	)
	for !adapter_request.done {
		wgpu.InstanceProcessEvents(renderer.instance)
	}
	renderer.adapter = adapter_request.adapter
	if renderer.adapter == nil {
		return false
	}
	if adapter_info, info_status := wgpu.AdapterGetInfo(renderer.adapter); info_status == .Success {
		fmt.printfln("render: %v on %s", adapter_info.backendType, adapter_info.device)
		wgpu.AdapterInfoFreeMembers(adapter_info)
	}

	// Device: our logical connection to the adapter. Validation errors that aren't caught by an
	// error scope arrive at on_uncaptured_error; this is where wgpu explains API misuse.
	Device_Request :: struct {
		done:   bool,
		device: wgpu.Device,
	}
	device_request: Device_Request
	on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, user_data, user_data_2: rawptr) {
		context = runtime.default_context()
		request := (^Device_Request)(user_data)
		request.done = true
		if status == .Success {
			request.device = device
		} else {
			fmt.eprintfln("render: device request failed (%v): %s", status, message)
		}
	}
	// Optional features: GPU timestamps, for measuring frame cost (dynamic resolution).
	renderer.timestamps_supported = bool(wgpu.AdapterHasFeature(renderer.adapter, .TimestampQuery))
	required_features := [1]wgpu.FeatureName{.TimestampQuery}
	wgpu.AdapterRequestDevice(
		renderer.adapter,
		&{
			label = "engine device",
			requiredFeatureCount = 1 if renderer.timestamps_supported else 0,
			requiredFeatures = &required_features[0],
			uncapturedErrorCallbackInfo = {callback = on_uncaptured_error},
			deviceLostCallbackInfo = {mode = .AllowProcessEvents, callback = on_device_lost},
		},
		{mode = .AllowProcessEvents, callback = on_device, userdata1 = &device_request},
	)
	for !device_request.done {
		wgpu.InstanceProcessEvents(renderer.instance)
	}
	renderer.device = device_request.device
	if renderer.device == nil {
		return false
	}
	renderer.queue = wgpu.DeviceGetQueue(renderer.device)
	if limits, limits_status := wgpu.DeviceGetLimits(renderer.device); limits_status == .Success {
		renderer.max_texture_size = i32(limits.maxTextureDimension2D)
	}

	// Prefer an sRGB surface format so the hardware converts our linear colors for display.
	// If none is offered (WebGPU in browsers, for example), shaders encode output themselves.
	capabilities, capabilities_status := wgpu.SurfaceGetCapabilities(renderer.surface, renderer.adapter)
	if capabilities_status != .Success || capabilities.formatCount == 0 {
		fmt.eprintln("render: the surface reports no supported formats")
		return false
	}
	supported_formats := capabilities.formats[:capabilities.formatCount]
	renderer.surface_format = supported_formats[0]
	for format in supported_formats {
		if format == .BGRA8UnormSrgb || format == .RGBA8UnormSrgb {
			renderer.surface_format = format
			break
		}
	}
	renderer.surface_copyable = .CopySrc in capabilities.usages
	for present_mode in capabilities.presentModes[:capabilities.presentModeCount] {
		renderer.immediate_present_supported ||= present_mode == .Immediate
		renderer.mailbox_present_supported ||= present_mode == .Mailbox
	}
	wgpu.SurfaceCapabilitiesFreeMembers(capabilities)
	renderer.gamma_correct = renderer.surface_format != .BGRA8UnormSrgb && renderer.surface_format != .RGBA8UnormSrgb
	renderer.vsync = true

	create_bindings(renderer)
	create_timestamp_resources(renderer)
	report_timestamp_support(renderer)
	configure_surface(renderer, window_size)
	return create_pipelines(renderer)
}

shutdown :: proc(renderer: ^Renderer) {
	for &mesh in renderer.meshes {
		if mesh.alive {
			wgpu.BufferRelease(mesh.position_buffer)
			wgpu.BufferRelease(mesh.normal_buffer)
			wgpu.BufferRelease(mesh.index_buffer)
		}
	}
	release_timestamp_resources(renderer)
	release_pipelines(renderer)
	release_scene_targets(renderer)
	release_post_bindings(renderer)
	release_atlas_texture(renderer)
	if renderer.overlay_sampler != nil do wgpu.SamplerRelease(renderer.overlay_sampler)
	if renderer.overlay_buffer != nil do wgpu.BufferRelease(renderer.overlay_buffer)
	if renderer.overlay_layout != nil do wgpu.BindGroupLayoutRelease(renderer.overlay_layout)
	if renderer.frame_group != nil do wgpu.BindGroupRelease(renderer.frame_group)
	if renderer.instance_group != nil do wgpu.BindGroupRelease(renderer.instance_group)
	if renderer.frame_buffer != nil do wgpu.BufferRelease(renderer.frame_buffer)
	if renderer.instance_buffer != nil do wgpu.BufferRelease(renderer.instance_buffer)
	if renderer.line_buffer != nil do wgpu.BufferRelease(renderer.line_buffer)
	if renderer.frame_layout != nil do wgpu.BindGroupLayoutRelease(renderer.frame_layout)
	if renderer.instance_layout != nil do wgpu.BindGroupLayoutRelease(renderer.instance_layout)
	if renderer.queue != nil do wgpu.QueueRelease(renderer.queue)
	if renderer.device != nil do wgpu.DeviceRelease(renderer.device)
	if renderer.adapter != nil do wgpu.AdapterRelease(renderer.adapter)
	if renderer.surface != nil do wgpu.SurfaceRelease(renderer.surface)
	if renderer.instance != nil do wgpu.InstanceRelease(renderer.instance)
	renderer^ = {}
}

// (Re)creates the swapchain and the scene render targets for a new window size, or applies a
// vsync change.
configure_surface :: proc(renderer: ^Renderer, size: [2]i32) {
	resized := size != renderer.surface_size || renderer.scene_color_texture == nil
	renderer.surface_size = size
	if size.x <= 0 || size.y <= 0 {
		return
	}

	// Vsync waits for the display (Fifo, always supported). Without it, prefer Immediate (no
	// waiting at all), then Mailbox (newest frame wins, no tearing).
	present_mode := wgpu.PresentMode.Fifo
	if !renderer.vsync {
		if renderer.immediate_present_supported {
			present_mode = .Immediate
		} else if renderer.mailbox_present_supported {
			present_mode = .Mailbox
		}
	}
	wgpu.SurfaceConfigure(renderer.surface, &{
		device      = renderer.device,
		format      = renderer.surface_format,
		usage       = {.RenderAttachment, .CopySrc} if renderer.surface_copyable else {.RenderAttachment},
		width       = u32(size.x),
		height      = u32(size.y),
		alphaMode   = .Auto,
		presentMode = present_mode,
	})

	if resized {
		create_scene_targets(renderer, size)
	}
}

@(private)
create_surface :: proc(instance: wgpu.Instance, window: platform.Native_Window) -> wgpu.Surface {
	switch native in window {
	case platform.Native_Window_Win32:
		return wgpu.InstanceCreateSurface(instance, &{
			nextInChain = &wgpu.SurfaceSourceWindowsHWND{
				chain = {sType = .SurfaceSourceWindowsHWND},
				hinstance = native.instance_handle,
				hwnd = native.window_handle,
			},
		})
	case platform.Native_Window_Metal:
		return wgpu.InstanceCreateSurface(instance, &{
			nextInChain = &wgpu.SurfaceSourceMetalLayer{
				chain = {sType = .SurfaceSourceMetalLayer},
				layer = native.metal_layer,
			},
		})
	case platform.Native_Window_Xlib:
		return wgpu.InstanceCreateSurface(instance, &{
			nextInChain = &wgpu.SurfaceSourceXlibWindow{
				chain = {sType = .SurfaceSourceXlibWindow},
				display = native.display,
				window = native.window,
			},
		})
	case platform.Native_Window_Wayland:
		return wgpu.InstanceCreateSurface(instance, &{
			nextInChain = &wgpu.SurfaceSourceWaylandSurface{
				chain = {sType = .SurfaceSourceWaylandSurface},
				display = native.display,
				surface = native.surface,
			},
		})
	}
	return nil
}

@(private)
on_uncaptured_error :: proc "c" (device: ^wgpu.Device, error_type: wgpu.ErrorType, message: string, user_data, user_data_2: rawptr) {
	context = runtime.default_context()
	fmt.eprintfln("render: wgpu %v error:\n%s", error_type, message)
}

@(private)
on_device_lost :: proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: string, user_data, user_data_2: rawptr) {
	context = runtime.default_context()
	if reason != .Destroyed && reason != .CallbackCancelled {
		fmt.eprintfln("render: device lost (%v): %s", reason, message)
	}
}
