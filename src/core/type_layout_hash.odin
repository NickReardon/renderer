// Type layout hashes: one number that changes whenever a type's memory layout changes.
//
// Hot reload hands the memory a game DLL allocated to the next build of the DLL. That's only
// safe if the new build reads the bytes the same way: same fields, in the same order, with the
// same types. Comparing sizes misses changes that keep the size (two fields swapped, an f32
// that became an i32), and the new code then silently misreads the old data. So the host
// compares this hash instead, and restarts the game when it differs.
//
// The hash walks Odin's runtime type information (what `type_info_of` returns) and feeds every
// detail that decides how bytes are read into FNV-1a: each type's kind, size and alignment;
// struct field names, offsets and types; array counts; enum member names and values; union
// variants and tag position; and the names of named types. It follows pointers, slices,
// dynamic arrays and maps into the types they point to, because memory reached through them was
// allocated by the old build too. Source locations and addresses are left out, so two builds of
// the same code hash the same.
//
// It errs towards "changed": renaming a field or a type also changes the hash, though the bytes
// are the same. A needless restart only loses editor state; a wrong reload corrupts it.
package core

import "base:runtime"
import "core:reflect"

// Hash of `type`'s full layout, including everything it points to. Uses the temp allocator for
// scratch (the set of types already visited).
type_layout_hash :: proc(type: typeid) -> u64 {
	hasher := Layout_Hasher {
		hash    = FNV_64_OFFSET_BASIS,
		visited = make(map[^runtime.Type_Info]int, allocator = context.temp_allocator),
	}
	hash_type_info(&hasher, type_info_of(type))
	delete(hasher.visited)
	return hasher.hash
}

// FNV-1a, 64-bit: for each byte, xor it in, then multiply by the prime. Simple, and good enough
// to tell layouts apart (this isn't defending against anyone crafting collisions).
// Fowler, Noll, Vo: http://www.isthe.com/chongo/tech/comp/fnv/
FNV_64_OFFSET_BASIS :: 0xcbf29ce484222325
FNV_64_PRIME :: 0x100000001b3

@(private = "file")
Layout_Hasher :: struct {
	hash:    u64,
	// Types already hashed, numbered in the order they were first reached. A type seen again
	// hashes as that number instead of its contents: that keeps recursive types (a node pointing
	// to its own type) from looping forever, and the numbering is the same in every build.
	visited: map[^runtime.Type_Info]int,
}

@(private = "file")
hash_bytes :: proc(hasher: ^Layout_Hasher, bytes: []byte) {
	for byte_value in bytes {
		hasher.hash = (hasher.hash ~ u64(byte_value)) * FNV_64_PRIME
	}
}

@(private = "file")
hash_int :: proc(hasher: ^Layout_Hasher, value: i64) {
	value := value
	hash_bytes(hasher, ([^]byte)(&value)[:size_of(value)])
}

// The length goes in first, so that ("ab", "c") and ("a", "bc") hash differently.
@(private = "file")
hash_string :: proc(hasher: ^Layout_Hasher, text: string) {
	hash_int(hasher, i64(len(text)))
	hash_bytes(hasher, transmute([]byte)text)
}

