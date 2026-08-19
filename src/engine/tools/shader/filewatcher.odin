package shader_tools

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

File_Watcher_Callback :: proc(data: rawptr, filepath: string)

File_Watcher :: struct {
	filepath:      string,
	last_modified: time.Time,
	callback:      File_Watcher_Callback,
	data:          rawptr,
}

Watcher_Set :: struct {
	watchers: [dynamic]File_Watcher,
}

add_file_watcher :: proc(
	set: ^Watcher_Set,
	filepath: string,
	callback: File_Watcher_Callback,
	data: rawptr = nil,
) {
	for watcher in set.watchers {
		if watcher.filepath == filepath {
			return
		}
	}
	last_modified, err := os.modification_time_by_path(filepath)
	if err != nil {
		fmt.println("Error getting modification time for file: ", filepath, " - ", err)
		return
	}
	append(
		&set.watchers,
		File_Watcher {
			filepath = strings.clone(filepath),
			last_modified = last_modified,
			callback = callback,
			data = data,
		},
	)
}

check_file_watchers :: proc(set: ^Watcher_Set) {
	for &watcher in set.watchers {
		last_modified, err := os.modification_time_by_path(watcher.filepath)
		if err != nil {
			fmt.println("Error getting modification time for file: ", watcher.filepath, " - ", err)
			continue
		}
		if last_modified._nsec > watcher.last_modified._nsec {
			watcher.last_modified = last_modified
			watcher.callback(watcher.data, watcher.filepath)
		}
	}
}

destroy_file_watchers :: proc(set: ^Watcher_Set) {
	for watcher in set.watchers {
		delete(watcher.filepath)
	}
	delete(set.watchers)
	set^ = {}
}
