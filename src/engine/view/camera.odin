package view

import "core:math"
import lina "core:math/linalg"

Camera :: struct {
	position:      [3]f32,
	rotation:      quaternion128,
	yaw_and_pitch: [2]f32,
	view_proj:     matrix[4, 4]f32,
	inv_view_proj: matrix[4, 4]f32,
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

update_matrices :: proc(
	camera: ^Camera,
	aspect_ratio: f32,
	field_of_view_degrees: f32 = 90,
	near_plane: f32 = 0.1,
	far_plane: f32 = 10000,
) {
	projection := lina.matrix4_perspective(
		math.to_radians(field_of_view_degrees),
		aspect_ratio,
		near_plane,
		far_plane,
	)
	rotation := lina.matrix4_from_quaternion(lina.quaternion_inverse(camera.rotation))
	translation := lina.matrix4_translate(-camera.position)
	axis_remap := matrix[4, 4]f32{
		0, 0, 1, 0,
		0, 1, 0, 0,
		-1, 0, 0, 0,
		0, 0, 0, 1,
	}
	view_matrix := axis_remap * rotation * translation
	camera.view_proj = projection * view_matrix
	camera.inv_view_proj = lina.matrix4_inverse(camera.view_proj)
}
