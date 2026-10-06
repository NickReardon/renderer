// Primitive meshes: plane, UV sphere, cylinder (the cube is in mesh.odin). All are centred on
// the origin, Y up, with faces counter-clockwise seen from outside (checked by the tests).
//
// Around the Y axis, angle φ places a point at (sin φ, ·, cos φ): φ = 0 faces +Z (toward the
// viewer) and φ increases toward +X. With that convention, a quad listed as
// (upper φ₀, lower φ₀, lower φ₁, upper φ₁) faces outward.
package core

import "core:math"

// A flat square on the XZ plane facing +Y, split into `subdivisions` × `subdivisions` quads.
make_plane :: proc(size: f32, subdivisions: int, allocator := context.allocator) -> Mesh {
	assert(size > 0 && subdivisions >= 1)
	vertices_per_side := subdivisions + 1
	mesh := Mesh{
		positions    = make([dynamic][3]f32, 0, vertices_per_side * vertices_per_side, allocator),
		face_offsets = make([dynamic]u32, 0, subdivisions * subdivisions + 1, allocator),
		corner_verts = make([dynamic]u32, 0, subdivisions * subdivisions * 4, allocator),
	}
	half_size := size * 0.5
	for row in 0 ..< vertices_per_side {
		for column in 0 ..< vertices_per_side {
			x := -half_size + size * f32(column) / f32(subdivisions)
			z := -half_size + size * f32(row) / f32(subdivisions)
			append(&mesh.positions, [3]f32{x, 0, z})
		}
	}
	append(&mesh.face_offsets, 0)
	for row in 0 ..< subdivisions {
		for column in 0 ..< subdivisions {
			near_left := u32(row * vertices_per_side + column) // smaller z, smaller x
			near_right := near_left + 1
			far_left := near_left + u32(vertices_per_side)
			far_right := far_left + 1
			// Counter-clockwise seen from above (+Y).
			append(&mesh.corner_verts, far_left, far_right, near_right, near_left)
			append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
		}
	}
	return mesh
}

// A sphere made of `rings` latitude bands and `segments` longitude slices: triangles around the
// poles, quads in between.
make_uv_sphere :: proc(radius: f32, segments, rings: int, allocator := context.allocator) -> Mesh {
	assert(radius > 0 && segments >= 3 && rings >= 2)
	ring_vertex_count := (rings - 1) * segments
	mesh := Mesh{
		positions    = make([dynamic][3]f32, 0, ring_vertex_count + 2, allocator),
		face_offsets = make([dynamic]u32, 0, rings * segments + 1, allocator),
		corner_verts = make([dynamic]u32, 0, rings * segments * 4, allocator),
	}
	// Vertex 0 is the top pole, then rings from top to bottom, then the bottom pole.
	append(&mesh.positions, [3]f32{0, radius, 0})
	for ring in 1 ..< rings {
		polar_angle := math.PI * f32(ring) / f32(rings)
		ring_radius := radius * math.sin(polar_angle)
		height := radius * math.cos(polar_angle)
		for segment in 0 ..< segments {
			azimuth := 2 * math.PI * f32(segment) / f32(segments)
			append(&mesh.positions, [3]f32{ring_radius * math.sin(azimuth), height, ring_radius * math.cos(azimuth)})
		}
	}
	top_pole := u32(0)
	bottom_pole := u32(len(mesh.positions))
	append(&mesh.positions, [3]f32{0, -radius, 0})

	ring_vertex :: proc(ring, segment, segments: int) -> u32 {
		// `ring` counts from 1 (the first ring below the top pole).
		return u32(1 + (ring - 1) * segments + segment % segments)
	}

	append(&mesh.face_offsets, 0)
	for segment in 0 ..< segments {
		append(&mesh.corner_verts, top_pole, ring_vertex(1, segment, segments), ring_vertex(1, segment + 1, segments))
		append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
	}
	for ring in 1 ..< rings - 1 {
		for segment in 0 ..< segments {
			append(
				&mesh.corner_verts,
				ring_vertex(ring, segment, segments),
				ring_vertex(ring + 1, segment, segments),
				ring_vertex(ring + 1, segment + 1, segments),
				ring_vertex(ring, segment + 1, segments),
			)
			append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
		}
	}
	for segment in 0 ..< segments {
		append(&mesh.corner_verts, ring_vertex(rings - 1, segment, segments), bottom_pole, ring_vertex(rings - 1, segment + 1, segments))
		append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
	}
	return mesh
}

// A closed cylinder along Y: `segments` side quads and an n-gon cap at each end.
make_cylinder :: proc(radius, height: f32, segments: int, allocator := context.allocator) -> Mesh {
	assert(radius > 0 && height > 0 && segments >= 3)
	mesh := Mesh{
		positions    = make([dynamic][3]f32, 0, segments * 2, allocator),
		face_offsets = make([dynamic]u32, 0, segments + 3, allocator),
		corner_verts = make([dynamic]u32, 0, segments * 6, allocator),
	}
	half_height := height * 0.5
	// Top ring is vertices 0..segments-1, bottom ring segments..2*segments-1.
	for y in ([2]f32{half_height, -half_height}) {
		for segment in 0 ..< segments {
			azimuth := 2 * math.PI * f32(segment) / f32(segments)
			append(&mesh.positions, [3]f32{radius * math.sin(azimuth), y, radius * math.cos(azimuth)})
		}
	}
	top :: proc(segment, segments: int) -> u32 {return u32(segment % segments)}
	bottom :: proc(segment, segments: int) -> u32 {return u32(segments + segment % segments)}

	append(&mesh.face_offsets, 0)
	for segment in 0 ..< segments {
		append(&mesh.corner_verts, top(segment, segments), bottom(segment, segments), bottom(segment + 1, segments), top(segment + 1, segments))
		append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
	}
	// Top cap: increasing angle is counter-clockwise seen from above. Bottom cap: the reverse.
	for segment in 0 ..< segments {
		append(&mesh.corner_verts, top(segment, segments))
	}
	append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
	for segment := segments - 1; segment >= 0; segment -= 1 {
		append(&mesh.corner_verts, bottom(segment, segments))
	}
	append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
	return mesh
}
