package utils

import "core:fmt"
import "core:os"
import "core:strings"
compile :: proc(srcdir: string, destdir: string) {
	fmt.printfln("Starting Compilation...")

	if !os.is_dir(srcdir) || !os.is_dir(destdir) {
		fmt.printfln("One of the provided arguments is not a directory")
		return
	}

	// files := strings.builder_make()
	fileinfos, err := os.read_all_directory_by_path(srcdir, context.allocator)
	defer os.file_info_slice_delete(fileinfos, context.allocator)
	if err != nil {
		fmt.panicf("Failed to read directory: %s", err)
	}
	for file in &fileinfos {
		fmt.printfln("Found File: %s", file.fullpath)
		thing := strings.split(file.name, ".")
		defer delete(thing)
		compile_file(thing[0], file.fullpath, destdir)
	}
}


compile_file :: proc(filename: string, input_file: string, output_dir: string) {
	shader_name := strings.join({output_dir, filename, ".spirv"}, "")
	defer delete(shader_name)
	reflection_name := strings.join({output_dir, filename, ".json"}, "")
	defer delete(reflection_name)
	process_info := os.Process_Desc {
		command = []string {
			"slangc",
			"-target",
			"spirv",
			"-profile",
			"glsl_460",
			"-reflection-json",
			reflection_name,
			"-o",
			shader_name,
			"--",
			input_file,
		},
		stdout  = os.stdout,
		stderr  = os.stderr,
		stdin   = os.stdin,
	}
	fmt.printfln("Starting Process: %s", process_info.command)
	process, err2 := os.process_start(process_info)
	if err2 != nil {
		fmt.panicf("Failed to start process: %s", err2)
	}
	status, err3 := os.process_wait(process)
	if err3 != nil {
		fmt.panicf("Compilation Failed!: %s", err3)
	}
	fmt.printfln("Compilation Complete!")
}

load_shader :: proc(shader_name: string) -> string {
	type := "wgsl"
	shader_name := shader_name
	if (strings.ends_with(shader_name, ".spirv")) {
		type = "spirv"
		shader_name = strings.trim_suffix(shader_name, ".spirv")
	}
	comp := strings.join({"shaders/", shader_name, ".", type}, "")
	defer delete(comp)
	fmt.printfln("Loading shader: %s", comp)
	code, err := os.read_entire_file(comp, context.allocator)
	defer delete(code)
	if err != nil {
		fmt.panicf("Failed to read shader file: %s\n", err)
	}
	cloned := strings.clone_from_bytes(code)
	return cloned
}

load_shader_bytes :: proc(shader_name: string) -> []byte {
	type := "wgsl"
	shader_name := shader_name
	if strings.ends_with(shader_name, ".spirv") {
		type = "spirv"
		shader_name = strings.trim_suffix(shader_name, ".spirv")
	}
	comp := strings.join({"shaders/", shader_name, ".", type}, "")
	defer delete(comp)
	fmt.printfln("Loading shader: %s", comp)
	code, err := os.read_entire_file(comp, context.allocator)
	if err != nil {
		fmt.panicf("Failed to read shader file: %s\n", err)
	}
	return code
}
