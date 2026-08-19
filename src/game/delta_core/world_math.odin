package delta_core

import "core:math"

mix_u64 :: proc(value: u64) -> u64 {
	x := value ~ 0x9E37_79B9_7F4A_7C15
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	x ~= x >> 23
	x ~= x << 29
	return x
}

derive_seed :: proc(seed: u64, stream: u64) -> u64 {
	return mix_u64(seed ~ stream ~ (stream << 31) ~ (stream >> 11))
}

random_01 :: proc(seed: u64, index: u64) -> f32 {
	bits := u32(derive_seed(seed, index) >> 40)
	return f32(bits) / f32(0x00FF_FFFF)
}

hash_grid_01 :: proc(seed: u64, x, z: i32) -> f32 {
	key := u64(u32(x)) | (u64(u32(z)) << 32)
	return random_01(seed ~ key, 0)
}

smooth_curve :: proc(value: f32) -> f32 {
	value := clamp(value, f32(0), f32(1))
	return value * value * (3 - 2 * value)
}

lerp_f32 :: proc(a, b, amount: f32) -> f32 {
	return a + (b - a) * amount
}

smoothstep_f32 :: proc(edge_0, edge_1, value: f32) -> f32 {
	if edge_0 == edge_1 {
		return value >= edge_1 ? 1 : 0
	}
	return smooth_curve((value - edge_0) / (edge_1 - edge_0))
}

value_noise_2d :: proc(seed: u64, x, z: f32) -> f32 {
	x0 := i32(math.floor(x))
	z0 := i32(math.floor(z))
	tx := smooth_curve(x - f32(x0))
	tz := smooth_curve(z - f32(z0))
	a := hash_grid_01(seed, x0, z0)
	b := hash_grid_01(seed, x0 + 1, z0)
	c := hash_grid_01(seed, x0, z0 + 1)
	d := hash_grid_01(seed, x0 + 1, z0 + 1)
	return lerp_f32(lerp_f32(a, b, tx), lerp_f32(c, d, tx), tz)
}

fbm_2d :: proc(seed: u64, x, z: f32, octaves: int = 3) -> f32 {
	value: f32
	amplitude: f32 = 0.5
	frequency: f32 = 1
	normalization: f32
	for octave in 0 ..< octaves {
		value +=
			value_noise_2d(derive_seed(seed, u64(octave)), x * frequency, z * frequency) *
			amplitude
		normalization += amplitude
		frequency *= 2
		amplitude *= 0.5
	}
	return value / normalization
}

ridged_noise_2d :: proc(seed: u64, x, z: f32) -> f32 {
	value := value_noise_2d(seed, x, z)
	return 1 - abs(value * 2 - 1)
}
