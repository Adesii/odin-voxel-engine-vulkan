package view

import lina "core:math/linalg"
import "core:testing"

test_camera :: proc(position: [3]f32) -> Camera {
	camera := Camera {
		position = position,
	}
	rotate(&camera, 130, -45)
	update_matrices(&camera, 16.0 / 9.0, 90, 0.1, 65_536)
	return camera
}

unproject_relative_ray :: proc(camera: Camera, ndc: [2]f32) -> [3]f32 {
	target := camera.relative_inv_view_proj * [4]f32{ndc.x, ndc.y, -1, 1}
	return lina.normalize(target.xyz / target.w)
}

@(test)
relative_rays_do_not_depend_on_camera_distance_from_origin :: proc(t: ^testing.T) {
	near_origin := test_camera({0, 20, 0})
	far_away := test_camera({31_000, 20, -29_000})
	ndc_samples := [?][2]f32{{0, 0}, {-0.9, 0.8}, {0.37, -0.52}, {1, 1}}
	for ndc in ndc_samples {
		a := unproject_relative_ray(near_origin, ndc)
		b := unproject_relative_ray(far_away, ndc)
		testing.expect(t, lina.length(a - b) < 1e-6, "ray direction changed with camera position")
	}
	center := unproject_relative_ray(far_away, {0, 0})
	testing.expect(
		t,
		lina.length(center - forward(far_away)) < 1e-5,
		"screen centre ray does not match the camera forward vector",
	)
}

@(test)
reverse_z_maps_near_to_one_and_far_to_zero :: proc(t: ^testing.T) {
	camera := test_camera({12_000, 300, 9_000})
	look := forward(camera)
	depth_at :: proc(camera: Camera, direction: [3]f32, distance: f32) -> f32 {
		relative := direction * distance
		clip := camera.relative_view_proj_reverse_z * [4]f32{relative.x, relative.y, relative.z, 1}
		return clip.z / clip.w
	}
	near_depth := depth_at(camera, look, 0.1)
	far_depth := depth_at(camera, look, 65_536)
	testing.expect(t, abs(near_depth - 1) < 1e-4, "near plane must map to depth 1")
	testing.expect(t, abs(far_depth) < 1e-4, "far plane must map to depth 0")
	previous: f32 = 1
	for distance in ([?]f32{1, 10, 100, 1_000, 10_000, 60_000}) {
		depth := depth_at(camera, look, distance)
		testing.expect(t, depth < previous, "depth must decrease monotonically with distance")
		previous = depth
	}
	// A float depth buffer must still separate surfaces 2 m apart at 30 km.
	a := depth_at(camera, look, 30_000)
	b := depth_at(camera, look, 30_002)
	testing.expect(t, a > b, "reversed-Z cannot resolve 2 m at 30 km")
}
