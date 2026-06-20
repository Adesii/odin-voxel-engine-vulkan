package utils

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"


entry_point :: struct {
	name:              string,
	thread_group_size: Maybe([3]int),
}

descriptor_slot :: struct {
	name: string,
	slot: int,
}

struct_definition :: struct {
	name:     string,
	type_obj: json.Object,
}

json_get_string :: proc(obj: json.Object, key: string) -> string {
	value, exists := obj[key]
	if !exists {
		return ""
	}

	#partial switch v in value {
	case json.String:
		return string(v)
	}

	return ""
}

json_get_int :: proc(obj: json.Object, key: string) -> int {
	value, exists := obj[key]
	if !exists {
		return 0
	}

	#partial switch v in value {
	case json.Integer:
		return int(v)
	case json.Float:
		return int(v)
	}

	return 0
}

json_get_object :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	value, exists := obj[key]
	if !exists {
		return json.Object{}, false
	}

	#partial switch v in value {
	case json.Object:
		return v, true
	}

	return json.Object{}, false
}

json_get_array :: proc(obj: json.Object, key: string) -> (json.Array, bool) {
	value, exists := obj[key]
	if !exists {
		return nil, false
	}

	#partial switch v in value {
	case json.Array:
		return v, true
	}

	return nil, false
}

append_unique_descriptor_slot :: proc(slots: ^[dynamic]descriptor_slot, name: string, slot: int) {
	for existing in slots^ {
		if existing.name == name {
			return
		}
	}

	append(slots, descriptor_slot{name = name, slot = slot})
}

append_unique_struct_definition :: proc(
	struct_defs: ^[dynamic]struct_definition,
	name: string,
	type_obj: json.Object,
) {
	if name == "" {
		return
	}

	for existing in struct_defs^ {
		if existing.name == name {
			return
		}
	}

	append(struct_defs, struct_definition{name = name, type_obj = type_obj})
}

find_struct_definition :: proc(struct_defs: []struct_definition, name: string) -> (int, bool) {
	for i in 0 ..< len(struct_defs) {
		if struct_defs[i].name == name {
			return i, true
		}
	}

	return 0, false
}

append_unique_name :: proc(names: ^[dynamic]string, name: string) {
	if name == "" {
		return
	}

	for existing in names^ {
		if existing == name {
			return
		}
	}

	append(names, name)
}

collect_type_definitions :: proc(type_obj: json.Object, struct_defs: ^[dynamic]struct_definition) {
	kind := json_get_string(type_obj, "kind")

	switch kind {
	case "scalar":
		return
	case "vector", "matrix", "array":
		if elem, exists := json_get_object(type_obj, "elementType"); exists {
			collect_type_definitions(elem, struct_defs)
		}
	case "struct":
		append_unique_struct_definition(struct_defs, json_get_string(type_obj, "name"), type_obj)
		if fields, exists := json_get_array(type_obj, "fields"); exists {
			for field_val in fields {
				field := field_val.(json.Object)
				if field_type, ok := json_get_object(field, "type"); ok {
					collect_type_definitions(field_type, struct_defs)
				}
			}
		}
	case "resource":
		if result_type, exists := json_get_object(type_obj, "resultType"); exists {
			collect_type_definitions(result_type, struct_defs)
		}
	case "pointer":
		value, exists := type_obj["valueType"]
		if !exists {
			return
		}

		#partial switch v in value {
		case json.Object:
			collect_type_definitions(v, struct_defs)
		}

		default: if
		elem, exists := json_get_object(type_obj, "elementType"); exists {
			collect_type_definitions(elem, struct_defs)
		}
		if result_type, exists := json_get_object(type_obj, "resultType"); exists {
			collect_type_definitions(result_type, struct_defs)
		}
	}
}

