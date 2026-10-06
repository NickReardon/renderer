// Post passes that turn the scene render target into the viewport image:
//
//   easu_fragment_main      FSR 1 EASU: edge-adaptive upscaling (render scale < 1)
//   rcas_fragment_main      FSR 1 RCAS: contrast-adaptive sharpening of the EASU result
//   resample_fragment_main  bilinear resampling: plain upscaling, 1:1 copy, or supersampling
//                           (render scale > 1, where bilinear between texels averages them)
//
// All draw one full-screen triangle into the current viewport.
//
// Color spaces: the scene is rendered into an sRGB texture. FSR expects perceptual
// (display-encoded) values, so EASU reads the texture through a non-sRGB view, which returns
// the stored encoded bytes; RCAS output is encoded too and is decoded to linear for the sRGB
// window surface. The bilinear path samples through the sRGB view, which decodes to linear
// before filtering, so averaging (supersampling) happens in linear light as it should.
//
// EASU and RCAS are ported from AMD FidelityFX Super Resolution 1.0 (ffx_fsr1.h, the 32-bit
// "F" path), https://github.com/GPUOpen-Effects/FidelityFX-FSR, under this license:
//
//   Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this
//   software and associated documentation files (the "Software"), to deal in the Software
//   without restriction, including without limitation the rights to use, copy, modify, merge,
//   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
//   to whom the Software is furnished to do so, subject to the following conditions:
//   The above copyright notice and this permission notice shall be included in all copies or
//   substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
//   FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//   DEALINGS IN THE SOFTWARE.

// Must match `Post_Uniforms` in render.odin.
struct Post_Uniforms {
	easu_constants_0: vec4f, // FsrEasuCon con0, as floats: output pixel -> input texel position
	// con1..con3 (gather positions) are unused: the taps are loaded per texel instead
	easu_constants_1: vec4f,
	easu_constants_2: vec4f,
	easu_constants_3: vec4f,
	output_offset:    vec2f, // top-left of the viewport in the window, pixels
	output_size:      vec2f, // viewport size, pixels
	source_uv_scale:  vec2f, // rendered size / scene texture size
	rcas_sharpness:   f32,   // linear amount, exp2(-stops); 1 = strongest
	surface_is_srgb:  f32,   // 1: write linear values, the surface encodes them
}

@group(0) @binding(0) var<uniform> post: Post_Uniforms;
@group(0) @binding(1) var source_texture: texture_2d<f32>;
@group(0) @binding(2) var source_sampler: sampler;

