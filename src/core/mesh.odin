// Polygon mesh with a flat, struct-of-arrays layout.
//
// Layout (following Blender's mesh refactor, see docs/REFERENCES.md):
//
//   positions:    one entry per vertex
//   face_offsets: one entry per face plus a final end marker. Face f's corners are
//                 corner_verts[face_offsets[f] : face_offsets[f + 1]]
//   corner_verts: for every face corner, the vertex it uses
//
// A "corner" is one use of a vertex by one face (Blender calls it a loop, Houdini a vertex).
// Per-corner data (UVs, later) lives in arrays parallel to corner_verts, which lets UV seams
// exist without splitting vertices.
//
// Invariants:
//   - len(face_offsets) == face_count + 1, face_offsets[0] == 0, offsets never decrease;
//   - face_offsets[face_count] == len(corner_verts);
//   - every face has at least 3 corners;
//   - corners are counter-clockwise seen from outside, so the right-hand rule gives an
//     outward normal.
//
// Adjacency (edges, vertex -> faces) is derived data: build it into arrays when an operation
// needs it, never store it here.
package core

import "core:math/linalg"

Mesh :: struct {
	positions:    [dynamic][3]f32,
	face_offsets: [dynamic]u32,
	corner_verts: [dynamic]u32,
}

mesh_destroy :: proc(mesh: ^Mesh) {
	delete(mesh.positions)
	delete(mesh.face_offsets)
	delete(mesh.corner_verts)
	mesh^ = {}
}

face_count :: proc(mesh: Mesh) -> int {
	return max(len(mesh.face_offsets) - 1, 0)
}

face_corners :: proc(mesh: Mesh, face_index: int) -> []u32 {
	assert(face_index >= 0 && face_index < face_count(mesh))
	return mesh.corner_verts[mesh.face_offsets[face_index]:mesh.face_offsets[face_index + 1]]
}

// Normal of a polygon by Newell's method: correct for any planar polygon (convex or not) and
// stable for slightly non-planar ones. Before normalizing, the sum has length 2 * area.
face_normal :: proc(mesh: Mesh, face_index: int) -> [3]f32 {
	corners := face_corners(mesh, face_index)
	normal_sum: [3]f32
	for corner_index in 0 ..< len(corners) {
		current := mesh.positions[corners[corner_index]]
		next := mesh.positions[corners[(corner_index + 1) % len(corners)]]
		normal_sum.x += (current.y - next.y) * (current.z + next.z)
		normal_sum.y += (current.z - next.z) * (current.x + next.x)
		normal_sum.z += (current.x - next.x) * (current.y + next.y)
	}
	return linalg.normalize0(normal_sum)
}

face_center :: proc(mesh: Mesh, face_index: int) -> [3]f32 {
	corners := face_corners(mesh, face_index)
	position_sum: [3]f32
	for vertex_index in corners {
		position_sum += mesh.positions[vertex_index]
	}
	return position_sum / f32(len(corners))
}

// Signed volume enclosed by a closed, consistently oriented mesh (divergence theorem: sum of
// signed tetrahedra from the origin to each triangle). Positive when faces point outward.
// Only meaningful for closed meshes; tests use it to check that operations keep a solid solid.
mesh_volume :: proc(mesh: Mesh) -> f32 {
	six_times_volume: f32
	for face_index in 0 ..< face_count(mesh) {
		corners := face_corners(mesh, face_index)
		fan_origin := mesh.positions[corners[0]]
		for corner_index in 1 ..< len(corners) - 1 {
			second := mesh.positions[corners[corner_index]]
			third := mesh.positions[corners[corner_index + 1]]
			six_times_volume += linalg.dot(fan_origin, linalg.cross(second, third))
		}
	}
	return six_times_volume / 6
}

// Axis-aligned cube centred on the origin with edge length `size`.
make_cube :: proc(size: f32, allocator := context.allocator) -> Mesh {
	assert(size > 0)
	half_size := size * 0.5
	mesh := Mesh{
		positions    = make([dynamic][3]f32, 0, 8, allocator),
		face_offsets = make([dynamic]u32, 0, 7, allocator),
		corner_verts = make([dynamic]u32, 0, 24, allocator),
	}

	// Vertex i takes its x, y, z signs from bits 0, 1, 2 of i (bit set = positive side).
	for vertex_index in 0 ..< 8 {
		append(&mesh.positions, [3]f32{
			half_size if vertex_index & 1 != 0 else -half_size,
			half_size if vertex_index & 2 != 0 else -half_size,
			half_size if vertex_index & 4 != 0 else -half_size,
		})
	}

	// Each face is counter-clockwise seen from outside (checked by the tests).
	CUBE_FACES :: [6][4]u32{
		{1, 3, 7, 5}, // +X
		{0, 4, 6, 2}, // -X
		{2, 6, 7, 3}, // +Y
		{0, 1, 5, 4}, // -Y
		{4, 5, 7, 6}, // +Z
		{0, 2, 3, 1}, // -Z
	}
	append(&mesh.face_offsets, 0)
	for face in CUBE_FACES {
		for vertex_index in face {
			append(&mesh.corner_verts, vertex_index)
		}
		append(&mesh.face_offsets, u32(len(mesh.corner_verts)))
	}
	return mesh
}

// Triangle data for flat shading: every face corner becomes its own render vertex carrying the
// face normal, and each face is split into a fan of triangles from its first corner.
// The fan is only correct for convex faces; concave faces need ear clipping (later).
// The three slices share one lifetime and are freed together with `allocator`.
flat_shaded_triangles :: proc(
	mesh: Mesh,
	allocator := context.allocator,
) -> (
	positions: [][3]f32,
	normals: [][3]f32,
	indices: []u32,
) {
	corner_count := len(mesh.corner_verts)
	triangle_count := corner_count - 2 * face_count(mesh) // a face with k corners gives k - 2 triangles

	positions = make([][3]f32, corner_count, allocator)
	normals = make([][3]f32, corner_count, allocator)
	indices = make([]u32, triangle_count * 3, allocator)

	written_index_count := 0
	for face_index in 0 ..< face_count(mesh) {
		first_corner := mesh.face_offsets[face_index]
		corners := face_corners(mesh, face_index)
		normal := face_normal(mesh, face_index)
		for vertex_index, corner_in_face in corners {
			positions[int(first_corner) + corner_in_face] = mesh.positions[vertex_index]
			normals[int(first_corner) + corner_in_face] = normal
		}
		for fan_step in 1 ..< u32(len(corners) - 1) {
			indices[written_index_count + 0] = first_corner
			indices[written_index_count + 1] = first_corner + fan_step
			indices[written_index_count + 2] = first_corner + fan_step + 1
			written_index_count += 3
		}
	}
	assert(written_index_count == len(indices))
	return
}
