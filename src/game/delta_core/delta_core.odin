package delta_core

import shader_assets "../../engine/render/shader_assets"
import voxel_renderer "../../engine/render/voxel"
import vulkan "../../engine/render/vulkan"
import shader_tools "../../engine/tools/shader"
import ui "../../engine/ui/microui"
import view "../../engine/view"
import voxel "../../engine/voxel"
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
	voxel_renderer:  voxel_renderer.Context,
	camera:          view.Camera,
	world:           []voxel.Volume,
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
	voxel_renderer.init(&game.voxel_renderer, &game.renderer)
	ui.init(&game.ui, &game.renderer, game.window)

	game.world = create_test_world()
	for &volume in game.world {
		voxel_renderer.add_volume(&game.voxel_renderer, &game.renderer, &volume)
	}

	game.camera.position = {-32, 32, 50}
	view.rotate(&game.camera, -360, 0)
	game.held_keys = make(map[sdl.Keycode]bool)
	if !sdl.SetWindowRelativeMouseMode(game.window, true) {
		fmt.eprintf("Failed to set relative mouse mode: %v\n", sdl.GetError())
	}

	shader_path := shader_assets.source_path("default.slang")
	shader_tools.add_file_watcher(&game.shader_watchers, shader_path, reload_shaders, game)
	delete(shader_path)
}

reload_shaders :: proc(data: rawptr, filepath: string) {
	_ = filepath
	game := cast(^Game)data
	shader_tools.compile("shader_src/", "shaders/")
	presentation_shader := shader_assets.load_bytes("default.spirv")
	defer delete(presentation_shader)
	vulkan.reload_presentation_shader(&game.renderer, presentation_shader)
	voxel_renderer.reload_shader(&game.voxel_renderer, &game.renderer)
	ui.reload_shader(&game.ui, &game.renderer)
}

before_swapchain_destroy :: proc(data: rawptr, r: ^vulkan.Renderer) {
	game := cast(^Game)data
	ui.before_swapchain_destroy(&game.ui, r)
	voxel_renderer.before_swapchain_destroy(&game.voxel_renderer, r)
}

after_swapchain_create :: proc(data: rawptr, r: ^vulkan.Renderer) {
	game := cast(^Game)data
	voxel_renderer.after_swapchain_create(&game.voxel_renderer, r)
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
				if event.key.key == sdl.K_F6 && !event.key.repeat {
					reload_shaders(game, "")
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
		build_ui(game, last_fps)
		update_camera(game, dt_ms)

		frame_input := voxel_renderer.Frame_Input {
			renderer = &game.voxel_renderer,
			camera   = game.camera,
		}
		vulkan.frame(
			&game.renderer,
			{
				source_image = voxel_renderer.output_image(&game.voxel_renderer),
				content_data = &frame_input,
				record_content = voxel_renderer.record_frame,
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
		"FPS",
		{h = 100, w = 100, x = 0, y = 0},
		mu.Options{.NO_SCROLL, .NO_INTERACT, .NO_FRAME, .NO_RESIZE, .NO_TITLE, .NO_CLOSE},
	)
	mu.text(ctx, fmt.tprintf("FPS: %.2f", fps))
	mu.end_window(ctx)
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
	shader_tools.destroy_file_watchers(&game.shader_watchers)
	ui.destroy(&game.ui, &game.renderer)
	voxel_renderer.destroy(&game.voxel_renderer, &game.renderer)
	voxel.destroy_volumes(game.world)
	delete(game.held_keys)
	vulkan.finish(&game.renderer)
	sdl.DestroyWindow(game.window)
	sdl.Quit()
	game^ = {}
}
