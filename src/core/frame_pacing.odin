// Frame pacing for low input latency with vsync.
//
// With vsync, each frame blocks when it asks the swapchain for an image to draw into, until the
// display is ready for a new frame. That wait comes *after* the frame has read the mouse, so the
// input is already that much older when the frame starts drawing, about a whole refresh
// interval when the frame itself is cheap. Moving the wait before input fixes that: after
// presenting, sleep for most of the time the next acquire would block, then read input. The
// acquire then only waits a short safety margin.
//
// The right sleep depends on the display and on how long frames take, so it's found by
// feedback: watch how long the acquire still waits, and steer the sleep until the shortest wait
// over a window of frames equals the margin. A frame that waits almost nothing may have woken
// too late and missed the refresh, so that backs off at once. (The same idea as NVIDIA Reflex
// or Unreal's "frame delay"; see docs/DESIGN.md.)
package core

FRAME_PACING_MARGIN_MILLISECONDS :: 2    // the acquire wait to keep, for timing jitter
FRAME_PACING_WINDOW_FRAMES       :: 30   // frames between adjustments
FRAME_PACING_LATE_MILLISECONDS   :: 0.3  // a wait shorter than this may mean a missed refresh
FRAME_PACING_BACKOFF_MILLISECONDS :: 2   // how much shorter to sleep after a late frame
FRAME_PACING_GAIN                :: 0.5  // fraction of the error corrected per window

Frame_Pacing :: struct {
	delay_milliseconds:  f32, // sleep this long after presenting, before reading input
	window_minimum_wait: f32,
	window_frame_count:  int,
}

// Call once per presented frame with how long the swapchain acquire blocked.
update_frame_pacing :: proc(pacing: ^Frame_Pacing, acquire_wait_milliseconds: f32) {
	if acquire_wait_milliseconds < FRAME_PACING_LATE_MILLISECONDS && pacing.delay_milliseconds > 0 {
		pacing.delay_milliseconds = max(pacing.delay_milliseconds - FRAME_PACING_BACKOFF_MILLISECONDS, 0)
		pacing.window_frame_count = 0
		return
	}
	if pacing.window_frame_count == 0 || acquire_wait_milliseconds < pacing.window_minimum_wait {
		pacing.window_minimum_wait = acquire_wait_milliseconds
	}
	pacing.window_frame_count += 1
	if pacing.window_frame_count < FRAME_PACING_WINDOW_FRAMES {
		return
	}
	// Steer by the shortest wait in the window (the frame closest to missing), part of the way
	// each time so one noisy window can't push it over the edge.
	error := pacing.window_minimum_wait - FRAME_PACING_MARGIN_MILLISECONDS
	pacing.delay_milliseconds = max(pacing.delay_milliseconds + error * FRAME_PACING_GAIN, 0)
	pacing.window_frame_count = 0
}