collect_named_dependencies :: proc(type_obj: json.Object, deps: ^[dynamic]string) {
	kind := json_get_string(type_obj, "kind")

	switch kind {
	case "vector", "matrix", "array":
		if elem, exists := json_get_object(type_obj, "elementType"); exists {
			collect_named_dependencies(elem, deps)
		}
	case "struct":
		append_unique_name(deps, json_get_string(type_obj, "name"))
		if fields, exists := json_get_array(type_obj, "fields"); exists {
			for field_val in fields {
				field := field_val.(json.Object)
				if field_type, ok := json_get_object(field, "type"); ok {
					collect_named_dependencies(field_type, deps)
				}
			}
		}
	case "resource":
		if result_type, exists := json_get_object(type_obj, "resultType"); exists {
			collect_named_dependencies(result_type, deps)
		}
	case "pointer":
		value, exists := type_obj["valueType"]
		if !exists {
			return
		}

		#partial switch v in value {
		case json.Object:
			collect_named_dependencies(v, deps)
		case json.String:
			append_unique_name(deps, string(v))
		}
	}
}

get_odin_type :: proc(type_obj: json.Object, known_structs: []struct_definition) -> string {
	kind := json_get_string(type_obj, "kind")

	switch kind {
	case "scalar":
		switch json_get_string(type_obj, "scalarType") {
		case "float16":
			return "f16"
		case "float32":
			return "f32"
		case "float64":
			return "f64"
		case "uint8":
			return "u8"
		case "uint16":
			return "u16"
		case "uint32":
			return "u32"
		case "uint64":
			return "u64"
		case "int8":
			return "i8"
		case "int16":
			return "i16"
		case "int32":
			return "i32"
		case "int64":
			return "i64"
		case "bool":
			return "bool"
		}
	case "vector", "array":
		count := json_get_int(type_obj, "elementCount")
		if elem, exists := json_get_object(type_obj, "elementType"); exists {
			return fmt.tprintf("[%d]%s", count, get_odin_type(elem, known_structs))
		}
	case "matrix":
		rows := json_get_int(type_obj, "rowCount")
		cols := json_get_int(type_obj, "columnCount")
		if elem, exists := json_get_object(type_obj, "elementType"); exists {
			if (cols % 4 != 0) {
				return fmt.tprintf(
					"[%d][%d]%s",
					rows,
					cols + 1,
					get_odin_type(elem, known_structs),
				)
			}
			return fmt.tprintf("matrix[%d,%d]%s", rows, cols, get_odin_type(elem, known_structs))
		}
	case "struct":
		name := json_get_string(type_obj, "name")
		if name != "" {
			return name
		}
	case "pointer":
		value, exists := type_obj["valueType"]
		if !exists {
			return "rawptr"
		}

		#partial switch v in value {
		case json.Object:
			return fmt.tprintf("^%s", get_odin_type(v, known_structs))
		case json.String:
			value_name := string(v)
			if _, ok := find_struct_definition(known_structs, value_name); ok {
				return fmt.tprintf("^%s", value_name)
			}
			return "u64"
		}
	case "resource":
		if result_type, exists := json_get_object(type_obj, "resultType"); exists {
			base_shape := json_get_string(type_obj, "baseShape")
			switch base_shape {
			case "structuredBuffer", "constantBuffer":
				return get_odin_type(result_type, known_structs)
			}
		}
	}

	return "u64"
}

record_binding :: proc(
	name: string,
	binding_obj: json.Object,
	uniform_buffer_size: ^int,
	descriptor_slots: ^[dynamic]descriptor_slot,
) {
	switch json_get_string(binding_obj, "kind") {
	case "uniform":
		offset := json_get_int(binding_obj, "offset")
		size := json_get_int(binding_obj, "size")
		if offset + size > uniform_buffer_size^ {
			uniform_buffer_size^ = offset + size
		}
		append_unique_descriptor_slot(descriptor_slots, name, 0)
	case "descriptorTableSlot":
		append_unique_descriptor_slot(descriptor_slots, name, json_get_int(binding_obj, "index"))
	}
}