@(private = "file")
hash_type_info :: proc(hasher: ^Layout_Hasher, info: ^runtime.Type_Info) {
	if info == nil {
		hash_string(hasher, "nil") // rawptr's target, an absent union tag type
		return
	}
	if visit_number, seen := hasher.visited[info]; seen {
		hash_string(hasher, "seen")
		hash_int(hasher, i64(visit_number))
		return
	}
	hasher.visited[info] = len(hasher.visited)

	hash_int(hasher, i64(info.size))
	hash_int(hasher, i64(info.align))
	// Which variant of the Type_Info union this is (struct, array, pointer...): its tag, a small
	// number that is the same in every build (unlike the variant's typeid).
	hash_int(hasher, reflect.get_union_variant_raw_tag(info.variant))

	switch variant in info.variant {
	case runtime.Type_Info_Named:
		hash_string(hasher, variant.pkg)
		hash_string(hasher, variant.name)
		hash_type_info(hasher, variant.base)

	case runtime.Type_Info_Integer:
		hash_int(hasher, i64(variant.signed))
		hash_int(hasher, i64(variant.endianness))
	case runtime.Type_Info_Float:
		hash_int(hasher, i64(variant.endianness))
	case runtime.Type_Info_String:
		hash_int(hasher, i64(variant.is_cstring))
		hash_int(hasher, i64(variant.encoding))
	case runtime.Type_Info_Rune, runtime.Type_Info_Complex, runtime.Type_Info_Quaternion,
	     runtime.Type_Info_Boolean, runtime.Type_Info_Any, runtime.Type_Info_Type_Id:
		// Size and kind say everything.

	case runtime.Type_Info_Pointer:
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Multi_Pointer:
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Soa_Pointer:
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Procedure:
		// Procedure pointers must never be kept across a reload (they point into the old DLL),
		// so only their kind and size matter here.

	case runtime.Type_Info_Array:
		hash_int(hasher, i64(variant.count))
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Enumerated_Array:
		hash_int(hasher, i64(variant.count))
		hash_int(hasher, i64(variant.is_sparse))
		hash_type_info(hasher, variant.index)
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Dynamic_Array:
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Slice:
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		hash_int(hasher, i64(variant.capacity))
		hash_int(hasher, i64(variant.len_offset))
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Simd_Vector:
		hash_int(hasher, i64(variant.count))
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Matrix:
		hash_int(hasher, i64(variant.row_count))
		hash_int(hasher, i64(variant.column_count))
		hash_int(hasher, i64(variant.elem_stride))
		hash_int(hasher, i64(variant.layout))
		hash_type_info(hasher, variant.elem)
	case runtime.Type_Info_Map:
		hash_type_info(hasher, variant.key)
		hash_type_info(hasher, variant.value)

	case runtime.Type_Info_Struct:
		hash_int(hasher, i64(transmute(u8)variant.flags))
		hash_int(hasher, i64(variant.soa_kind))
		hash_int(hasher, i64(variant.soa_len))
		hash_int(hasher, i64(variant.field_count))
		for field_index in 0 ..< int(variant.field_count) {
			hash_string(hasher, variant.names[field_index])
			hash_int(hasher, i64(variant.offsets[field_index]))
			hash_type_info(hasher, variant.types[field_index])
		}
		if variant.soa_kind != .None {
			hash_type_info(hasher, variant.soa_base_type)
		}
	case runtime.Type_Info_Union:
		// The tag stores the variant's position in this list, so the order matters.
		hash_int(hasher, i64(variant.tag_offset))
		hash_int(hasher, i64(variant.no_nil))
		hash_int(hasher, i64(variant.shared_nil))
		hash_type_info(hasher, variant.tag_type)
		hash_int(hasher, i64(len(variant.variants)))
		for variant_info in variant.variants {
			hash_type_info(hasher, variant_info)
		}
	case runtime.Type_Info_Enum:
		hash_type_info(hasher, variant.base)
		hash_int(hasher, i64(len(variant.names)))
		for member_index in 0 ..< len(variant.names) {
			hash_string(hasher, variant.names[member_index])
			hash_int(hasher, i64(variant.values[member_index]))
		}
	case runtime.Type_Info_Bit_Set:
		hash_int(hasher, variant.lower)
		hash_int(hasher, variant.upper)
		hash_type_info(hasher, variant.elem)
		hash_type_info(hasher, variant.underlying)
	case runtime.Type_Info_Bit_Field:
		hash_type_info(hasher, variant.backing_type)
		hash_int(hasher, i64(variant.field_count))
		for field_index in 0 ..< variant.field_count {
			hash_string(hasher, variant.names[field_index])
			hash_int(hasher, i64(variant.bit_offsets[field_index]))
			hash_int(hasher, i64(variant.bit_sizes[field_index]))
			hash_type_info(hasher, variant.types[field_index])
		}
	case runtime.Type_Info_Parameters:
		// Only appears inside procedure types, which aren't followed.
	}
}
