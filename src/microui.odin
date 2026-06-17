package main

import intr "base:intrinsics"

import "core:fmt"
import "core:math/linalg"

import vma "../vendor/odin-vma"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

BUFFER_SIZE :: 16384

microui_ctx :: struct {
	texture_image:       vk.Image,
	texture_allocation:  vma.Allocation,
	texture_view:        vk.ImageView,
	sampler:             vk.Sampler,
	descriptor_layout:   vk.DescriptorSetLayout,
	descriptor_pool:     vk.DescriptorPool,
	descriptor_set:      vk.DescriptorSet,
	pipeline_layout:     vk.PipelineLayout,
	pipeline:            vk.Pipeline,
	render_pass:         vk.RenderPass,
	framebuffers:        []vk.Framebuffer,
	vertex_buffer:       vulkan_buffer,
	tex_buffer:          vulkan_buffer,
	color_buffer:        vulkan_buffer,
	index_buffer:        vulkan_buffer,
	const_buffer:        vulkan_buffer,
	shader_module:       vk.ShaderModule,
	tex_buf:             [BUFFER_SIZE * 8]f32,
	vert_buf:            [BUFFER_SIZE * 8]f32,
	color_buf:           [BUFFER_SIZE * 16]u8,
	index_buf:           [BUFFER_SIZE * 6]u32,
	prev_buf_idx:        u32,
	buf_idx:             u32,
	current_command:     vk.CommandBuffer,
	current_framebuffer: vk.Framebuffer,
}

get_dpi :: proc() -> f32 {
	return sdl.GetDisplayContentScale(sdl.GetDisplayForWindow(state.window))
}

convert_key :: proc(sdlkey: sdl.Keycode) -> mu.Key {
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
	case sdl.K_HOME:
		mu_key = .HOME
	case sdl.K_END:
		mu_key = .END
	case sdl.K_A:
		mu_key = .A
	case sdl.K_X:
		mu_key = .X
	case sdl.K_C:
		mu_key = .C
	case sdl.K_V:
		mu_key = .V
	}

	return mu_key
}

r_write_consts :: proc() {
	r := &state.renderer.ui
	dpi := get_dpi()
	width, height := get_window_size()
	fw, fh := f32(width), f32(height)
	transform := linalg.matrix_ortho3d(0, fw, 0, fh, -1, 1) * linalg.matrix4_scale(dpi)
	vulkan_write_buffer(
		&state.renderer,
		&r.const_buffer,
		raw_data([]matrix[4, 4]f32{transform}),
		size_of(transform),
	)
}

r_flush :: proc() {
	r := &state.renderer.ui
	if r.buf_idx == 0 || r.buf_idx == r.prev_buf_idx {
		return
	}
	delta := r.buf_idx - r.prev_buf_idx
	vk.CmdDrawIndexed(r.current_command, delta * 6, 1, r.prev_buf_idx * 6, 0, 0)
	r.prev_buf_idx = r.buf_idx
}

r_bind :: proc(command_buffer: vk.CommandBuffer) {
	r := &state.renderer.ui
	if r.pipeline == {} ||
	   r.pipeline_layout == {} ||
	   r.descriptor_set == {} ||
	   r.vertex_buffer.buffer == {} ||
	   r.index_buffer.buffer == {} {
		fmt.panicf(
			"UI bind with invalid state pipeline=%v layout=%v set=%v vbuf=%v ibuf=%v",
			r.pipeline,
			r.pipeline_layout,
			r.descriptor_set,
			r.vertex_buffer.buffer,
			r.index_buffer.buffer,
		)
	}
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, r.pipeline)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		r.pipeline_layout,
		0,
		1,
		&r.descriptor_set,
		0,
		nil,
	)
	buffers := [3]vk.Buffer{r.vertex_buffer.buffer, r.tex_buffer.buffer, r.color_buffer.buffer}
	offsets := [3]vk.DeviceSize{0, 0, 0}
	vk.CmdBindVertexBuffers(command_buffer, 0, 3, &buffers[0], &offsets[0])
	vk.CmdBindIndexBuffer(command_buffer, r.index_buffer.buffer, 0, .UINT32)
}