emit_struct_definition :: proc(
	sb: ^strings.Builder,
	struct_defs: []struct_definition,
	struct_name: string,
	emitted: ^[dynamic]string,
	in_progress: ^[dynamic]string,
) {
	for name in emitted^ {
		if name == struct_name {
			return
		}
	}

	for name in in_progress^ {
		if name == struct_name {
			return
		}
	}

	index, exists := find_struct_definition(struct_defs, struct_name)
	if !exists {
		return
	}

	append(in_progress, struct_name)

	struct_obj := struct_defs[index].type_obj
	if fields, ok := json_get_array(struct_obj, "fields"); ok {
		deps := make([dynamic]string, 0, context.temp_allocator)
		for field_val in fields {
			field := field_val.(json.Object)
			if field_type, field_ok := json_get_object(field, "type"); field_ok {
				collect_named_dependencies(field_type, &deps)
			}
		}

		for dep_name in deps {
			if dep_name != struct_name {
				emit_struct_definition(sb, struct_defs, dep_name, emitted, in_progress)
			}
		}
	}

	resize(in_progress, len(in_progress^) - 1)

	fmt.sbprintf(sb, "%s :: struct #align(16) {{\n", struct_name)
	current_offset := 0

	if fields, ok := json_get_array(struct_obj, "fields"); ok {
		for field_val in fields {
			field := field_val.(json.Object)
			field_name := json_get_string(field, "name")
			field_type, field_ok := json_get_object(field, "type")
			if !field_ok {
				continue
			}

			if binding, binding_ok := json_get_object(field, "binding");
			   binding_ok && json_get_string(binding, "kind") == "uniform" {
				offset := json_get_int(binding, "offset")
				size := json_get_int(binding, "size")

				if offset > current_offset {
					fmt.sbprintf(sb, "\t_pad_%d: [%d]u8,\n", offset, offset - current_offset)
				}

				fmt.sbprintf(
					sb,
					"\t%s: %s, // offset: %d, size: %d\n",
					field_name,
					get_odin_type(field_type, struct_defs),
					offset,
					size,
				)
				current_offset = offset + size
			} else {
				fmt.sbprintf(sb, "\t%s: %s,\n", field_name, get_odin_type(field_type, struct_defs))
			}
		}
	}

	fmt.sbprintf(sb, "}\n\n")
	append(emitted, struct_name)
}

