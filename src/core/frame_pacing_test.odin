// Tests for frame pacing. Run with `build.bat test`.
package core

import "core:testing"

// A simple vsync model: each frame takes `work` milliseconds of CPU after the sleep, and the
// swapchain is ready again `interval` after the last one. The acquire waits for whatever is
// left; a frame that runs past that point misses the refresh and waits (almost) nothing.
@(private = "file")
simulated_acquire_wait :: proc(interval, work, delay: f32) -> f32 {
	return max(interval - work - delay, 0)
}

@(test)
test_frame_pacing_converges_to_the_margin :: proc(test: ^testing.T) {
	pacing: Frame_Pacing
	interval, work: f32 = 16.67, 1
	for _ in 0 ..< 600 { // 10 seconds at 60 Hz
		update_frame_pacing(&pacing, simulated_acquire_wait(interval, work, pacing.delay_milliseconds))
	}
	remaining_wait := simulated_acquire_wait(interval, work, pacing.delay_milliseconds)
	testing.expectf(test, abs(remaining_wait - FRAME_PACING_MARGIN_MILLISECONDS) < 0.25, "should settle with about the margin left to wait, got %.2f ms (delay %.2f ms)", remaining_wait, pacing.delay_milliseconds)
}

@(test)
test_frame_pacing_backs_off_when_late :: proc(test: ^testing.T) {
	pacing := Frame_Pacing{delay_milliseconds = 14}
	// The frame suddenly got slower: the acquire no longer waits at all.
	update_frame_pacing(&pacing, 0)
	testing.expectf(test, pacing.delay_milliseconds < 14, "a late frame should shorten the delay at once, got %.2f", pacing.delay_milliseconds)
	// With the slower work it settles again, still keeping the margin.
	interval, work: f32 = 16.67, 6
	for _ in 0 ..< 600 {
		update_frame_pacing(&pacing, simulated_acquire_wait(interval, work, pacing.delay_milliseconds))
	}
	remaining_wait := simulated_acquire_wait(interval, work, pacing.delay_milliseconds)
	testing.expectf(test, abs(remaining_wait - FRAME_PACING_MARGIN_MILLISECONDS) < 0.25, "should resettle after slowing down, got %.2f ms", remaining_wait)
}

@(test)
test_frame_pacing_never_negative :: proc(test: ^testing.T) {
	pacing: Frame_Pacing
	// No time to spare (the frame takes the whole interval): never a negative delay.
	for _ in 0 ..< 120 {
		update_frame_pacing(&pacing, 0.5)
	}
	testing.expect_value(test, pacing.delay_milliseconds, 0)
}
