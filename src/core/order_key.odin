// Order keys: short strings whose byte order is the order things should appear in (the
// Hierarchy's entities, later anything the user reorders).
//
// Each item stores its own key, and plain string comparison sorts them. Moving an item means
// giving it a key between its new neighbours' keys, so nothing else changes: with one file per
// entity (#36), a move rewrites one file, not every file after it. This is fractional indexing
// as described by David Greenspan, and as Figma uses it (see REFERENCES.md).
//
// A key is a head letter, an integer part and an optional fraction, all in base 62 with the
// digits "0-9A-Za-z" (which sort correctly as ASCII):
//   - the head says how many integer digits follow: 'a' one, 'b' two, ... 'z' twenty-six, so
//     longer integers (bigger numbers) sort after shorter ones; 'Z' down to 'A' are negative
//     integers with one, two, ... twenty-six digits, for keys made before "a0";
//   - the fraction makes room between two integers ("a0V" sits between "a0" and "a1"). It never
//     ends in '0', so there is always room for another key between it and its neighbours.
//
// The first key is "a0". This file only makes keys *after* another key; keys *between* two
// keys come with drag-to-reorder in the Hierarchy.
package core

ORDER_KEY_DIGITS    :: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
ORDER_KEY_MAX_BYTES :: 32 // what the scene stores; the largest integer key is 27 bytes
FIRST_ORDER_KEY     :: "a0"

// The smallest integer, "A" followed by 26 zeros. Nothing could be placed before it, so it's
// not a valid key (Greenspan's rule).
SMALLEST_ORDER_KEY_INTEGER :: "A" + "00000000000000000000000000"

// The key right after `key` ("" means no key yet: the result is FIRST_ORDER_KEY), written into
// `buffer`. Returns false if the result doesn't fit in `buffer`. `key` must be valid.
order_key_after :: proc(buffer: []u8, key: string) -> (next: string, ok: bool) {
	if key == "" {
		if len(buffer) < len(FIRST_ORDER_KEY) {
			return "", false
		}
		return string(buffer[:copy(buffer, FIRST_ORDER_KEY)]), true
	}
	assert(order_key_is_valid(key), "order_key_after needs a valid key")

	integer_length := order_key_integer_length(key[0])
	integer := key[:integer_length]
	fraction := key[integer_length:]

	// Usually the next integer: "a5" -> "a6", "a0V" -> "a1" (the fraction is dropped, since
	// any bigger integer comes after every fraction of a smaller one).
	scratch: [ORDER_KEY_MAX_BYTES + 1]u8
	if incremented, incremented_ok := increment_order_key_integer(scratch[:], integer); incremented_ok {
		if len(buffer) < len(incremented) {
			return "", false
		}
		return string(buffer[:copy(buffer, incremented)]), true
	}

	// Only the largest integer ("z" and 26 'z's) can't grow; keep it and extend the fraction
	// past the existing one instead. Taking the digit halfway between the fraction's first
	// digit and the top ("V" after nothing) leaves room on both sides for later keys.
	length := 0
	for character in transmute([]u8)integer {
		if length >= len(buffer) {
			return "", false
		}
		buffer[length] = character
		length += 1
	}
	digits := ORDER_KEY_DIGITS
	fraction_rest := fraction
	for {
		first_digit := 0
		if len(fraction_rest) > 0 {
			first_digit = order_key_digit_value(fraction_rest[0])
		}
		if length >= len(buffer) {
			return "", false
		}
		if len(ORDER_KEY_DIGITS) - first_digit > 1 {
			// round(0.5 * (first_digit + 62)), as Greenspan's midpoint does
			buffer[length] = digits[(first_digit + len(digits) + 1) / 2]
			length += 1
			break
		}
		// The first digit is already the top digit ('z'): keep it and look one digit further.
		buffer[length] = digits[first_digit]
		length += 1
		fraction_rest = fraction_rest[1:]
	}
	return string(buffer[:length]), true
}

// Whether `key` is a well-formed key of at most ORDER_KEY_MAX_BYTES. Keys from files are checked
// with this before they're used.
order_key_is_valid :: proc(key: string) -> bool {
	if key == "" || len(key) > ORDER_KEY_MAX_BYTES {
		return false
	}
	head := key[0]
	if !(('a' <= head && head <= 'z') || ('A' <= head && head <= 'Z')) {
		return false
	}
	integer_length := order_key_integer_length(head)
	if len(key) < integer_length {
		return false
	}
	for character in transmute([]u8)key[1:] {
		if order_key_digit_value(character) < 0 {
			return false
		}
	}
	if key[:integer_length] == SMALLEST_ORDER_KEY_INTEGER {
		return false
	}
	fraction := key[integer_length:]
	if len(fraction) > 0 && fraction[len(fraction) - 1] == '0' {
		return false
	}
	return true
}

// Head letter and digits together: 'a' -> 2 ("a0"), 'z' -> 27; 'Z' -> 2, 'A' -> 27.
@(private = "file")
order_key_integer_length :: proc(head: u8) -> int {
	if 'a' <= head && head <= 'z' {
		return int(head - 'a') + 2
	}
	return int('Z' - head) + 2
}

// The digit's value 0..61, or -1 if it isn't a base-62 digit.
@(private = "file")
order_key_digit_value :: proc(character: u8) -> int {
	switch character {
	case '0' ..= '9': return int(character - '0')
	case 'A' ..= 'Z': return int(character - 'A') + 10
	case 'a' ..= 'z': return int(character - 'a') + 36
	}
	return -1
}

// integer + 1, written into `buffer`. Fails only for the largest integer. Greenspan's
// incrementInteger: add one to the last digit with carry; if every digit carried, the head
// letter moves up. A bigger head means one more digit for positive integers ("az" -> "b00") and
// one fewer for negative ones ("Yzz" -> "Z0"); after the largest negative ("Zz") comes "a0".
@(private = "file")
increment_order_key_integer :: proc(buffer: []u8, integer: string) -> (next: string, ok: bool) {
	assert(len(buffer) >= len(integer) + 1)
	digits := ORDER_KEY_DIGITS
	head := integer[0]
	digit_count := copy(buffer[1:], integer[1:])
	carry := true
	for digit_index := digit_count; carry && digit_index >= 1; digit_index -= 1 {
		value := order_key_digit_value(buffer[digit_index]) + 1
		if value == len(ORDER_KEY_DIGITS) {
			buffer[digit_index] = ORDER_KEY_DIGITS[0]
		} else {
			buffer[digit_index] = digits[value]
			carry = false
		}
	}
	if !carry {
		buffer[0] = head
		return string(buffer[:digit_count + 1]), true
	}
	switch head {
	case 'Z':
		return string(buffer[:copy(buffer, FIRST_ORDER_KEY)]), true
	case 'z':
		return "", false
	}
	new_head := head + 1
	buffer[0] = new_head
	if new_head > 'a' {
		buffer[digit_count + 1] = ORDER_KEY_DIGITS[0] // every digit is now '0'; add one more
		return string(buffer[:digit_count + 2]), true
	}
	return string(buffer[:digit_count]), true // one digit fewer
}
