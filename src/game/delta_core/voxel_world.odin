package delta_core

import terrain_renderer "../../engine/render/terrain"
import voxel_terrain "../../engine/terrain/voxel"

Material :: enum u16 {
	AIR,
	SURFACE_ROCK,
	SURFACE_ROCK_ROLLING,
	ROCK,
	IRON_ORE,
	COPPER_ORE,
	PLAYER_SOLID,
}

Material_Flags :: bit_set[Material_Flag;u32]
Material_Flag :: enum u32 {
	MINABLE,
	BUILDABLE,
	RESOURCE,
}

Material_Definition :: struct {
	name:               string,
	base_color:         u32,
	variation_strength: f32,
	hardness:           f32,
	density:            f32,
	resource_yield:     u32,
	flags:              Material_Flags,
}

pack_voxel_color :: proc "contextless" (r, g, b: u8) -> u32 {
	return u32(r) | u32(g) << 8 | u32(b) << 16 | 0xFF << 24
}

MATERIAL_DEFINITIONS := [?]Material_Definition {
	{name = "Air", base_color = 0, variation_strength = 0},
	{
		name = "Surface Rock (Barren Plains)",
		base_color = pack_voxel_color(102, 88, 70),
		variation_strength = 0.18,
		hardness = 1.2,
		density = 2.4,
		flags = {.MINABLE},
	},
	{
		name = "Surface Rock (Rolling Wastes)",
		base_color = pack_voxel_color(117, 82, 55),
		variation_strength = 0.18,
		hardness = 1.2,
		density = 2.4,
		flags = {.MINABLE},
	},
	{
		name = "Basalt",
		base_color = pack_voxel_color(64, 68, 72),
		variation_strength = 0.14,
		hardness = 2.5,
		density = 2.9,
		flags = {.MINABLE},
	},
	{
		name = "Iron Ore",
		base_color = pack_voxel_color(184, 91, 47),
		variation_strength = 0.12,
		hardness = 3.1,
		density = 4.3,
		resource_yield = 1,
		flags = {.MINABLE, .RESOURCE},
	},
	{
		name = "Copper Ore",
		base_color = pack_voxel_color(59, 174, 154),
		variation_strength = 0.10,
		hardness = 2.8,
		density = 4.0,
		resource_yield = 1,
		flags = {.MINABLE, .RESOURCE},
	},
	{
		name = "Placed Composite",
		base_color = pack_voxel_color(78, 123, 170),
		variation_strength = 0.06,
		hardness = 4.0,
		density = 3.2,
		flags = {.MINABLE, .BUILDABLE},
	},
}

material_id :: proc(material: Material) -> voxel_terrain.Material_Id {
	return voxel_terrain.Material_Id(material)
}

material_from_id :: proc(id: voxel_terrain.Material_Id) -> Material {
	if u16(id) >= u16(len(MATERIAL_DEFINITIONS)) {
		return .ROCK
	}
	return Material(id)
}

material_definition :: proc(id: voxel_terrain.Material_Id) -> Material_Definition {
	return MATERIAL_DEFINITIONS[int(material_from_id(id))]
}

voxel_render_materials :: proc(
) -> [len(MATERIAL_DEFINITIONS)]terrain_renderer.Material_Render_Info {
	result: [len(MATERIAL_DEFINITIONS)]terrain_renderer.Material_Render_Info
	for definition, index in MATERIAL_DEFINITIONS {
		result[index] = {
			base_color         = definition.base_color,
			variation_strength = definition.variation_strength,
			flags              = definition.resource_yield > 0 ? 1 : 0,
		}
	}
	return result
}

terrain_render_materials :: proc() -> [len(Biome)]terrain_renderer.Material_Render_Info {
	result: [len(Biome)]terrain_renderer.Material_Render_Info
	for index in 0 ..< len(Biome) {
		result[index] = {
			base_color         = terrain_biome_color(Biome(index)),
			variation_strength = 0.12,
		}
	}
	return result
}

voxel_column_sample :: proc(data: rawptr, x, z: f32) -> voxel_terrain.Column_Sample {
	terrain := cast(^Natural_Terrain)data
	sample := sample_natural_terrain(terrain, x, z)
	material := material_id(.SURFACE_ROCK)
	#partial switch Biome(sample.material) {
	case .BARREN_PLAINS:
		material = material_id(.SURFACE_ROCK)
	case .ROLLING_WASTES:
		material = material_id(.SURFACE_ROCK_ROLLING)

	}
	return {
		surface_height = sample.height,
		surface_material = material,
		subsurface_material = material_id(.ROCK),
	}
}

