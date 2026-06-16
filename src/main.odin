package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import compiler "utils"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

state: struct {
	ctx:             runtime.Context,
	window:          ^sdl.Window,
	instance:        wgpu.Instance,
	surface:         wgpu.Surface,
	adapter:         wgpu.Adapter,
	device:          wgpu.Device,
	queue:           wgpu.Queue,
	config:          wgpu.SurfaceConfiguration,
	pipeline:        wgpu.RenderPipeline,
	pipeline_layout: wgpu.PipelineLayout,
	module:          wgpu.ShaderModule,
	renderer:        microui_ctx,
	mu_ctx:          mu.Context,
	bg:              mu.Color,
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
		{.RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	if state.window == nil {
		fmt.panicf("Failed to create window: %v\n", sdl.GetError())
	}

	state.instance = wgpu.CreateInstance(&wgpu.InstanceDescriptor{})
	if state.instance == nil {
		fmt.panicf("Failed to create WGPU instance\n")
	}
	state.surface = sdl3glue.GetSurface(state.instance, state.window)
	wgpu.InstanceRequestAdapter(
		state.instance,
		&wgpu.RequestAdapterOptions{compatibleSurface = state.surface},
		{callback = on_adapter},
	)

	on_adapter :: proc "c" (
		status: wgpu.RequestAdapterStatus,
		adapter: wgpu.Adapter,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = state.ctx
		if status != .Success || adapter == nil {
			fmt.panicf("request adapter failure: [%v] %s", status, message)
		}
		fmt.printfln("Got a Adapter")
		state.adapter = adapter
		wgpu.AdapterRequestDevice(adapter, &wgpu.DeviceDescriptor{}, {callback = on_device})
	}


	on_device :: proc "c" (
		status: wgpu.RequestDeviceStatus,
		device: wgpu.Device,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = state.ctx
		if status != .Success || device == nil {
			fmt.panicf("request device failure: [%v] %s", status, message)
		}
		fmt.printfln("Got a Device")
		state.device = device

		width, height: i32
		sdl.GetWindowSizeInPixels(state.window, &width, &height)

		state.config = wgpu.SurfaceConfiguration {
			device      = state.device,
			usage       = {.RenderAttachment},
			format      = .BGRA8Unorm,
			width       = cast(u32)width,
			height      = cast(u32)height,
			presentMode = .Fifo,
			alphaMode   = .Opaque,
		}
		wgpu.SurfaceConfigure(state.surface, &state.config)

		state.queue = wgpu.DeviceGetQueue(state.device)

		r_on_adapter_and_device()

		rebuild_shaders()


		run_game()
	}
}

get_window_size_absolute :: proc() -> (w: i32, h: i32) {
	width, height: i32
	sdl.GetWindowSize(state.window, &width, &height)
	// fmt.printfln("Window size is %d x %d", width, height)
	return width, height
}
get_window_size :: proc() -> (w: i32, h: i32) {
	width, height: i32
	sdl.GetWindowSizeInPixels(state.window, &width, &height)
	// fmt.printfln("Window size is %d x %d", width, height)
	return width, height
}
get_dpi :: proc() -> f32 {
	return sdl.GetDisplayContentScale(sdl.GetDisplayForWindow(state.window))
}
convert_key :: proc(sdlkey: sdl.Keycode) -> mu.Key {
	// Convert SDL keycodes to microui keys
	mu_key: mu.Key
	switch sdlkey {
	case sdl.K_LSHIFT, sdl.K_RSHIFT:
		mu_key = .SHIFT
	case sdl.K_LCTRL, sdl.K_RCTRL:
		mu_key = .CTRL
	case sdl.K_LALT, sdl.K_RALT:
		mu_key = .ALT
	case sdl.K_BACKSPACE:
		mu_key = .BACKSPACE
	case sdl.K_DELETE:
		mu_key = .DELETE
	case sdl.K_RETURN:
		mu_key = .RETURN
	case sdl.K_LEFT:
		mu_key = .LEFT
	case sdl.K_RIGHT:
		mu_key = .RIGHT
	}

	return mu_key
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
			#partial switch (e.type) {
			case .QUIT:
				break main_loop
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				resize()
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


resize :: proc() {
	context = state.ctx
	width, height: i32
	sdl.GetWindowSizeInPixels(state.window, &width, &height)

	state.config.width, state.config.height = cast(u32)width, cast(u32)height
	wgpu.SurfaceConfigure(state.surface, &state.config)
	fmt.printfln("Resized surface to %d x %d", width, height)
}

frame :: proc(dt: f32) {
	context = state.ctx

	surface_texture := wgpu.SurfaceGetCurrentTexture(state.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// All good, could handle suboptimal here.
	case .Timeout, .Outdated, .Lost:
		// Skip this frame, and re-configure surface.
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		fmt.printfln(
			"Surface texture not available, status=%v. Resizing surface...",
			surface_texture.status,
		)
		resize()
		return
	case .Occluded, .Error:
		// Fatal error
		fmt.panicf("[triangle] get_current_texture status=%v", surface_texture.status)
	}

	//UI Declarations
	mc := &state.mu_ctx

	mu.begin(mc)
	demo_windows(mc)
	mu.end(mc)

	defer wgpu.TextureRelease(surface_texture.texture)

	frame := wgpu.TextureCreateView(surface_texture.texture, nil)
	defer wgpu.TextureViewRelease(frame)

	command_encoder := wgpu.DeviceCreateCommandEncoder(state.device, nil)
	defer wgpu.CommandEncoderRelease(command_encoder)

	render_pass_encoder := wgpu.CommandEncoderBeginRenderPass(
		command_encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = frame,
				loadOp = .Clear,
				storeOp = .Store,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				clearValue = {
					f64(state.bg.r) / 255,
					f64(state.bg.g) / 255,
					f64(state.bg.b) / 255,
					1,
				},
			},
		},
	)

	wgpu.RenderPassEncoderSetPipeline(render_pass_encoder, state.pipeline)

	wgpu.RenderPassEncoderDraw(
		render_pass_encoder,
		vertexCount = 6,
		instanceCount = 1,
		firstVertex = 0,
		firstInstance = 0,
	)


	wgpu.RenderPassEncoderEnd(render_pass_encoder)
	wgpu.RenderPassEncoderRelease(render_pass_encoder)

	state.renderer.curr_encoder = command_encoder
	state.renderer.curr_view = frame
	state.renderer.curr_texture = surface_texture
	r_render()

	command_buffer := wgpu.CommandEncoderFinish(command_encoder, nil)
	defer wgpu.CommandBufferRelease(command_buffer)

	wgpu.QueueSubmit(state.queue, {command_buffer})
	wgpu.SurfacePresent(state.surface)
}

finish :: proc() {
	wgpu.RenderPipelineRelease(state.pipeline)
	wgpu.PipelineLayoutRelease(state.pipeline_layout)
	wgpu.ShaderModuleRelease(state.module)
	wgpu.QueueRelease(state.queue)
	wgpu.DeviceRelease(state.device)
	wgpu.AdapterRelease(state.adapter)
	wgpu.SurfaceRelease(state.surface)
	wgpu.InstanceRelease(state.instance)
}
