package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import mu "vendor:microui"
import sdl "vendor:sdl3"

state: struct {
	ctx:      runtime.Context,
	window:   ^sdl.Window,
	renderer: vulkan_renderer,
	mu_ctx:   mu.Context,
	bg:       mu.Color,
}

main :: proc() {
	context.allocator = runtime.default_allocator()

	when ODIN_DEBUG || (ODIN_OPTIMIZATION_MODE == .Minimal) {
		DEV_MODE :: true
	} else {
		DEV_MODE :: false
	}

	when DEV_MODE {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(
			&track,
			context.allocator,
			internals_allocator = context.allocator,
		)
		fmt.printfln("DEV MODE ACTIVE")

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

	state.ctx = context
	state.bg = {90, 100, 120, 255}
	fmt.print("Hello, Odin! This is a test program. \n")

	mu.init(&state.mu_ctx, nil, nil, nil)
	state.mu_ctx.text_width = mu.default_atlas_text_width
	state.mu_ctx.text_height = mu.default_atlas_text_height

	if !sdl.Init({.VIDEO}) {
		fmt.panicf("Failed to initialize sdl: %v\n", sdl.GetError())
	}

	state.window = sdl.CreateWindow(
		"Odin Test Window",
		1024,
		1024,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY, .VULKAN},
	)
	if state.window == nil {
		fmt.panicf("Failed to create window: %v\n", sdl.GetError())
	}

	vulkan_init()
	run_game()
}

get_window_size_absolute :: proc() -> (w: i32, h: i32) {
	width, height: i32
	sdl.GetWindowSize(state.window, &width, &height)
	return width, height
}

get_window_size :: proc() -> (w: i32, h: i32) {
	width, height: i32
	sdl.GetWindowSizeInPixels(state.window, &width, &height)
	return width, height
}

run_game :: proc() {
	now := sdl.GetPerformanceCounter()
	last: u64
	dt: f32
	main_loop: for {
		last = now
		now = sdl.GetPerformanceCounter()
		dt = f32((now - last) * 1000) / f32(sdl.GetPerformanceFrequency())

		e: sdl.Event
		for sdl.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				break main_loop
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				vulkan_resize()
			case .KEY_DOWN:
				if e.key.key == sdl.K_ESCAPE {
					break main_loop
				}
				if e.key.key == sdl.K_F6 {
					rebuild_shaders()
				}
				mu.input_key_down(&state.mu_ctx, convert_key(e.key.key))
			case .KEY_UP:
				mu.input_key_up(&state.mu_ctx, convert_key(e.key.key))
			case .TEXT_INPUT:
				mu.input_text(&state.mu_ctx, string(e.text.text))
			case .MOUSE_MOTION:
				mu.input_mouse_move(&state.mu_ctx, auto_cast e.motion.x, auto_cast e.motion.y)
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				mu_mouse: mu.Mouse
				switch e.button.button {
				case 1:
					mu_mouse = .LEFT
				case 2:
					mu_mouse = .MIDDLE
				case 3:
					mu_mouse = .RIGHT
				}
				if e.button.down {
					mu.input_mouse_down(
						&state.mu_ctx,
						auto_cast e.button.x,
						auto_cast e.button.y,
						mu_mouse,
					)
				} else {
					mu.input_mouse_up(
						&state.mu_ctx,
						auto_cast e.button.x,
						auto_cast e.button.y,
						mu_mouse,
					)
				}
			case .MOUSE_WHEEL:
				mu.input_scroll(&state.mu_ctx, auto_cast e.wheel.x, auto_cast e.wheel.y)
			}
		}

		frame(dt)
	}

	finish()
	sdl.DestroyWindow(state.window)
	sdl.Quit()
}

frame :: proc(dt: f32) {
	context = state.ctx
	_ = dt
	mu.begin(&state.mu_ctx)
	demo_windows(&state.mu_ctx)
	mu.end(&state.mu_ctx)
	vulkan_frame()
}

finish :: proc() {
	vulkan_finish()
}
