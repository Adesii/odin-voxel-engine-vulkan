package microui_backend

import vulkan "../../render/vulkan"
import intr "base:intrinsics"
import "core:fmt"
import "core:math/linalg"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

Context :: struct {
	mu:     mu.Context,
	window: ^sdl.Window,
	gpu:    gpu_context,
}

init :: proc(ctx: ^Context, r: ^vulkan.Renderer, window: ^sdl.Window) {
	ctx^ = {}
	ctx.window = window
	mu.init(&ctx.mu, nil, nil, nil)
	ctx.mu.text_width = mu.default_atlas_text_width
	ctx.mu.text_height = mu.default_atlas_text_height
	gpu_init(ctx, r)
}

destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	gpu_destroy(ctx, r)
	ctx^ = {}
}

ui_context :: proc(ctx: ^Context) -> ^mu.Context {
	return &ctx.mu
}

convert_key :: proc(sdlkey: sdl.Keycode) -> mu.Key {
	switch sdlkey {
	case sdl.K_LSHIFT, sdl.K_RSHIFT:
		return .SHIFT
	case sdl.K_LCTRL, sdl.K_RCTRL:
		return .CTRL
	case sdl.K_LALT, sdl.K_RALT:
		return .ALT
	case sdl.K_BACKSPACE:
		return .BACKSPACE
	case sdl.K_DELETE:
		return .DELETE
	case sdl.K_RETURN:
		return .RETURN
	case sdl.K_LEFT:
		return .LEFT
	case sdl.K_RIGHT:
		return .RIGHT
	case sdl.K_HOME:
		return .HOME
	case sdl.K_END:
		return .END
	case sdl.K_A:
		return .A
	case sdl.K_X:
		return .X
	case sdl.K_C:
		return .C
	case sdl.K_V:
		return .V
	}
	return {}
}

handle_event :: proc(ctx: ^Context, event: sdl.Event) {
	#partial switch event.type {
	case .KEY_DOWN:
		mu.input_key_down(&ctx.mu, convert_key(event.key.key))
	case .KEY_UP:
		mu.input_key_up(&ctx.mu, convert_key(event.key.key))
	case .TEXT_INPUT:
		mu.input_text(&ctx.mu, string(event.text.text))
	case .MOUSE_MOTION:
		mu.input_mouse_move(&ctx.mu, auto_cast event.motion.x, auto_cast event.motion.y)
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button: mu.Mouse
		switch event.button.button {
		case 1:
			button = .LEFT
		case 2:
			button = .MIDDLE
		case 3:
			button = .RIGHT
		}
		if event.button.down {
			mu.input_mouse_down(
				&ctx.mu,
				auto_cast event.button.x,
				auto_cast event.button.y,
				button,
			)
		} else {
			mu.input_mouse_up(&ctx.mu, auto_cast event.button.x, auto_cast event.button.y, button)
		}
	case .MOUSE_WHEEL:
		mu.input_scroll(&ctx.mu, auto_cast event.wheel.x, auto_cast event.wheel.y)
	}
}

before_swapchain_destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	destroy_swapchain_objects(ctx, r)
}

after_swapchain_create :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	create_swapchain_objects(ctx, r)
	create_pipeline(ctx, r)
}

get_dpi :: proc(ctx: ^Context) -> f32 {
	return sdl.GetDisplayContentScale(sdl.GetDisplayForWindow(ctx.window))
}

write_constants :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	width, height: i32
	sdl.GetWindowSizeInPixels(ctx.window, &width, &height)
	transform :=
		linalg.matrix_ortho3d(0, f32(width), 0, f32(height), -1, 1) *
		linalg.matrix4_scale(get_dpi(ctx))
	vulkan.write_buffer(r, &ctx.gpu.const_buffer, &transform, size_of(transform))
}

