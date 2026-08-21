package delta_core

import tracy "../../../vendor/odin-tracy"
import shader_assets "../../engine/render/shader_assets"
import terrain_renderer "../../engine/render/terrain"
import vulkan "../../engine/render/vulkan"
import voxel_terrain "../../engine/terrain/voxel"
import shader_tools "../../engine/tools/shader"
import ui "../../engine/ui/microui"
import view "../../engine/view"
import "base:runtime"
import "core:fmt"
import "core:mem"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

TRACY_ENABLE :: #config(TRACY_ENABLE, false)

Game :: struct {
	window:              ^sdl.Window,
	renderer:            vulkan.Renderer,
	ui:                  ui.Context,
	terrain_render:      terrain_renderer.Context,
	camera:              view.Camera,
	world:               World,
	debug_mode:          terrain_renderer.Debug_Mode,
	terrain_config:      terrain_renderer.Config,
	show_world_plan:     bool,
	held_keys:           map[sdl.Keycode]bool,
	shader_watchers:     shader_tools.Watcher_Set,
	last_mined_material: Material,
	mined_resources:     [len(MATERIAL_DEFINITIONS)]u32,
}

run :: proc() {
	context.allocator = runtime.default_allocator()

	when (ODIN_DEBUG || (ODIN_OPTIMIZATION_MODE == .Minimal)) && !TRACY_ENABLE {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(
			&track,
			context.allocator,
			internals_allocator = context.allocator,
		)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	when TRACY_ENABLE {
		context.allocator = tracy.MakeProfiledAllocator(
			self = &tracy.ProfiledAllocatorData{},
			callstack_size = 5,
			backing_allocator = context.allocator,
			secure = true,
		)
	}

	game := new(Game)
	initialize(game)
	run_loop(game)
	shutdown(game)
	free(game)
}

initialize :: proc(game: ^Game) {
	if !sdl.Init({.VIDEO}) {
		fmt.panicf("Failed to initialize SDL: %v", sdl.GetError())
	}
	game.window = sdl.CreateWindow(
		"Delta Core",
		800,
		800,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY, .VULKAN},
	)
	if game.window == nil {
		fmt.panicf("Failed to create window: %v", sdl.GetError())
	}

	if !initialize_world(&game.world, default_world_config()) {
		fmt.panicf("Failed to load or generate Delta Core world")
	}
	game.terrain_config = default_terrain_render_config(game.world.terrain.config)
	assert(terrain_renderer.valid_config(game.terrain_config))
	shader_tools.compile("shader_src/", "shaders/")
	presentation_shader := shader_assets.load_bytes("default.spirv")
	defer delete(presentation_shader)
	vulkan.init(
		&game.renderer,
		game.window,
		{
			application_name = "Delta Core",
			engine_name = "Odin Voxel Engine",
			presentation_shader = presentation_shader,
		},
	)
	terrain_renderer.init(&game.terrain_render, &game.renderer)
	ui.init(&game.ui, &game.renderer, game.window)

	game.camera.position = spawn_camera_position(&game.world)
	view.rotate(&game.camera, 0, 140)
	stream_world(&game.world, game.camera.position)
	game.held_keys = make(map[sdl.Keycode]bool)
	game.show_world_plan = false
	if !sdl.SetWindowRelativeMouseMode(game.window, true) {
		fmt.eprintf("Failed to set relative mouse mode: %v\n", sdl.GetError())
	}

	shader_names := [?]string{"default.slang", "terrain.slang"}
	for shader_name in shader_names {
		shader_path := shader_assets.source_path(shader_name)
		shader_tools.add_file_watcher(&game.shader_watchers, shader_path, reload_shaders, game)
		delete(shader_path)
	}
}

reload_shaders :: proc(data: rawptr, filepath: string) {
	_ = filepath
	game := cast(^Game)data
	shader_tools.compile("shader_src/", "shaders/")
	presentation_shader := shader_assets.load_bytes("default.spirv")
	defer delete(presentation_shader)
	vulkan.reload_presentation_shader(&game.renderer, presentation_shader)
	terrain_renderer.reload_shader(&game.terrain_render, &game.renderer)
	ui.reload_shader(&game.ui, &game.renderer)
}
before_swapchain_destroy :: proc(data: rawptr, r: ^vulkan.Renderer) {
	game := cast(^Game)data
	ui.before_swapchain_destroy(&game.ui, r)
	terrain_renderer.before_swapchain_destroy(&game.terrain_render, r)
}

after_swapchain_create :: proc(data: rawptr, r: ^vulkan.Renderer) {
	game := cast(^Game)data
	terrain_renderer.after_swapchain_create(&game.terrain_render, r)
	ui.after_swapchain_create(&game.ui, r)
}