point_segment_distance_squared :: proc(point, start, end: [3]f32) -> f32 {
	segment := end - start
	length_squared := segment.x * segment.x + segment.y * segment.y + segment.z * segment.z
	if length_squared <= 1e-6 {
		delta := point - start
		return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
	}
	delta := point - start
	amount := clamp(
		(delta.x * segment.x + delta.y * segment.y + delta.z * segment.z) / length_squared,
		f32(0),
		f32(1),
	)
	closest := start + segment * amount
	offset := point - closest
	return offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
}

initialize_voxel_geology :: proc(terrain: ^Natural_Terrain) {
	anchor_xz := terrain.plan.spawn + [2]f32{12, 4}
	anchor_height := sample_natural_terrain(terrain, anchor_xz.x, anchor_xz.y).height
	terrain.ore_vein_start = {anchor_xz.x, anchor_height + 0.65, anchor_xz.y}
	terrain.ore_vein_end = terrain.ore_vein_start + [3]f32{18, -27, 11}
}

guaranteed_iron_vein :: proc(terrain: ^Natural_Terrain, position: [3]f32) -> bool {
	start := terrain.ore_vein_start
	end := terrain.ore_vein_end
	minimum := [3]f32{min(start.x, end.x), min(start.y, end.y), min(start.z, end.z)} - 5
	maximum := [3]f32{max(start.x, end.x), max(start.y, end.y), max(start.z, end.z)} + 5
	if position.x < minimum.x ||
	   position.y < minimum.y ||
	   position.z < minimum.z ||
	   position.x > maximum.x ||
	   position.y > maximum.y ||
	   position.z > maximum.z {
		return false
	}
	warp := [3]f32 {
		(value_noise_3d(
				derive_seed(terrain.config.seed, 0x1A0),
				position.x / 8,
				position.y / 8,
				position.z / 8,
			) -
			0.5) *
		2.4,
		(value_noise_3d(
				derive_seed(terrain.config.seed, 0x1A1),
				position.x / 9,
				position.y / 9,
				position.z / 9,
			) -
			0.5) *
		1.2,
		(value_noise_3d(
				derive_seed(terrain.config.seed, 0x1A2),
				position.x / 8,
				position.y / 8,
				position.z / 8,
			) -
			0.5) *
		2.4,
	}
	radius :=
		1.65 +
		value_noise_3d(
			derive_seed(terrain.config.seed, 0x1A3),
			position.x / 5,
			position.y / 5,
			position.z / 5,
		) *
			1.15
	return point_segment_distance_squared(position + warp, start, end) <= radius * radius
}

regional_ore_material :: proc(
	terrain: ^Natural_Terrain,
	position: [3]f32,
	depth: f32,
) -> Material {
	if depth < 1.5 || depth > terrain.config.ore_generation_depth - 1 {
		return .ROCK
	}
	warp :=
		(value_noise_3d(
				derive_seed(terrain.config.seed, 0x0AE0),
				position.x / 24,
				position.y / 18,
				position.z / 24,
			) -
			0.5) *
		7
	iron := value_noise_3d(
		derive_seed(terrain.config.seed, 0x1A04),
		(position.x + warp) / 9,
		position.y / 6,
		(position.z - warp) / 9,
	)
	iron_region := value_noise_3d(
		derive_seed(terrain.config.seed, 0x1A05),
		position.x / 23,
		position.y / 15,
		position.z / 23,
	)
	if iron > 0.70 && iron_region > 0.48 {
		return .IRON_ORE
	}
	copper := value_noise_3d(
		derive_seed(terrain.config.seed, 0xC022),
		(position.x - warp) / 8,
		position.y / 10,
		(position.z + warp) / 8,
	)
	if depth > 6 && copper > 0.76 {
		return .COPPER_ORE
	}
	return .ROCK
}

voxel_natural_sample :: proc(
	data: rawptr,
	voxel: [3]i32,
	position: [3]f32,
	column: voxel_terrain.Column_Sample,
) -> voxel_terrain.Material_Id {
	terrain := cast(^Natural_Terrain)data
	if terrain.config.world_type != .DELTA_CORE {
		return sample_benchmark_voxel(terrain, voxel, position, column)
	}
	if position.y > column.surface_height {
		return voxel_terrain.AIR
	}
	depth := column.surface_height - position.y
	if guaranteed_iron_vein(terrain, position) {
		return material_id(.IRON_ORE)
	}
	ore := regional_ore_material(terrain, position, depth)
	if ore != .ROCK {
		return material_id(ore)
	}
	if depth <= 0.75 {
		return column.surface_material
	}
	return column.subsurface_material
}

voxel_source :: proc(terrain: ^Natural_Terrain) -> voxel_terrain.Source {
	return {
		data = terrain,
		sample_column = voxel_column_sample,
		sample_voxel = voxel_natural_sample,
	}
}

