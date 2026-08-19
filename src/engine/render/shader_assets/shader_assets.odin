package shader_assets

import "core:fmt"
import "core:os"
import "core:strings"

source_path :: proc(shader_name: string) -> string {
	return strings.join({"shader_src/", shader_name}, "")
}

compiled_path :: proc(shader_name: string) -> string {
	return strings.join({"shaders/", shader_name}, "")
}

load_bytes :: proc(shader_name: string) -> []byte {
	path := compiled_path(shader_name)
	defer delete(path)
	code, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.panicf("Failed to read shader file: %s, at path: %s", err, path)
	}
	return code
}