run_loop :: proc(game: ^Game) {
	now := sdl.GetPerformanceCounter()
	last: u64
	frame_count: u64
	elapsed_ms: f64
	last_fps: f64

	main_loop: for {
		defer tracy.FrameMark("Main Loop")
		last = now
		now = sdl.GetPerformanceCounter()
		dt_ms := f32((now - last) * 1000) / f32(sdl.GetPerformanceFrequency())
		elapsed_ms += f64(dt_ms)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			ui.handle_event(&game.ui, event)
			#partial switch event.type {
			case .QUIT:
				break main_loop
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				vulkan.resize(&game.renderer)
			case .KEY_DOWN:
				if event.key.key == sdl.K_ESCAPE {
					break main_loop
				}
				if !event.key.repeat {
					if event.key.key == sdl.K_F6 {
						reload_shaders(game, "")
					} else if event.key.key == sdl.K_F1 {
						game.debug_mode = terrain_renderer.Debug_Mode(
							(u32(game.debug_mode) + 1) % u32(len(terrain_renderer.Debug_Mode)),
						)
					} else if event.key.key == sdl.K_F2 {
						game.show_world_plan = !game.show_world_plan
					}
				}
				game.held_keys[event.key.key] = true
			case .KEY_UP:
				game.held_keys[event.key.key] = false
			case .MOUSE_MOTION:
				view.rotate(&game.camera, f32(event.motion.xrel), f32(event.motion.yrel))
			case .MOUSE_BUTTON_DOWN:
				if event.button.button == sdl.BUTTON_LEFT {
					edit_crosshair_voxel(game, false)
				} else if event.button.button == sdl.BUTTON_RIGHT {
					edit_crosshair_voxel(game, true)
				}
			case .MOUSE_WHEEL:
				if event.wheel.integer_y > 0 {
					base_speed += 1
				} else {
					base_speed -= 1
				}
				base_speed = max(base_speed, 1.0)
			}
		}
		shader_tools.check_file_watchers(&game.shader_watchers)

		if elapsed_ms >= 1000 {
			last_fps = 1000.0 * f64(frame_count) / elapsed_ms
			stats := game.world.voxels.stats
			fmt.printf(
				"Voxel stats: fps=%.1f chunks=%v pending=%v bricks=%v/%v/%v detailed=%v generation=%.2fms CPU=%.2fMiB GPU=%.2fMiB edits=%v\n",
				last_fps,
				stats.resident_chunks,
				stats.pending_chunks,
				stats.empty_bricks,
				stats.solid_bricks,
				stats.mixed_bricks,
				stats.detailed_voxels,
				stats.generation_ms,
				f64(stats.resident_bytes) / (1024 * 1024),
				f64(stats.gpu_bytes) / (1024 * 1024),
				stats.persistent_edits,
			)
			traversal := game.terrain_render.stats
			fmt.printf(
				"Heightfield DDA: sampled=%v cells=%.1f max=%v hit-distance=%.1fm lod-cells=%.1f/%.1f/%.1f lod-hits=%v/%v/%v reps=%v/%v/%v misses=%v\n",
				traversal.sampled_rays,
				traversal.average_heightfield_cells,
				traversal.maximum_heightfield_cells,
				traversal.average_heightfield_hit_distance,
				traversal.average_lod_cells[0],
				traversal.average_lod_cells[1],
				traversal.average_lod_cells[2],
				traversal.lod_hits[0],
				traversal.lod_hits[1],
				traversal.lod_hits[2],
				traversal.voxel_only_hits,
				traversal.heightfield_only_hits,
				traversal.blended_hits,
				traversal.missed_rays,
			)
			elapsed_ms = 0
			frame_count = 0
		}
		update_camera(game, dt_ms)
		stream_world(&game.world, game.camera.position)
		build_ui(game, last_fps)

		config := game.world.terrain.config
		render_materials := voxel_render_materials()
		terrain_materials := terrain_render_materials()
		frame_input := terrain_renderer.Frame_Input {
			renderer          = &game.terrain_render,
			camera            = game.camera,
			cache             = &game.world.cache,
			overrides         = &game.world.modifications,
			voxels            = &game.world.voxels,
			materials         = render_materials[:],
			terrain_materials = terrain_materials[:],
			config            = game.terrain_config,
			visual_seed       = config.seed,
			world_radius      = config.world_radius,
			debug_mode        = game.debug_mode,
			debug_ring_radius = config.crater_radius,
		}
		vulkan.frame(
			&game.renderer,
			{
				source_image = terrain_renderer.output_image(&game.terrain_render, &game.renderer),
				content_data = &frame_input,
				record_content = terrain_renderer.record_frame,
				overlay_data = &game.ui,
				record_overlay = ui.record_frame,
				swapchain = {
					data = game,
					before_destroy = before_swapchain_destroy,
					after_create = after_swapchain_create,
				},
			},
		)
		frame_count += 1
	}
}

