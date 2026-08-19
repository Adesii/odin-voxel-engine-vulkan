package delta_core

import shader_assets "../../engine/render/shader_assets"
import terrain_renderer "../../engine/render/terrain"
import vulkan "../../engine/render/vulkan"
import shader_tools "../../engine/tools/shader"
import ui "../../engine/ui/microui"
import view "../../engine/view"
import "base:runtime"
import "core:fmt"
import "core:mem"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

Game :: struct {
	window:          ^sdl.Window,
	renderer:        vulkan.Renderer,
	ui:              ui.Context,
	terrain_render:  terrain_renderer.Context,
	camera:          view.Camera,
	world:           World,
	debug_mode:      terrain_renderer.Debug_Mode,
	show_world_plan: bool,
	held_keys:       map[sdl.Keycode]bool,
	shader_watchers: shader_tools.Watcher_Set,
}

run :: proc() {
	context.allocator = runtime.default_allocator()

	when ODIN_DEBUG || (ODIN_OPTIMIZATION_MODE == .Minimal) {
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
		1024,
		1024,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY, .VULKAN},
	)
	if game.window == nil {
		fmt.panicf("Failed to create window: %v", sdl.GetError())
	}

	if !initialize_world(&game.world, default_world_config()) {
		fmt.panicf("Failed to load or generate Delta Core world")
	}
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
	game.held_keys = make(map[sdl.Keycode]bool)
	game.show_world_plan = true
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
			}
		}
		shader_tools.check_file_watchers(&game.shader_watchers)

		if elapsed_ms >= 1000 {
			last_fps = 1000.0 * f64(frame_count) / elapsed_ms
			elapsed_ms = 0
			frame_count = 0
		}
		update_camera(game, dt_ms)
		stream_world(&game.world, game.camera.position)
		build_ui(game, last_fps)

		config := game.world.terrain.config
		frame_input := terrain_renderer.Frame_Input {
			renderer          = &game.terrain_render,
			camera            = game.camera,
			cache             = &game.world.cache,
			overrides         = &game.world.modifications,
			world_radius      = config.world_radius,
			max_distance      = config.render_distance,
			debug_mode        = game.debug_mode,
			debug_ring_radius = config.crater_radius,
		}
		vulkan.frame(
			&game.renderer,
			{
				source_image = terrain_renderer.output_image(&game.terrain_render),
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
		{h = 112, w = 260, x = 0, y = 0},
		mu.Options{.NO_SCROLL, .NO_INTERACT, .NO_FRAME, .NO_RESIZE, .NO_TITLE, .NO_CLOSE},
	)
	mu.text(ctx, fmt.tprintf("FPS: %.2f", fps))
	mu.text(ctx, fmt.tprintf("Debug: %v (F1)", game.debug_mode))
	mu.text(ctx, "World Plan: F2")
	mu.end_window(ctx)
	build_world_debug_ui(game, ctx)
	mu.end(ctx)
}

update_camera :: proc(game: ^Game, dt_ms: f32) {
	speed := 100.0 * dt_ms / 1000.0
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