@vertex
fn fullscreen_vertex_main(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
	// One triangle that covers the whole viewport: (-1,-1), (3,-1), (-1,3).
	let corner = vec2f(f32((vertex_index << 1u) & 2u), f32(vertex_index & 2u));
	return vec4f(corner * 2.0 - 1.0, 0.0, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Fast approximations from AMD's ffx_a.h (APrxLoRcpF1, APrxMedRcpF1, APrxLoRsqF1). They
// subtract the float's bit pattern from a magic constant, which roughly negates the exponent.
fn approximate_reciprocal_low(value: f32) -> f32 {
	return bitcast<f32>(0x7ef07ebbu - bitcast<u32>(value));
}

fn approximate_reciprocal_medium(value: f32) -> f32 {
	let estimate = bitcast<f32>(0x7ef19fffu - bitcast<u32>(value));
	return estimate * (-estimate * value + 2.0);
}

fn approximate_reciprocal_square_root_low(value: f32) -> f32 {
	return bitcast<f32>(0x5f347d74u - (bitcast<u32>(value) >> 1u));
}

fn srgb_to_linear(encoded: vec3f) -> vec3f {
	let low = encoded / 12.92;
	let high = pow((encoded + 0.055) / 1.055, vec3f(2.4));
	return select(high, low, encoded <= vec3f(0.04045));
}

// Final output for the window: linear for an sRGB surface, otherwise approximately encoded.
fn output_from_linear(linear_color: vec3f) -> vec4f {
	if (post.surface_is_srgb > 0.5) {
		return vec4f(linear_color, 1.0);
	}
	return vec4f(pow(max(linear_color, vec3f(0.0)), vec3f(1.0 / 2.2)), 1.0);
}

fn output_from_encoded(encoded_color: vec3f) -> vec4f {
	if (post.surface_is_srgb > 0.5) {
		return vec4f(srgb_to_linear(encoded_color), 1.0);
	}
	return vec4f(encoded_color, 1.0);
}

// ---------------------------------------------------------------------------------------------
// EASU: Edge Adaptive Spatial Upsampling (FsrEasuF)
//
// For each output pixel, look at the 12 nearest input texels:
//      b c
//    e f g h
//    i j k l
//      n o
// estimate the local edge direction and strength from luma, then filter with a Lanczos-like
// kernel stretched along the edge. The result is clamped to the 2x2 neighbourhood (f g j k) so
// the kernel's negative lobes can't ring.

// One tap of the kernel (FsrEasuTapF). Returns the weighted color in xyz and the weight in w.
fn easu_tap(offset: vec2f, direction: vec2f, kernel_length: vec2f, lobe: f32, clip_point: f32, tap_color: vec3f) -> vec4f {
	// Rotate the offset into the edge's frame, then stretch it (anisotropy).
	var rotated = vec2f(
		offset.x * direction.x + offset.y * direction.y,
		offset.x * -direction.y + offset.y * direction.x,
	);
	rotated *= kernel_length;
	// Distance squared, limited to the window (corner taps can fall outside it).
	let distance_squared = min(dot(rotated, rotated), clip_point);
	// Approximation of lanczos2 without sin, rcp or sqrt:
	//   (25/16 * (2/5 * x^2 - 1)^2 - (25/16 - 1)) * (lobe * x^2 - 1)^2
	var base_weight = (2.0 / 5.0) * distance_squared - 1.0;
	var window_weight = lobe * distance_squared - 1.0;
	base_weight *= base_weight;
	window_weight *= window_weight;
	base_weight = (25.0 / 16.0) * base_weight - (25.0 / 16.0 - 1.0);
	let weight = base_weight * window_weight;
	return vec4f(tap_color * weight, weight);
}

// Edge direction and length from one of the four bilinear corners (FsrEasuSetF). The five
// lumas form a '+' around the centre tap: a above, b c d across, e below. Returns
// (direction x, direction y, length), already multiplied by this corner's bilinear weight.
fn easu_direction_and_length(weight: f32, luma_a: f32, luma_b: f32, luma_c: f32, luma_d: f32, luma_e: f32) -> vec3f {
	let difference_dc = luma_d - luma_c;
	let difference_cb = luma_c - luma_b;
	var length_x = approximate_reciprocal_low(max(abs(difference_dc), abs(difference_cb)));
	let direction_x = luma_d - luma_b;
	length_x = clamp(abs(direction_x) * length_x, 0.0, 1.0);
	length_x *= length_x;

	let difference_ec = luma_e - luma_c;
	let difference_ca = luma_c - luma_a;
	var length_y = approximate_reciprocal_low(max(abs(difference_ec), abs(difference_ca)));
	let direction_y = luma_e - luma_a;
	length_y = clamp(abs(direction_y) * length_y, 0.0, 1.0);
	length_y *= length_y;

	return vec3f(direction_x * weight, direction_y * weight, (length_x + length_y) * weight);
}

// One input texel, clamped to the region that was actually rendered this frame. (The texture is
// larger than that region under dynamic resolution, so the sampler's clamp-to-edge isn't
// enough: it would clamp to the texture's edge and read stale pixels.)
fn load_rendered_texel(texel: vec2i, last_rendered_texel: vec2i) -> vec3f {
	return textureLoad(source_texture, clamp(texel, vec2i(0), last_rendered_texel), 0).rgb;
}

// Approximate luma (times 2): blue/2 + red/2 + green.
fn easu_luma(color: vec3f) -> f32 {
	return color.b * 0.5 + (color.r * 0.5 + color.g);
}

fn fsr_easu(output_pixel: vec2f) -> vec3f {
	// Position of 'f' (the input texel up and left of this output pixel) and the fraction past it.
	var position = output_pixel * post.easu_constants_0.xy + post.easu_constants_0.zw;
	let base_texel = floor(position);
	position -= base_texel;

	// The 12 taps. AMD's version fetches them with four textureGather calls and relies on the
	// sampler clamping at the image edge; here each texel is loaded and clamped to the rendered
	// region instead, which matches that behaviour when the image is a sub-rectangle.
	let rendered_size = vec2i(round(post.source_uv_scale * vec2f(textureDimensions(source_texture))));
	let last_texel = rendered_size - vec2i(1);
	let texel_f = vec2i(base_texel);
	let color_b = load_rendered_texel(texel_f + vec2i(0, -1), last_texel);
	let color_c = load_rendered_texel(texel_f + vec2i(1, -1), last_texel);
	let color_e = load_rendered_texel(texel_f + vec2i(-1, 0), last_texel);
	let color_f = load_rendered_texel(texel_f, last_texel);
	let color_g = load_rendered_texel(texel_f + vec2i(1, 0), last_texel);
	let color_h = load_rendered_texel(texel_f + vec2i(2, 0), last_texel);
	let color_i = load_rendered_texel(texel_f + vec2i(-1, 1), last_texel);
	let color_j = load_rendered_texel(texel_f + vec2i(0, 1), last_texel);
	let color_k = load_rendered_texel(texel_f + vec2i(1, 1), last_texel);
	let color_l = load_rendered_texel(texel_f + vec2i(2, 1), last_texel);
	let color_n = load_rendered_texel(texel_f + vec2i(0, 2), last_texel);
	let color_o = load_rendered_texel(texel_f + vec2i(1, 2), last_texel);

	let luma_b = easu_luma(color_b);
	let luma_c = easu_luma(color_c);
	let luma_e = easu_luma(color_e);
	let luma_f = easu_luma(color_f);
	let luma_g = easu_luma(color_g);
	let luma_h = easu_luma(color_h);
	let luma_i = easu_luma(color_i);
	let luma_j = easu_luma(color_j);
	let luma_k = easu_luma(color_k);
	let luma_l = easu_luma(color_l);
	let luma_n = easu_luma(color_n);
	let luma_o = easu_luma(color_o);

	// Edge direction and length, bilinearly blended from the four texels around the sample.
	var direction_and_length = vec3f(0.0);
	direction_and_length += easu_direction_and_length((1.0 - position.x) * (1.0 - position.y), luma_b, luma_e, luma_f, luma_g, luma_j);
	direction_and_length += easu_direction_and_length(position.x * (1.0 - position.y), luma_c, luma_f, luma_g, luma_h, luma_k);
	direction_and_length += easu_direction_and_length((1.0 - position.x) * position.y, luma_f, luma_i, luma_j, luma_k, luma_n);
	direction_and_length += easu_direction_and_length(position.x * position.y, luma_g, luma_j, luma_k, luma_l, luma_o);
	var direction = direction_and_length.xy;
	var edge_length = direction_and_length.z;

	// Normalize the direction (approximately); near zero, fall back to horizontal.
	let direction_squared = direction * direction;
	var direction_length_squared = direction_squared.x + direction_squared.y;
	let direction_is_zero = direction_length_squared < (1.0 / 32768.0);
	var inverse_direction_length = approximate_reciprocal_square_root_low(direction_length_squared);
	inverse_direction_length = select(inverse_direction_length, 1.0, direction_is_zero);
	direction.x = select(direction.x, 1.0, direction_is_zero);
	direction *= inverse_direction_length;

	// Map length from {0..2} to {0..1} and shape it.
	edge_length = edge_length * 0.5;
	edge_length *= edge_length;
	// Stretch the kernel from 1 (axis-aligned) to sqrt(2) (diagonal).
	let stretch = dot(direction, direction) * approximate_reciprocal_low(max(abs(direction.x), abs(direction.y)));
	// Anisotropic length: x goes from 1 toward `stretch` on edges, y from 1 toward 0.5.
	let kernel_length = vec2f(1.0 + (stretch - 1.0) * edge_length, 1.0 - 0.5 * edge_length);
	// The window widens with edge strength, from sqrt(2) to slightly beyond 2.
	let lobe = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * edge_length;
	let clip_point = approximate_reciprocal_low(lobe);

	// Min and max of the four nearest texels (f g j k), used to remove ringing.
	let minimum_4 = min(min(color_f, color_g), min(color_j, color_k));
	let maximum_4 = max(max(color_f, color_g), max(color_j, color_k));

	var accumulated = vec4f(0.0);
	accumulated += easu_tap(vec2f(0.0, -1.0) - position, direction, kernel_length, lobe, clip_point, color_b);
	accumulated += easu_tap(vec2f(1.0, -1.0) - position, direction, kernel_length, lobe, clip_point, color_c);
	accumulated += easu_tap(vec2f(-1.0, 1.0) - position, direction, kernel_length, lobe, clip_point, color_i);
	accumulated += easu_tap(vec2f(0.0, 1.0) - position, direction, kernel_length, lobe, clip_point, color_j);
	accumulated += easu_tap(vec2f(0.0, 0.0) - position, direction, kernel_length, lobe, clip_point, color_f);
	accumulated += easu_tap(vec2f(-1.0, 0.0) - position, direction, kernel_length, lobe, clip_point, color_e);
	accumulated += easu_tap(vec2f(1.0, 1.0) - position, direction, kernel_length, lobe, clip_point, color_k);
	accumulated += easu_tap(vec2f(2.0, 1.0) - position, direction, kernel_length, lobe, clip_point, color_l);
	accumulated += easu_tap(vec2f(2.0, 0.0) - position, direction, kernel_length, lobe, clip_point, color_h);
	accumulated += easu_tap(vec2f(1.0, 0.0) - position, direction, kernel_length, lobe, clip_point, color_g);
	accumulated += easu_tap(vec2f(1.0, 2.0) - position, direction, kernel_length, lobe, clip_point, color_o);
	accumulated += easu_tap(vec2f(0.0, 2.0) - position, direction, kernel_length, lobe, clip_point, color_n);

	// Normalize and clamp to the 2x2 neighbourhood (de-ringing).
	return min(maximum_4, max(minimum_4, accumulated.xyz / accumulated.w));
}

@fragment
fn easu_fragment_main(@builtin(position) fragment_position: vec4f) -> @location(0) vec4f {
	// EASU writes into its own target with the viewport at the origin.
	return vec4f(fsr_easu(floor(fragment_position.xy)), 1.0);
}

// ---------------------------------------------------------------------------------------------
// RCAS: Robust Contrast Adaptive Sharpening (FsrRcasF)
//
// A 5-tap cross:      b
//                   d e f
//                     h
// output = (lobe * (b + d + f + h) + e) / (4 * lobe + 1), with the (negative) lobe chosen as
// large as possible without pushing any channel outside [0, 1], then scaled by the sharpness.

const RCAS_LIMIT: f32 = 0.25 - (1.0 / 16.0);

fn load_upscaled(pixel: vec2i) -> vec3f {
	let last_pixel = vec2i(post.output_size) - vec2i(1);
	return textureLoad(source_texture, clamp(pixel, vec2i(0), last_pixel), 0).rgb;
}

fn fsr_rcas(pixel: vec2i) -> vec3f {
	let color_b = load_upscaled(pixel + vec2i(0, -1));
	let color_d = load_upscaled(pixel + vec2i(-1, 0));
	let color_e = load_upscaled(pixel);
	let color_f = load_upscaled(pixel + vec2i(1, 0));
	let color_h = load_upscaled(pixel + vec2i(0, 1));

	// Min and max of the ring around the centre.
	let minimum_4 = min(min(color_b, color_d), min(color_f, color_h));
	let maximum_4 = max(max(color_b, color_d), max(color_f, color_h));

	// How far the lobe can go before the result would clip below 0 or above 1, per channel.
	// (AMD divides exactly; the max() only guards a division by zero in pure black areas.)
	let hit_minimum = min(minimum_4, color_e) / max(4.0 * maximum_4, vec3f(1e-5));
	let hit_maximum = (1.0 - max(maximum_4, color_e)) / (4.0 * minimum_4 - 4.0);
	let lobe_per_channel = max(-hit_minimum, hit_maximum);
	let lobe = max(-RCAS_LIMIT, min(max(lobe_per_channel.r, max(lobe_per_channel.g, lobe_per_channel.b)), 0.0)) * post.rcas_sharpness;

	let reciprocal = approximate_reciprocal_medium(4.0 * lobe + 1.0);
	return (lobe * (color_b + color_d + color_h + color_f) + color_e) * reciprocal;
}

@fragment
fn rcas_fragment_main(@builtin(position) fragment_position: vec4f) -> @location(0) vec4f {
	let pixel = vec2i(floor(fragment_position.xy - post.output_offset));
	return output_from_encoded(fsr_rcas(pixel));
}

// ---------------------------------------------------------------------------------------------
// Bilinear resampling: upscale without FSR, copy at 1:1, or downsample when supersampling.

@fragment
fn resample_fragment_main(@builtin(position) fragment_position: vec4f) -> @location(0) vec4f {
	let viewport_uv = (fragment_position.xy - post.output_offset) / post.output_size;
	// The scene only covers part of its texture; keep the filter from reaching past that part.
	let half_texel = 0.5 / vec2f(textureDimensions(source_texture));
	let source_uv = clamp(viewport_uv * post.source_uv_scale, half_texel, post.source_uv_scale - half_texel);
	let linear_color = textureSample(source_texture, source_sampler, source_uv).rgb;
	return output_from_linear(linear_color);
}
