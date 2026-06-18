package utils

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

FileWatcher :: struct {
	filepath:      string,
	last_modified: time.Time,
	callback:      proc(args: string),
}

watchers: [dynamic]FileWatcher


add_file_watcher :: proc(filepath: string, callback: proc(args: string)) {
	for watcher in &watchers {
		if watcher.filepath == filepath {
			return
		}
	}
	last_modified, err := os.modification_time_by_path(filepath)
	if err != nil {
		fmt.println("Error getting modification time for file: ", filepath, " - ", err)
		return
	}
	watcher := FileWatcher {
		filepath      = strings.clone(filepath),
		last_modified = last_modified,
		callback      = callback,
	}

	append_elem(&watchers, watcher)
}

check_file_watchers :: proc() {
	for i in 0 ..< len(watchers) {
		watcher := &watchers[i]
		last_modified, err := os.modification_time_by_path(watcher.filepath)
		if err != nil {
			fmt.println("Error getting modification time for file: ", watcher.filepath, " - ", err)
			continue
		}
		if last_modified._nsec > watcher.last_modified._nsec {
			watcher.last_modified = last_modified
			watcher.callback(watcher.filepath)
		}
	}
}

destroy_file_watchers :: proc() {
	for w in &watchers {
		delete(w.filepath)
	}
	delete(watchers)
}