flush :: proc(ctx: ^Context) {
	ui := &ctx.gpu
	if ui.buf_idx == 0 || ui.buf_idx == ui.prev_buf_idx {
		return
	}
	delta := ui.buf_idx - ui.prev_buf_idx
	vk.CmdDrawIndexed(ui.current_command, delta * 6, 1, ui.prev_buf_idx * 6, 0, 0)
	ui.prev_buf_idx = ui.buf_idx
}

bind :: proc(ctx: ^Context, command_buffer: vk.CommandBuffer) {
	ui := &ctx.gpu
	if ui.pipeline == {} ||
	   ui.pipeline_layout == {} ||
	   ui.descriptor_set == {} ||
	   ui.vertex_buffer.buffer == {} ||
	   ui.index_buffer.buffer == {} {
		fmt.panicf(
			"UI bind with invalid state pipeline=%v layout=%v set=%v vbuf=%v ibuf=%v",
			ui.pipeline,
			ui.pipeline_layout,
			ui.descriptor_set,
			ui.vertex_buffer.buffer,
			ui.index_buffer.buffer,
		)
	}
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, ui.pipeline)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		ui.pipeline_layout,
		0,
		1,
		&ui.descriptor_set,
		0,
		nil,
	)
	buffers := [3]vk.Buffer{ui.vertex_buffer.buffer, ui.tex_buffer.buffer, ui.color_buffer.buffer}
	offsets := [3]vk.DeviceSize{}
	vk.CmdBindVertexBuffers(command_buffer, 0, len(buffers), &buffers[0], &offsets[0])
	vk.CmdBindIndexBuffer(command_buffer, ui.index_buffer.buffer, 0, .UINT32)
}

submit :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	flush(ctx)
	write_constants(ctx, r)
	vulkan.write_buffer(
		r,
		&ui.vertex_buffer,
		raw_data(ui.vert_buf[:]),
		int(ui.buf_idx * 8 * size_of(f32)),
	)
	vulkan.write_buffer(
		r,
		&ui.tex_buffer,
		raw_data(ui.tex_buf[:]),
		int(ui.buf_idx * 8 * size_of(f32)),
	)
	vulkan.write_buffer(r, &ui.color_buffer, raw_data(ui.color_buf[:]), int(ui.buf_idx * 16))
	vulkan.write_buffer(
		r,
		&ui.index_buffer,
		raw_data(ui.index_buf[:]),
		int(ui.buf_idx * 6 * size_of(u32)),
	)
}

begin_render :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	command_buffer: vk.CommandBuffer,
	framebuffer: vk.Framebuffer,
) {
	ui := &ctx.gpu
	ui.buf_idx = 0
	ui.prev_buf_idx = 0
	ui.current_command = command_buffer
	ui.current_framebuffer = framebuffer
	begin_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = ui.render_pass,
		framebuffer = framebuffer,
		renderArea = {extent = r.extent},
	}
	vk.CmdBeginRenderPass(command_buffer, &begin_info, .INLINE)
	bind(ctx, command_buffer)
	vulkan.set_scissor(command_buffer, 0, 0, r.extent.width, r.extent.height)
}

end_render :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	submit(ctx, r)
	vk.CmdEndRenderPass(ctx.gpu.current_command)
}

full_flush :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	submit(ctx, r)
	ui.buf_idx = 0
	ui.prev_buf_idx = 0
	vk.CmdEndRenderPass(ui.current_command)
	begin_render(ctx, r, ui.current_command, ui.current_framebuffer)
}