r_submit :: proc() {
	r := &state.renderer.ui
	r_flush()
	r_write_consts()
	vulkan_write_buffer(
		&state.renderer,
		&r.vertex_buffer,
		raw_data(r.vert_buf[:]),
		int(r.buf_idx * 8 * size_of(f32)),
	)
	vulkan_write_buffer(
		&state.renderer,
		&r.tex_buffer,
		raw_data(r.tex_buf[:]),
		int(r.buf_idx * 8 * size_of(f32)),
	)
	vulkan_write_buffer(
		&state.renderer,
		&r.color_buffer,
		raw_data(r.color_buf[:]),
		int(r.buf_idx * 16),
	)
	vulkan_write_buffer(
		&state.renderer,
		&r.index_buffer,
		raw_data(r.index_buf[:]),
		int(r.buf_idx * 6 * size_of(u32)),
	)
}

r_begin :: proc(command_buffer: vk.CommandBuffer, framebuffer: vk.Framebuffer) {
	r := &state.renderer.ui
	r.buf_idx = 0
	r.prev_buf_idx = 0
	r.current_command = command_buffer
	r.current_framebuffer = framebuffer
	begin_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = r.render_pass,
		framebuffer = framebuffer,
		renderArea = {extent = state.renderer.extent},
	}
	vk.CmdBeginRenderPass(command_buffer, &begin_info, .INLINE)
	r_bind(command_buffer)
	vulkan_set_scissor(
		command_buffer,
		0,
		0,
		state.renderer.extent.width,
		state.renderer.extent.height,
	)
}

r_end :: proc() {
	r_submit()
	vk.CmdEndRenderPass(state.renderer.ui.current_command)
}

r_full_flush :: proc() {
	r := &state.renderer.ui
	r_submit()
	r.buf_idx = 0
	r.prev_buf_idx = 0
	vk.CmdEndRenderPass(r.current_command)
	r_begin(r.current_command, r.current_framebuffer)
}

r_render :: proc(command_buffer: vk.CommandBuffer, framebuffer: vk.Framebuffer) {
	r_begin(command_buffer, framebuffer)
	command_backing: ^mu.Command
	for variant in mu.next_command_iterator(&state.mu_ctx, &command_backing) {
		switch cmd in variant {
		case ^mu.Command_Text:
			r_draw_text(cmd.str, cmd.pos, cmd.color)
		case ^mu.Command_Rect:
			r_draw_rect(cmd.rect, cmd.color)
		case ^mu.Command_Icon:
			r_draw_icon(cmd.id, cmd.rect, cmd.color)
		case ^mu.Command_Clip:
			r_set_clip_rect(cmd.rect)
		case ^mu.Command_Jump:
			unreachable()
		}
	}
	r_end()
}

push_quad :: proc(dst, src: mu.Rect, color: mu.Color) #no_bounds_check {
	r := &state.renderer.ui
	if r.buf_idx == BUFFER_SIZE {
		r_full_flush()
	}
	textvert_idx := r.buf_idx * 8
	color_idx := r.buf_idx * 16
	element_idx := u32(r.buf_idx * 4)
	index_idx := r.buf_idx * 6
	r.buf_idx += 1

	x := f32(src.x) / mu.DEFAULT_ATLAS_WIDTH
	y := f32(src.y) / mu.DEFAULT_ATLAS_HEIGHT
	w := f32(src.w) / mu.DEFAULT_ATLAS_WIDTH
	h := f32(src.h) / mu.DEFAULT_ATLAS_HEIGHT
	copy(r.tex_buf[textvert_idx:], []f32{x, y, x + w, y, x, y + h, x + w, y + h})

	dx, dy, dw, dh := f32(dst.x), f32(dst.y), f32(dst.w), f32(dst.h)
	copy(r.vert_buf[textvert_idx:], []f32{dx, dy, dx + dw, dy, dx, dy + dh, dx + dw, dy + dh})

	color := color
	intr.mem_copy_non_overlapping(raw_data(r.color_buf[color_idx + 0:]), &color, 4)
	intr.mem_copy_non_overlapping(raw_data(r.color_buf[color_idx + 4:]), &color, 4)
	intr.mem_copy_non_overlapping(raw_data(r.color_buf[color_idx + 8:]), &color, 4)
	intr.mem_copy_non_overlapping(raw_data(r.color_buf[color_idx + 12:]), &color, 4)

	copy(
		r.index_buf[index_idx:],
		[]u32 {
			element_idx + 0,
			element_idx + 1,
			element_idx + 2,
			element_idx + 2,
			element_idx + 3,
			element_idx + 1,
		},
	)
}

