package main

import intr "base:intrinsics"

import "core:fmt"
import "core:math/linalg"

import utils "utils"
import mu "vendor:microui"
import "vendor:wgpu"

BUFFER_SIZE :: 16384

microui_ctx :: struct {
	module:             wgpu.ShaderModule,
	atlas_texture:      wgpu.Texture,
	atlas_texture_view: wgpu.TextureView,
	pipeline_layout:    wgpu.PipelineLayout,
	pipeline:           wgpu.RenderPipeline,
	const_buffer:       wgpu.Buffer,
	tex_buffer:         wgpu.Buffer,
	vertex_buffer:      wgpu.Buffer,
	color_buffer:       wgpu.Buffer,
	index_buffer:       wgpu.Buffer,
	sampler:            wgpu.Sampler,
	bind_group_layout:  wgpu.BindGroupLayout,
	bind_group:         wgpu.BindGroup,
	curr_encoder:       wgpu.CommandEncoder,
	curr_pass:          wgpu.RenderPassEncoder,
	curr_texture:       wgpu.SurfaceTexture,
	curr_view:          wgpu.TextureView,
	tex_buf:            [BUFFER_SIZE * 8]f32,
	vert_buf:           [BUFFER_SIZE * 8]f32,
	color_buf:          [BUFFER_SIZE * 16]u8,
	index_buf:          [BUFFER_SIZE * 6]u32,
	prev_buf_idx:       u32,
	buf_idx:            u32,
}

r_on_adapter_and_device :: proc() {
	r := &state.renderer

	r.const_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&{
			label = "Constant buffer",
			usage = {.Uniform, .CopyDst},
			size = size_of(matrix[4, 4]f32),
		},
	)

	r.atlas_texture = wgpu.DeviceCreateTexture(
		state.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT, 1},
			format = .R8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	r.atlas_texture_view = wgpu.TextureCreateView(r.atlas_texture, nil)

	r.sampler = wgpu.DeviceCreateSampler(
		state.device,
		&{
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			magFilter = .Nearest,
			minFilter = .Nearest,
			mipmapFilter = .Nearest,
			lodMinClamp = 0,
			lodMaxClamp = 32,
			compare = .Undefined,
			maxAnisotropy = 1,
		},
	)

	r.vertex_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&{label = "Vertex Buffer", usage = {.Vertex, .CopyDst}, size = size_of(r.vert_buf)},
	)

	r.tex_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&{label = "Texture Buffer", usage = {.Vertex, .CopyDst}, size = size_of(r.tex_buf)},
	)

	r.color_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&{label = "Color Buffer", usage = {.Vertex, .CopyDst}, size = size_of(r.color_buf)},
	)

	r.index_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&{label = "Index Buffer", usage = {.Index, .CopyDst}, size = size_of(r.index_buf)},
	)

	r.bind_group_layout = wgpu.DeviceCreateBindGroupLayout(
		state.device,
		&{
			entryCount = 3,
			entries = raw_data(
				[]wgpu.BindGroupLayoutEntry {
					{binding = 0, visibility = {.Fragment}, sampler = {type = .Filtering}},
					{
						binding = 1,
						visibility = {.Fragment},
						texture = {
							sampleType = .Float,
							viewDimension = ._2D,
							multisampled = false,
						},
					},
					{
						binding = 2,
						visibility = {.Vertex},
						buffer = {type = .Uniform, minBindingSize = size_of(matrix[4, 4]f32)},
					},
				},
			),
		},
	)

	r.bind_group = wgpu.DeviceCreateBindGroup(
		state.device,
		&{
			layout = r.bind_group_layout,
			entryCount = 3,
			entries = raw_data(
				[]wgpu.BindGroupEntry {
					{binding = 0, sampler = r.sampler},
					{binding = 1, textureView = r.atlas_texture_view},
					{binding = 2, buffer = r.const_buffer, size = size_of(matrix[4, 4]f32)},
				},
			),
		},
	)
	ui_shader := utils.load_shader("ui_shader")
	defer delete(ui_shader)
	r.module = wgpu.DeviceCreateShaderModule(
		state.device,
		&{nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = ui_shader}},
	)

	r.pipeline_layout = wgpu.DeviceCreatePipelineLayout(
		state.device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &r.bind_group_layout},
	)
	r.pipeline = wgpu.DeviceCreateRenderPipeline(
		state.device,
		&{
			layout = r.pipeline_layout,
			vertex = {
				module = r.module,
				entryPoint = "vs_main",
				bufferCount = 3,
				buffers = raw_data(
					[]wgpu.VertexBufferLayout {
						{
							stepMode = .Vertex,
							arrayStride = 8,
							attributeCount = 1,
							attributes = &wgpu.VertexAttribute {
								format = .Float32x2,
								shaderLocation = 0,
							},
						},
						{
							stepMode = .Vertex,
							arrayStride = 8,
							attributeCount = 1,
							attributes = &wgpu.VertexAttribute {
								format = .Float32x2,
								shaderLocation = 1,
							},
						},
						{
							stepMode = .Vertex,
							arrayStride = 4,
							attributeCount = 1,
							attributes = &wgpu.VertexAttribute {
								format = .Uint32,
								shaderLocation = 2,
							},
						},
					},
				),
			},
			fragment = &{
				module = r.module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = .BGRA8Unorm,
					blend = &{
						alpha = {
							srcFactor = .SrcAlpha,
							dstFactor = .OneMinusSrcAlpha,
							operation = .Add,
						},
						color = {
							srcFactor = .SrcAlpha,
							dstFactor = .OneMinusSrcAlpha,
							operation = .Add,
						},
					},
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList, cullMode = .None},
			multisample = {count = 1, mask = 0xFFFFFFFF},
		},
	)


	wgpu.QueueWriteTexture(
		state.queue,
		&{texture = r.atlas_texture},
		&mu.default_atlas_alpha,
		mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT,
		&{bytesPerRow = mu.DEFAULT_ATLAS_WIDTH, rowsPerImage = mu.DEFAULT_ATLAS_HEIGHT},
		&{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT, 1},
	)

	r_write_consts()


}