record_frame :: proc(
	data: rawptr,
	r: ^vulkan.Renderer,
	command_buffer: vk.CommandBuffer,
	image_index: u32,
) {
	ctx := cast(^Context)data
	begin_render(ctx, r, command_buffer, ctx.gpu.framebuffers[image_index])
	command_backing: ^mu.Command
	for variant in mu.next_command_iterator(&ctx.mu, &command_backing) {
		switch command in variant {
		case ^mu.Command_Text:
			draw_text(ctx, r, command.str, command.pos, command.color)
		case ^mu.Command_Rect:
			draw_rect(ctx, r, command.rect, command.color)
		case ^mu.Command_Icon:
			draw_icon(ctx, r, command.id, command.rect, command.color)
		case ^mu.Command_Clip:
			set_clip_rect(ctx, command.rect, r)
		case ^mu.Command_Jump:
			unreachable()
		}
	}
	end_render(ctx, r)
}

push_quad :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	dst, src: mu.Rect,
	color: mu.Color,
) #no_bounds_check {
	ui := &ctx.gpu
	if ui.buf_idx == BUFFER_SIZE {
		full_flush(ctx, r)
	}
	textvert_idx := ui.buf_idx * 8
	color_idx := ui.buf_idx * 16
	element_idx := u32(ui.buf_idx * 4)
	index_idx := ui.buf_idx * 6
	ui.buf_idx += 1

	x := f32(src.x) / mu.DEFAULT_ATLAS_WIDTH
	y := f32(src.y) / mu.DEFAULT_ATLAS_HEIGHT
	w := f32(src.w) / mu.DEFAULT_ATLAS_WIDTH
	h := f32(src.h) / mu.DEFAULT_ATLAS_HEIGHT
	copy(ui.tex_buf[textvert_idx:], []f32{x, y, x + w, y, x, y + h, x + w, y + h})

	dx, dy, dw, dh := f32(dst.x), f32(dst.y), f32(dst.w), f32(dst.h)
	copy(ui.vert_buf[textvert_idx:], []f32{dx, dy, dx + dw, dy, dx, dy + dh, dx + dw, dy + dh})

	color := color
	intr.mem_copy_non_overlapping(raw_data(ui.color_buf[color_idx + 0:]), &color, 4)
	intr.mem_copy_non_overlapping(raw_data(ui.color_buf[color_idx + 4:]), &color, 4)
	intr.mem_copy_non_overlapping(raw_data(ui.color_buf[color_idx + 8:]), &color, 4)
	intr.mem_copy_non_overlapping(raw_data(ui.color_buf[color_idx + 12:]), &color, 4)

	copy(
		ui.index_buf[index_idx:],
		[]u32 {
			element_idx,
			element_idx + 1,
			element_idx + 2,
			element_idx + 2,
			element_idx + 3,
			element_idx + 1,
		},
	)
}

draw_rect :: proc(ctx: ^Context, r: ^vulkan.Renderer, rect: mu.Rect, color: mu.Color) {
	push_quad(ctx, r, rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], color)
}

draw_text :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	text: string,
	position: mu.Vec2,
	color: mu.Color,
) {
	dst := mu.Rect{position.x, position.y, 0, 0}
	for ch in text {
		if ch & 0xc0 == 0x80 {
			continue
		}
		glyph := min(int(ch), 127)
		src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + glyph]
		dst.w = src.w
		dst.h = src.h
		push_quad(ctx, r, dst, src, color)
		dst.x += dst.w
	}
}

draw_icon :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	id: mu.Icon,
	rect: mu.Rect,
	color: mu.Color,
) {
	src := mu.default_atlas[id]
	x := rect.x + (rect.w - src.w) / 2
	y := rect.y + (rect.h - src.h) / 2
	push_quad(ctx, r, {x, y, src.w, src.h}, src, color)
}

set_clip_rect :: proc(ctx: ^Context, rect: mu.Rect, r: ^vulkan.Renderer) {
	flush(ctx)
	x := min(u32(max(rect.x, 0)), r.extent.width)
	y := min(u32(max(rect.y, 0)), r.extent.height)
	w := min(u32(max(rect.w, 0)), r.extent.width - x)
	h := min(u32(max(rect.h, 0)), r.extent.height - y)
	vulkan.set_scissor(ctx.gpu.current_command, x, y, w, h)
}
