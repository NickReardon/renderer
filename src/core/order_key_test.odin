// Tests for order keys. Run with `build.bat test`.
package core

import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_order_key_after_exact_values :: proc(test: ^testing.T) {
	buffer: [ORDER_KEY_MAX_BYTES]u8
	after :: proc(buffer: []u8, key: string) -> string {
		next, ok := order_key_after(buffer, key)
		assert(ok)
		return next
	}
	// The first key, then counting up in base 62.
	testing.expect_value(test, after(buffer[:], ""), "a0")
	testing.expect_value(test, after(buffer[:], "a0"), "a1")
	testing.expect_value(test, after(buffer[:], "a9"), "aA")
	testing.expect_value(test, after(buffer[:], "aZ"), "aa")
	// The integer part runs out of digits: the head letter grows it by one digit.
	testing.expect_value(test, after(buffer[:], "az"), "b00")
	testing.expect_value(test, after(buffer[:], "b0z"), "b10")
	testing.expect_value(test, after(buffer[:], "bzz"), "c000")
	// Negative integers (upper-case heads, from keys made *before* "a0" by a later version)
	// count up towards "a0", losing a digit each time the head letter goes up.
	testing.expect_value(test, after(buffer[:], "Zy"), "Zz")
	testing.expect_value(test, after(buffer[:], "Zz"), "a0")
	testing.expect_value(test, after(buffer[:], "Yzz"), "Z0")
	// A fraction (from a key made *between* two others) is dropped: the next integer is after it.
	testing.expect_value(test, after(buffer[:], "a0V"), "a1")
	// The largest integer can't grow, so the key gets a fraction instead.
	largest := strings.concatenate({"z", strings.repeat("z", 26, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(test, after(buffer[:], largest), strings.concatenate({largest, "V"}, context.temp_allocator))
	free_all(context.temp_allocator)
}

@(test)
test_order_keys_sort_in_order :: proc(test: ^testing.T) {
	// Byte order is the intended order, so a plain string comparison sorts keys.
	keys := []string{"Yzz", "Z0", "Zz", "a0", "a0V", "a1", "aA", "az", "b00", "c000"}
	testing.expect(test, slice.is_sorted(keys), "keys sort by plain byte comparison")

	// Many keys in a row: each is valid and after the one before.
	buffer: [ORDER_KEY_MAX_BYTES]u8
	previous_bytes: [ORDER_KEY_MAX_BYTES]u8
	previous := ""
	for _ in 0 ..< 20_000 {
		next, ok := order_key_after(buffer[:], previous)
		testing.expect(test, ok, "a key fits")
		testing.expectf(test, order_key_is_valid(next), "%q is valid", next)
		testing.expectf(test, next > previous, "%q comes after %q", next, previous)
		previous = string(previous_bytes[:copy(previous_bytes[:], next)])
	}
}

@(test)
test_order_key_validity :: proc(test: ^testing.T) {
	valid := []string{"a0", "a1", "az", "b00", "Zz", "Yzz", "a0V", "a0zV"}
	for key in valid {
		testing.expectf(test, order_key_is_valid(key), "%q should be valid", key)
	}
	invalid := []string{
		"",    // "no key" is not a key
		"a",   // head says one digit follows, none does
		"b0",  // head says two digits follow
		"a00", // a fraction can't end in "0": nothing could sort between it and "a0"
		"a0!", // not a base-62 digit
		"0a",  // the head must be a letter
		"A" + "00000000000000000000000000", // the smallest integer: nothing could go before it
	}
	for key in invalid {
		testing.expectf(test, !order_key_is_valid(key), "%q should be invalid", key)
	}
	// Too long for the buffer the scene stores keys in, though otherwise well formed.
	fits := strings.concatenate({"a0", strings.repeat("V", ORDER_KEY_MAX_BYTES - 2, context.temp_allocator)}, context.temp_allocator)
	too_long := strings.concatenate({fits, "V"}, context.temp_allocator)
	testing.expect(test, order_key_is_valid(fits), "a key of exactly the limit is valid")
	testing.expect(test, !order_key_is_valid(too_long), "a key longer than the limit is invalid")
	free_all(context.temp_allocator)
}

@(test)
test_order_key_after_reports_a_full_buffer :: proc(test: ^testing.T) {
	small: [2]u8
	_, ok := order_key_after(small[:], "az") // "b00" needs 3 bytes
	testing.expect(test, !ok, "a key that doesn't fit is reported, not cut short")
	next, fits := order_key_after(small[:], "a0")
	testing.expect(test, fits && next == "a1", "a key that fits exactly is fine")
}
