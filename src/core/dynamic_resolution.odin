// Dynamic resolution controller: chooses the next render scale from measured GPU time.
//
// A frame's GPU cost is roughly proportional to the number of pixels shaded, which grows with
// scale squared. So the scale that would exactly meet the budget is
//     current_scale * sqrt(budget / measured)
// The controller aims a little under the budget (headroom for spikes), ignores small errors
// (a dead band, so the resolution doesn't pump back and forth), limits how far one adjustment
// may move, and snaps to steps so the render size doesn't change every adjustment.
package core

import "core:math"

DYNAMIC_RESOLUTION_HEADROOM  :: 0.9   // aim for 90% of the frame budget
DYNAMIC_RESOLUTION_DEAD_BAND :: 0.06  // within ±6% of the aim, leave the scale alone
DYNAMIC_RESOLUTION_MAX_DROP  :: 0.15  // one adjustment may lower the scale by up to 15%...
DYNAMIC_RESOLUTION_MAX_RISE  :: 0.05  // ...but raise it by only 5%: recover from spikes fast, climb back gently
DYNAMIC_RESOLUTION_STEP      :: 0.025 // scales snap to multiples of 2.5%

next_render_scale :: proc(current_scale, gpu_milliseconds, frame_budget_milliseconds, minimum_scale, maximum_scale: f32) -> f32 {
	assert(minimum_scale > 0 && minimum_scale <= maximum_scale)
	if gpu_milliseconds <= 0 || frame_budget_milliseconds <= 0 {
		return clamp(current_scale, minimum_scale, maximum_scale)
	}

	target_milliseconds := frame_budget_milliseconds * DYNAMIC_RESOLUTION_HEADROOM
	load_ratio := gpu_milliseconds / target_milliseconds
	if abs(load_ratio - 1) <= DYNAMIC_RESOLUTION_DEAD_BAND {
		return clamp(current_scale, minimum_scale, maximum_scale)
	}

	ideal_scale := current_scale * math.sqrt(1 / load_ratio)
	limited_scale := clamp(
		ideal_scale,
		current_scale * (1 - DYNAMIC_RESOLUTION_MAX_DROP),
		current_scale * (1 + DYNAMIC_RESOLUTION_MAX_RISE),
	)
	// Snap toward the direction of travel, so a small required change still moves one step.
	snapped_scale: f32
	if limited_scale < current_scale {
		snapped_scale = math.floor(limited_scale / DYNAMIC_RESOLUTION_STEP) * DYNAMIC_RESOLUTION_STEP
	} else {
		snapped_scale = math.ceil(limited_scale / DYNAMIC_RESOLUTION_STEP) * DYNAMIC_RESOLUTION_STEP
	}
	return clamp(snapped_scale, minimum_scale, maximum_scale)
}
