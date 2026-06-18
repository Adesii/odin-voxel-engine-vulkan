package utils

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
		if os.is_dir(file.fullpath) {
			continue
		}
		thing := strings.split(file.name, ".")
		defer delete(thing)
		// Check if shader file is newer than the compiled version and only then compile
		if filepath.ext(file.name) != ".slang" {
			fmt.printfln("Skipping non-slang file: %s", file.name)
			continue
		}
		compiled_name := strings.join({destdir, thing[0], ".spirv"}, "")
		defer delete(compiled_name)
		if !os.exists(compiled_name) {
			fmt.printfln("Compiled shader does not exist, compiling: %s", file.name)
			compile_file(thing[0], file.fullpath, destdir)
			continue
		}
		src_mod_time := file.modification_time
		dest_mod_time, err := os.modification_time_by_path(compiled_name)
		if err != nil {
			fmt.printfln(
				"Failed to get modification time for destination file, recompiling: %s",
				err,
			)
			compile_file(thing[0], file.fullpath, destdir)
			continue
		}
		if src_mod_time._nsec > dest_mod_time._nsec {
			fmt.printfln("Source file is newer than destination file, recompiling: %s", file.name)
			compile_file(thing[0], file.fullpath, destdir)
		}
	}
}


compile_file :: proc(filename: string, input_file: string, output_dir: string) {
	shader_name := strings.join({output_dir, filename, ".spirv"}, "")
	defer delete(shader_name)
	reflection_name := strings.join({output_dir, filename, ".json"}, "")
	defer delete(reflection_name)
	profile_string := "glsl_460"
	when ODIN_DEBUG {
		profile_string = strings.join({profile_string, "+SPV_KHR_non_semantic_info"}, "")
		defer delete(profile_string)
	}
	process_info := os.Process_Desc {
		command = []string {
			"slangc",
			"-target",
			"spirv",
			"-profile",
			profile_string,
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
	comp := get_shader_path(shader_name)
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
	path := get_shader_path(shader_name)
	defer delete(path)
	fmt.printfln("Loading shader: %s", path)
	code, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.panicf("Failed to read shader file: %s, at path: %s", err, path)
	}
	return code
}


get_shader_path :: proc(shader_name: string) -> string {
	if strings.ends_with(shader_name, ".slang") {
		return strings.join({"shader_src/", shader_name}, "")
	}
	type := "spirv"
	shader_name := shader_name
	if strings.ends_with(shader_name, ".wgsl") {
		type = "wgsl"
	}
	shader_name = strings.trim_suffix(shader_name, type)
	shader_name = strings.trim_suffix(shader_name, ".")
	comp := strings.join({"shaders/", shader_name, ".", type}, "")
	return comp
}