build_ui :: proc(game: ^Game, fps: f64) {
	ctx := ui.ui_context(&game.ui)
	mu.begin(ctx)
	mu.begin_window(
		ctx,
		"Runtime",
		{h = 220, w = 380, x = 0, y = 0},
		mu.Options{.NO_SCROLL, .NO_INTERACT, .NO_FRAME, .NO_RESIZE, .NO_TITLE, .NO_CLOSE},
	)
	mu.text(ctx, fmt.tprintf("FPS: %.2f", fps))
	mu.text(ctx, fmt.tprintf("Debug: %v (F1)", game.debug_mode))
	mu.text(ctx, "LMB mine / RMB place / F2 world plan")
	mu.text(
		ctx,
		fmt.tprintf(
			"Virtual voxels: %.0f / %.0f / %.0f m",
			game.terrain_config.virtual_voxel_size[0],
			game.terrain_config.virtual_voxel_size[1],
			game.terrain_config.virtual_voxel_size[2],
		),
	)
	stats := game.terrain_render.stats
	mu.text(
		ctx,
		fmt.tprintf(
			"DDA cells avg/max: %.1f / %v",
			stats.average_heightfield_cells,
			stats.maximum_heightfield_cells,
		),
	)
	mu.text(ctx, fmt.tprintf("HF hit distance: %.1f m", stats.average_heightfield_hit_distance))
	if game.last_mined_material != .AIR {
		mu.text(ctx, fmt.tprintf("Last mined: %v", game.last_mined_material))
	}
	mu.end_window(ctx)
	build_world_debug_ui(game, ctx)
	mu.end(ctx)
}

base_speed := 1.0

update_camera :: proc(game: ^Game, dt_ms: f32) {
	speed := 12.0 * dt_ms / 1000.0
	speed *= f32(base_speed)
	if game.held_keys[sdl.K_LSHIFT] {
		speed *= 5
	}
	forward := view.forward(game.camera)
	right := view.right(game.camera)
	up := view.up(game.camera)
	movement: [3]f32
	for key, held in game.held_keys {
		if !held {
			continue
		}
		switch key {
		case sdl.K_W:
			movement += forward * speed
		case sdl.K_S:
			movement -= forward * speed
		case sdl.K_A:
			movement -= right * speed
		case sdl.K_D:
			movement += right * speed
		case sdl.K_Q:
			movement -= up * speed
		case sdl.K_E:
			movement += up * speed
		}
	}
	game.camera.position += movement

	if game.renderer.extent.height == 0 {
		return
	}
	aspect_ratio := f32(game.renderer.extent.width) / f32(game.renderer.extent.height)
	view.update_matrices(&game.camera, aspect_ratio)
}

edit_crosshair_voxel :: proc(game: ^Game, place: bool) {
	config := game.world.terrain.config
	hit := voxel_terrain.raycast(
		&game.world.voxels,
		game.camera.position,
		view.forward(game.camera),
		config.voxel_render_radius,
	)
	if !hit.hit {
		return
	}
	if place {
		voxel_terrain.set_material(
			&game.world.voxels,
			&game.world.modifications,
			hit.previous_voxel,
			material_id(.PLAYER_SOLID),
		)
		fmt.printf("Placed %v at %v\n", Material.PLAYER_SOLID, hit.previous_voxel)
		return
	}
	material := material_from_id(hit.material)
	definition := material_definition(hit.material)
	game.last_mined_material = material
	if definition.resource_yield > 0 {
		game.mined_resources[int(material)] += definition.resource_yield
	}
	voxel_terrain.set_material(
		&game.world.voxels,
		&game.world.modifications,
		hit.voxel,
		voxel_terrain.AIR,
	)
	fmt.printf(
		"Mined %v voxel at %v; resource total=%v\n",
		material,
		hit.voxel,
		game.mined_resources[int(material)],
	)
}

shutdown :: proc(game: ^Game) {
	_ = vk.DeviceWaitIdle(game.renderer.device)
	if !save_world(&game.world) {
		fmt.eprintf("Failed to save Delta Core world\n")
	}
	shader_tools.destroy_file_watchers(&game.shader_watchers)
	ui.destroy(&game.ui, &game.renderer)
	terrain_renderer.destroy(&game.terrain_render, &game.renderer)
	destroy_world(&game.world)
	delete(game.held_keys)
	vulkan.finish(&game.renderer)
	sdl.DestroyWindow(game.window)
	sdl.Quit()
	game^ = {}
}