generate_shader_bindings :: proc(
	json_path: string,
	output_file_name: string,
	output_package_name: string,
) {
	data, ok := os.read_entire_file_from_path(json_path, allocator = context.allocator)
	if ok != nil {
		fmt.eprintln("Failed to read reflection file:", json_path)
		return
	}
	defer delete(data)

	json_value, err := json.parse(data)
	if err != .None {
		fmt.eprintln("Failed to parse reflection JSON:", err)
		return
	}
	defer json.destroy_value(json_value)

	root_obj := json_value.(json.Object)

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	base_name := filepath.short_stem(json_path)
	prefix := strings.to_upper(base_name)

	fmt.sbprintf(&sb, "// Automatically generated by Slang Reflector utility. DO NOT EDIT.\n")
	fmt.sbprintf(&sb, "package %s\n\n", output_package_name)

	entry_points := make([dynamic]entry_point, 0, context.temp_allocator)
	struct_defs := make([dynamic]struct_definition, 0, context.temp_allocator)
	descriptor_slots := make([dynamic]descriptor_slot, 0, context.temp_allocator)
	uniform_buffer_size := 0

	if params, exists := json_get_array(root_obj, "parameters"); exists {
		for param_val in params {
			param := param_val.(json.Object)
			param_name := json_get_string(param, "name")

			if type_obj, ok := json_get_object(param, "type"); ok {
				collect_type_definitions(type_obj, &struct_defs)
			}

			if binding_obj, ok := json_get_object(param, "binding"); ok {
				record_binding(param_name, binding_obj, &uniform_buffer_size, &descriptor_slots)
			}
		}
	}

	if entry_points_val, exists := json_get_array(root_obj, "entryPoints"); exists {
		for entry_val in entry_points_val {
			entry := entry_val.(json.Object)
			entry_meta := entry_point {
				name = json_get_string(entry, "name"),
			}

			if group_size, ok := json_get_array(entry, "threadGroupSize");
			   ok && len(group_size) >= 3 {
				entry_meta.thread_group_size = [3]int {
					int(group_size[0].(json.Float)),
					int(group_size[1].(json.Float)),
					int(group_size[2].(json.Float)),
				}
			}

			if bindings, ok := json_get_array(entry, "bindings"); ok {
				for binding_val in bindings {
					binding := binding_val.(json.Object)
					binding_name := json_get_string(binding, "name")
					if binding_obj, binding_ok := json_get_object(binding, "binding"); binding_ok {
						record_binding(
							binding_name,
							binding_obj,
							&uniform_buffer_size,
							&descriptor_slots,
						)
					}
				}
			}

			append(&entry_points, entry_meta)
		}
	}

	emitted := make([dynamic]string, 0, context.temp_allocator)
	in_progress := make([dynamic]string, 0, context.temp_allocator)
	for struct_def in struct_defs {
		emit_struct_definition(&sb, struct_defs[:], struct_def.name, &emitted, &in_progress)
	}

	fmt.sbprintf(&sb, "// --- %s Pipeline Constants ---\n", prefix)
	for entry in entry_points {
		fmt.sbprintf(
			&sb,
			"%s_ENTRY_POINT :: \"%s\"\n",
			strings.join({prefix, strings.to_upper(entry.name)}, "_"),
			entry.name,
		)

		if entry.thread_group_size != nil {
			group := entry.thread_group_size.([3]int)
			fmt.sbprintf(&sb, "%s_THREAD_X :: %d\n", prefix, group[0])
			fmt.sbprintf(&sb, "%s_THREAD_Y :: %d\n", prefix, group[1])
			fmt.sbprintf(&sb, "%s_THREAD_Z :: %d\n", prefix, group[2])
		}
	}

	if uniform_buffer_size > 0 {
		fmt.sbprintf(&sb, "%s_UNIFORM_BUFFER_SIZE :: %d\n", prefix, uniform_buffer_size)
	}

	for slot in descriptor_slots {
		fmt.sbprintf(&sb, "%s_BINDING_%s :: %d\n", prefix, strings.to_upper(slot.name), slot.slot)
	}

	output_directory := fmt.tprintf("src/shaders/%s", output_package_name)
	if !os.is_dir(output_directory) && os.make_directory_all(output_directory) != nil {
		fmt.eprintln("Failed to create output directory for shader bindings")
		return
	}

	output_odin_path, alloc_err := filepath.join(
		{output_directory, strings.join({output_file_name, ".odin"}, "")},
		allocator = context.allocator,
	)
	if alloc_err != nil {
		fmt.eprintln("Failed to build output file path:", alloc_err)
		return
	}
	defer delete(output_odin_path)

	generated_source := strings.clone(strings.to_string(sb), context.allocator)
	defer delete(generated_source)

	if write_err := os.write_entire_file(output_odin_path, data = generated_source);
	   write_err != nil {
		fmt.eprintln("Failed to write output file:", output_odin_path, write_err)
	}
}

main :: proc() {
	compile("shader_src/", "shaders/")

	iter, err := os.read_all_directory_by_path("shaders/", context.allocator)
	if err != nil {
		fmt.eprintln("Failed to read shaders directory for binding generation:", err)
		return
	}
	defer os.file_info_slice_delete(iter, context.allocator)

	for file in iter {
		if os.is_dir(file.fullpath) {
			continue
		}

		if filepath.ext(file.name) != ".json" {
			continue
		}

		base_name := filepath.short_stem(file.name)
		package_name := strings.to_lower(base_name)
		output_name := strings.join({base_name, "_shader"}, "")
		generate_shader_bindings(
			fmt.tprintf("shaders/%s.json", base_name),
			package_name,
			output_name,
		)
	}

	fmt.println("Successfully generated bindings!")
	free_all(context.temp_allocator)
}