r_draw_rect :: proc(rect: mu.Rect, color: mu.Color) {
	push_quad(rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], color)
}

r_draw_text :: proc(text: string, pos: mu.Vec2, color: mu.Color) {
	dst := mu.Rect{pos.x, pos.y, 0, 0}
	for ch in text {
		if ch & 0xc0 != 0x80 {
			r := min(int(ch), 127)
			src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
			dst.w = src.w
			dst.h = src.h
			push_quad(dst, src, color)
			dst.x += dst.w
		}
	}
}

r_draw_icon :: proc(id: mu.Icon, rect: mu.Rect, color: mu.Color) {
	src := mu.default_atlas[id]
	x := rect.x + (rect.w - src.w) / 2
	y := rect.y + (rect.h - src.h) / 2
	push_quad({x, y, src.w, src.h}, src, color)
}

r_set_clip_rect :: proc(rect: mu.Rect) {
	r := &state.renderer.ui
	r_flush()
	x := min(u32(max(rect.x, 0)), state.renderer.extent.width)
	y := min(u32(max(rect.y, 0)), state.renderer.extent.height)
	w := min(u32(max(rect.w, 0)), state.renderer.extent.width - x)
	h := min(u32(max(rect.h, 0)), state.renderer.extent.height - y)
	vulkan_set_scissor(r.current_command, x, y, w, h)
}