r_write_consts :: proc() {
	r := &state.renderer

	// Transformation matrix to convert from screen to device pixels and scale based on DPI.
	dpi := get_dpi()
	width, height := get_window_size()
	fw, fh := f32(width), f32(height)
	transform := linalg.matrix_ortho3d(0, fw, fh, 0, -1, 1) * linalg.matrix4_scale(dpi)

	// fmt.printfln("Transform matrix: %v", transform)

	wgpu.QueueWriteBuffer(state.queue, r.const_buffer, 0, &transform, size_of(transform))
}

r_bind :: proc() {
	r := &state.renderer

	wgpu.RenderPassEncoderSetPipeline(r.curr_pass, r.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(r.curr_pass, 0, r.bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(r.curr_pass, 0, r.vertex_buffer, 0, size_of(r.vert_buf))
	wgpu.RenderPassEncoderSetVertexBuffer(r.curr_pass, 1, r.tex_buffer, 0, size_of(r.tex_buf))
	wgpu.RenderPassEncoderSetVertexBuffer(r.curr_pass, 2, r.color_buffer, 0, size_of(r.color_buf))
	wgpu.RenderPassEncoderSetIndexBuffer(
		r.curr_pass,
		r.index_buffer,
		.Uint32,
		0,
		size_of(r.index_buf),
	)
}

r_flush :: proc() {
	r := &state.renderer

	if r.buf_idx == 0 || r.buf_idx == r.prev_buf_idx {return}

	delta := uint(r.buf_idx - r.prev_buf_idx)
	wgpu.RenderPassEncoderDrawIndexed(r.curr_pass, u32(delta * 6), 1, r.prev_buf_idx * 6, 0, 0)

	r.prev_buf_idx = r.buf_idx
}

r_full_flush :: proc() {
	r := &state.renderer

	r_submit()

	r.buf_idx = 0
	r.prev_buf_idx = 0

	r.curr_pass = wgpu.CommandEncoderBeginRenderPass(
		r.curr_encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = r.curr_view,
				loadOp = .Load,
				storeOp = .Store,
			},
		},
	)

	r_bind()
}

r_submit :: proc() {
	r := &state.renderer

	r_flush()

	r_write_consts()
	wgpu.QueueWriteBuffer(
		state.queue,
		r.vertex_buffer,
		0,
		&r.vert_buf,
		uint(r.buf_idx * 8 * size_of(f32)),
	)
	wgpu.QueueWriteBuffer(
		state.queue,
		r.tex_buffer,
		0,
		&r.tex_buf,
		uint(r.buf_idx * 8 * size_of(f32)),
	)
	wgpu.QueueWriteBuffer(state.queue, r.color_buffer, 0, &r.color_buf, uint(r.buf_idx * 16))
	wgpu.QueueWriteBuffer(
		state.queue,
		r.index_buffer,
		0,
		&r.index_buf,
		uint(r.buf_idx * 6 * size_of(u32)),
	)

	wgpu.RenderPassEncoderEnd(r.curr_pass)
	wgpu.RenderPassEncoderRelease(r.curr_pass)
}
r_clear :: proc(color: mu.Color) -> bool {
	r := &state.renderer

	r.buf_idx = 0
	r.prev_buf_idx = 0


	r.curr_pass = wgpu.CommandEncoderBeginRenderPass(
		r.curr_encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = raw_data(
				[]wgpu.RenderPassColorAttachment {
					{
						view = r.curr_view,
						loadOp = .Load,
						storeOp = .Store,
						clearValue = {
							f64(color.r) / 255,
							f64(color.g) / 255,
							f64(color.b) / 255,
							0,
						},
						depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					},
				},
			),
		},
	)

	r_bind()

	return true
}

r_render :: proc() {
	r := &state.renderer
	if !r_clear(state.bg) {
		return
	}
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
	r_submit()
}

push_quad :: proc(dst, src: mu.Rect, color: mu.Color) #no_bounds_check {
	r := &state.renderer

	if (r.buf_idx == BUFFER_SIZE) {
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
	r := &state.renderer
	r_flush()

	x := min(u32(rect.x), state.config.width)
	y := min(u32(rect.y), state.config.height)
	w := min(u32(rect.w), state.config.width - x)
	h := min(u32(rect.h), state.config.height - y)
	wgpu.RenderPassEncoderSetScissorRect(r.curr_pass, x, y, w, h)
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
				state := opt in opts
				if .CHANGE in mu.checkbox(ctx, fmt.tprintf("%v", opt), &state) {
					if state {
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
