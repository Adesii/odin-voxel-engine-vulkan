package view

import "core:math"
import lina "core:math/linalg"

Camera :: struct {
	position:                     [3]f32,
	rotation:                     quaternion128,
	yaw_and_pitch:                [2]f32,
	view_proj:                    matrix[4, 4]f32,
	inv_view_proj:                matrix[4, 4]f32,
	// Camera-relative transforms carry rotation and projection only. World
	// coordinates reach tens of kilometres, where an f32 translation baked into
	// a matrix loses millimetres to metres; applying these to
	// `world_position - camera.position` keeps full precision at any distance.
	relative_inv_view_proj:       matrix[4, 4]f32,
	// Vulkan reversed-Z (near -> 1, far -> 0) for a floating point depth buffer.
	relative_view_proj_reverse_z: matrix[4, 4]f32,
}

rotate :: proc(camera: ^Camera, mouse_x, mouse_y: f32, sensitivity: f32 = 0.002) {
	camera.yaw_and_pitch.x -= mouse_x * sensitivity
	camera.yaw_and_pitch.y -= mouse_y * sensitivity
	camera.yaw_and_pitch.y = clamp(camera.yaw_and_pitch.y, -math.PI / 2.01, math.PI / 2.01)

	yaw := lina.quaternion_angle_axis(camera.yaw_and_pitch.x, [3]f32{0, 1, 0})
	pitch_axis := lina.quaternion128_mul_vector3(yaw, [3]f32{0, 0, 1})
	pitch := lina.quaternion_angle_axis(camera.yaw_and_pitch.y, pitch_axis)
	camera.rotation = pitch * yaw
}

forward :: proc(camera: Camera) -> [3]f32 {
	return lina.quaternion128_mul_vector3(camera.rotation, [3]f32{1, 0, 0})
}

right :: proc(camera: Camera) -> [3]f32 {
	return lina.quaternion128_mul_vector3(camera.rotation, [3]f32{0, 0, 1})
}

up :: proc(camera: Camera) -> [3]f32 {
	return lina.quaternion128_mul_vector3(camera.rotation, [3]f32{0, 1, 0})
}

// Reversed-Z perspective projection producing Vulkan clip depth in [0, 1] with
// the near plane at 1 and the far plane at 0. X and Y follow the same OpenGL
// convention as `linalg.matrix4_perspective`; shaders flip Y for Vulkan.
perspective_reverse_z :: proc(
	field_of_view_radians, aspect_ratio, near_plane, far_plane: f32,
) -> (
	projection: matrix[4, 4]f32,
) {
	tan_half_fov := math.tan(0.5 * field_of_view_radians)
	projection[0, 0] = 1 / (aspect_ratio * tan_half_fov)
	projection[1, 1] = 1 / tan_half_fov
	projection[2, 2] = near_plane / (far_plane - near_plane)
	projection[2, 3] = near_plane * far_plane / (far_plane - near_plane)
	projection[3, 2] = -1
	return
}

update_matrices :: proc(
	camera: ^Camera,
	aspect_ratio: f32,
	field_of_view_degrees: f32 = 90,
	near_plane: f32 = 0.1,
	far_plane: f32 = 10000,
) {
	field_of_view := math.to_radians(field_of_view_degrees)
	projection := lina.matrix4_perspective(field_of_view, aspect_ratio, near_plane, far_plane)
	rotation := lina.matrix4_from_quaternion(lina.quaternion_inverse(camera.rotation))
	translation := lina.matrix4_translate(-camera.position)
	axis_remap := matrix[4, 4]f32{
		0, 0, 1, 0,
		0, 1, 0, 0,
		-1, 0, 0, 0,
		0, 0, 0, 1,
	}
	relative_view := axis_remap * rotation
	view_matrix := relative_view * translation
	camera.view_proj = projection * view_matrix
	camera.inv_view_proj = lina.matrix4_inverse(camera.view_proj)
	camera.relative_inv_view_proj = lina.matrix4_inverse(projection * relative_view)
	camera.relative_view_proj_reverse_z =
		perspective_reverse_z(field_of_view, aspect_ratio, near_plane, far_plane) * relative_view
}