demo_windows :: proc(ctx: ^mu.Context) {
	@(static) opts := mu.Options{.NO_CLOSE}

	if mu.window(ctx, "Demo Window", {40, 40, 300, 450}, opts) {
		if .ACTIVE in mu.header(ctx, "Window Info") {
			win := mu.get_current_container(ctx)
			mu.layout_row(ctx, {54, -1}, 0)
			mu.label(ctx, "Position:")
			mu.label(ctx, fmt.tprintf("%d, %d", win.rect.x, win.rect.y))
			mu.label(ctx, "Size:")
			mu.label(ctx, fmt.tprintf("%d, %d", win.rect.w, win.rect.h))
		}

		if .ACTIVE in mu.header(ctx, "Window Options") {
			mu.layout_row(ctx, {120, 120, 120}, 0)
			for opt in mu.Opt {
				opt_enabled := opt in opts
				if .CHANGE in mu.checkbox(ctx, fmt.tprintf("%v", opt), &opt_enabled) {
					if opt_enabled {
						opts += {opt}
					} else {
						opts -= {opt}
					}
				}
			}
		}

		if .ACTIVE in mu.header(ctx, "Test Buttons", {.EXPANDED}) {
			mu.layout_row(ctx, {86, -110, -1})
			mu.label(ctx, "Test buttons 1:")
			if .SUBMIT in mu.button(ctx, "Button 1") {fmt.println("Pressed button 1")}
			if .SUBMIT in mu.button(ctx, "Button 2") {fmt.println("Pressed button 2")}
			mu.label(ctx, "Test buttons 2:")
			if .SUBMIT in mu.button(ctx, "Button 3") {fmt.println("Pressed button 3")}
			if .SUBMIT in mu.button(ctx, "Button 4") {fmt.println("Pressed button 4")}
		}

		if .ACTIVE in mu.header(ctx, "Tree and Text", {.EXPANDED}) {
			mu.layout_row(ctx, {140, -1})
			mu.layout_begin_column(ctx)
			if .ACTIVE in mu.treenode(ctx, "Test 1") {
				if .ACTIVE in mu.treenode(ctx, "Test 1a") {
					mu.label(ctx, "Hello")
					mu.label(ctx, "world")
				}
				if .ACTIVE in mu.treenode(ctx, "Test 1b") {
					if .SUBMIT in mu.button(ctx, "Button 1") {fmt.println("Pressed button 1")}
					if .SUBMIT in mu.button(ctx, "Button 2") {fmt.println("Pressed button 2")}
				}
			}
			if .ACTIVE in mu.treenode(ctx, "Test 2") {
				mu.layout_row(ctx, {53, 53})
				if .SUBMIT in mu.button(ctx, "Button 3") {fmt.println("Pressed button 3")}
				if .SUBMIT in mu.button(ctx, "Button 4") {fmt.println("Pressed button 4")}
				if .SUBMIT in mu.button(ctx, "Button 5") {fmt.println("Pressed button 5")}
				if .SUBMIT in mu.button(ctx, "Button 6") {fmt.println("Pressed button 6")}
			}
			if .ACTIVE in mu.treenode(ctx, "Test 3") {
				@(static) checks := [3]bool{true, false, true}
				mu.checkbox(ctx, "Checkbox 1", &checks[0])
				mu.checkbox(ctx, "Checkbox 2", &checks[1])
				mu.checkbox(ctx, "Checkbox 3", &checks[2])
			}
			mu.layout_end_column(ctx)

			mu.layout_begin_column(ctx)
			mu.layout_row(ctx, {-1})
			mu.text(
				ctx,
				"Lorem ipsum dolor sit amet, consectetur adipiscing " +
				"elit. Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus " +
				"ipsum, eu varius magna felis a nulla.",
			)
			mu.layout_end_column(ctx)
		}

		if .ACTIVE in mu.header(ctx, "Background Colour", {.EXPANDED}) {
			mu.layout_row(ctx, {-78, -1}, 68)
			mu.layout_begin_column(ctx)
			{
				mu.layout_row(ctx, {46, -1}, 0)
				mu.label(ctx, "Red:"); u8_slider(ctx, &state.bg.r, 0, 255)
				mu.label(ctx, "Green:"); u8_slider(ctx, &state.bg.g, 0, 255)
				mu.label(ctx, "Blue:"); u8_slider(ctx, &state.bg.b, 0, 255)
			}
			mu.layout_end_column(ctx)

			r := mu.layout_next(ctx)
			mu.draw_rect(ctx, r, state.bg)
			mu.draw_box(ctx, mu.expand_rect(r, 1), ctx.style.colors[.BORDER])
			mu.draw_control_text(
				ctx,
				fmt.tprintf("#%02x%02x%02x", state.bg.r, state.bg.g, state.bg.b),
				r,
				.TEXT,
				{.ALIGN_CENTER},
			)
		}
	}

	if mu.window(ctx, "Style Window", {350, 250, 300, 240}) {
		@(static) colors := [mu.Color_Type]string {
			.TEXT         = "text",
			.BORDER       = "border",
			.WINDOW_BG    = "window bg",
			.TITLE_BG     = "title bg",
			.TITLE_TEXT   = "title text",
			.PANEL_BG     = "panel bg",
			.BUTTON       = "button",
			.BUTTON_HOVER = "button hover",
			.BUTTON_FOCUS = "button focus",
			.BASE         = "base",
			.BASE_HOVER   = "base hover",
			.BASE_FOCUS   = "base focus",
			.SCROLL_BASE  = "scroll base",
			.SCROLL_THUMB = "scroll thumb",
			.SELECTION_BG = "selection bg",
		}

		sw := i32(f32(mu.get_current_container(ctx).body.w) * 0.14)
		mu.layout_row(ctx, {80, sw, sw, sw, sw, -1})
		for label, col in colors {
			mu.label(ctx, label)
			u8_slider(ctx, &ctx.style.colors[col].r, 0, 255)
			u8_slider(ctx, &ctx.style.colors[col].g, 0, 255)
			u8_slider(ctx, &ctx.style.colors[col].b, 0, 255)
			u8_slider(ctx, &ctx.style.colors[col].a, 0, 255)
			mu.draw_rect(ctx, mu.layout_next(ctx), ctx.style.colors[col])
		}
	}
}

u8_slider :: proc(ctx: ^mu.Context, val: ^u8, lo, hi: u8) -> (res: mu.Result_Set) {
	mu.push_id(ctx, uintptr(val))
	@(static) tmp: mu.Real
	tmp = mu.Real(val^)
	res = mu.slider(ctx, &tmp, mu.Real(lo), mu.Real(hi), 0, "%.0f", {.ALIGN_CENTER})
	val^ = u8(tmp)
	mu.pop_id(ctx)
	return
}
