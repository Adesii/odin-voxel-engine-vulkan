package delta_core

import "core:fmt"
import "core:math"
import mu "vendor:microui"

biome_debug_color :: proc(biome: Biome) -> mu.Color {
	switch biome {
	case .BARREN_PLAINS:
		return {126, 107, 73, 255}
	case .ROLLING_WASTES:
		return {117, 82, 55, 255}
	case .OIL_BASIN:
		return {30, 29, 24, 255}
	case .BADLANDS:
		return {132, 56, 32, 255}
	case .MOUNTAIN:
		return {108, 108, 112, 255}
	}
	return {255, 0, 255, 255}
}

world_to_map :: proc(position: [2]f32, radius: f32, rect: mu.Rect) -> [2]i32 {
	return {
		rect.x + i32((position.x + radius) / (radius * 2) * f32(rect.w)),
		rect.y + rect.h - i32((position.y + radius) / (radius * 2) * f32(rect.h)),
	}
}

draw_map_outline :: proc(
	ctx: ^mu.Context,
	minimum, maximum: [2]f32,
	radius: f32,
	rect: mu.Rect,
	color: mu.Color,
) {
	min_point := world_to_map(minimum, radius, rect)
	max_point := world_to_map(maximum, radius, rect)
	x0 := min(min_point.x, max_point.x)
	x1 := max(min_point.x, max_point.x)
	y0 := min(min_point.y, max_point.y)
	y1 := max(min_point.y, max_point.y)
	mu.draw_rect(ctx, {x = x0, y = y0, w = max(x1 - x0, 1), h = 1}, color)
	mu.draw_rect(ctx, {x = x0, y = y1, w = max(x1 - x0, 1), h = 1}, color)
	mu.draw_rect(ctx, {x = x0, y = y0, w = 1, h = max(y1 - y0, 1)}, color)
	mu.draw_rect(ctx, {x = x1, y = y0, w = 1, h = max(y1 - y0, 1)}, color)
}

draw_world_plan_map :: proc(game: ^Game, ctx: ^mu.Context, rect: mu.Rect) {
	plan := &game.world.terrain.plan
	config := game.world.terrain.config
	mu.draw_rect(ctx, rect, {14, 15, 17, 255})
	cell_step := max(plan.resolution / 32, 1)
	for z: i32 = 0; z < plan.resolution; z += cell_step {
		for x: i32 = 0; x < plan.resolution; x += cell_step {
			position_min := plan_cell_position(config, plan.resolution, x, z)
			position_max := plan_cell_position(
				config,
				plan.resolution,
				min(x + cell_step, plan.resolution - 1),
				min(z + cell_step, plan.resolution - 1),
			)
			p0 := world_to_map(position_min, config.world_radius, rect)
			p1 := world_to_map(position_max, config.world_radius, rect)
			cell := plan.cells[z * plan.resolution + x]
			mu.draw_rect(
				ctx,
				{
					x = min(p0.x, p1.x),
					y = min(p0.y, p1.y),
					w = max(abs(p1.x - p0.x) + 1, 1),
					h = max(abs(p1.y - p0.y) + 1, 1),
				},
				biome_debug_color(cell.biome),
			)
		}
	}
	for sample_index in 0 ..< 96 {
		angle := f32(sample_index) / 96 * math.TAU
		position := [2]f32{math.cos(angle), math.sin(angle)} * config.crater_radius
		point := world_to_map(position, config.world_radius, rect)
		mu.draw_rect(ctx, {x = point.x, y = point.y, w = 2, h = 2}, {235, 70, 42, 255})
	}
	for feature in plan.world_features {
		point := world_to_map(feature.position, config.world_radius, rect)
		color := mu.Color{238, 213, 66, 255}
		if feature.kind == .RUIN {
			color = {180, 146, 91, 255}
		}
		mu.draw_rect(ctx, {x = point.x - 2, y = point.y - 2, w = 5, h = 5}, color)
	}
	cache_colors := [3]mu.Color{{30, 232, 77, 255}, {244, 190, 25, 255}, {42, 116, 245, 255}}
	for index in 0 ..< int(game.world.cache.config.level_count) {
		level := game.world.cache.levels[index]
		draw_map_outline(
			ctx,
			level.origin,
			level.origin + level.extent,
			config.world_radius,
			rect,
			cache_colors[index],
		)
	}
	camera_point := world_to_map(
		{game.camera.position.x, game.camera.position.z},
		config.world_radius,
		rect,
	)
	mu.draw_rect(
		ctx,
		{x = camera_point.x - 2, y = camera_point.y - 2, w = 5, h = 5},
		{255, 255, 255, 255},
	)
}

build_world_debug_ui :: proc(game: ^Game, ctx: ^mu.Context) {
	if !game.show_world_plan {
		return
	}
	if !mu.begin_window(ctx, "World Plan", {x = 8, y = 116, w = 440, h = 850}) {
		return
	}
	config := game.world.terrain.config
	plan := &game.world.terrain.plan
	mu.text(
		ctx,
		fmt.tprintf(
			"%s seed=%v attempt=%v",
			game.world.loaded_from_disk ? "loaded" : "generated",
			config.seed,
			plan.generation_attempt,
		),
	)
	mu.text(
		ctx,
		fmt.tprintf(
			"radius %.0fm crater %.0fm wall %.0fm",
			config.world_radius,
			config.crater_radius,
			config.crater_wall_width,
		),
	)
	mu.text(
		ctx,
		fmt.tprintf(
			"camera r=%.0fm biome=%v",
			radial_distance(game.camera.position),
			biome_at_camera(&game.world, game.camera.position),
		),
	)
	mu.text(
		ctx,
		fmt.tprintf(
			"plan %vx%v features=%v",
			plan.resolution,
			plan.resolution,
			len(plan.world_features),
		),
	)
	mu.text(
		ctx,
		fmt.tprintf(
			"cache generation=%v loaded LOD tiles=%v",
			game.world.cache.generation,
			game.world.cache.config.level_count,
		),
	)
	for index in 0 ..< int(game.world.cache.config.level_count) {
		level := game.world.cache.levels[index]
		mu.text(
			ctx,
			fmt.tprintf(
				"L%v %.0fm @ (%.0f, %.0f)",
				index,
				level.spacing,
				level.origin.x,
				level.origin.y,
			),
		)
	}
	mu.text(
		ctx,
		fmt.tprintf(
			"sparse bricks=%v cells=%v",
			len(game.world.modifications.bricks),
			game.world.modifications.modified_count,
		),
	)
	mu.layout_row(ctx, {-1}, 330)
	map_rect := mu.layout_next(ctx)
	draw_world_plan_map(game, ctx, map_rect)
	mu.end_window(ctx)
}
