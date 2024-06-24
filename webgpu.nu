use std log [debug, info]

export def "webgpu ci dl-reports" [
	--in-dir: string = "../wpt/",
	...revisions: string,
] {
	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/test_info/wptreport.json' --out-dir $in_dir ...$revisions
}

export def "webgpu ci update-expected" [
	--remove-old,
	--preset: string@"webgpu ci process-reports preset",
	--in-dir: string = "../wpt/",
	...revisions: string,
] {
	if (which ruplacer | is-empty) {
		error make --unspanned {
			msg: "`ruplacer` binary not found in `$PATH`, bailing"
		}
	}

	let in_dir = do {
		let path_sep_chars = [$'\(char path_sep)' '\/'] | uniq
		$in_dir | str replace --regex $"[($path_sep_chars)]$" ""
	}

	if $remove_old {
		try {
			rm -r $in_dir
		}
	}

	info "Downloading reports…"
	webgpu ci dl-reports --in-dir $in_dir ...$revisions

	debug "Deleting empty reports…"
	let wptreport_file_glob = [$in_dir "**/*wptreport.json"] |
		path join |
		str replace --all '\' '/' | into glob
	let empty_deleted = ls $wptreport_file_glob
		| filter {|entry| $entry.size == 0B }
		| each {|entry|
			rm $entry.name; $entry.name
		}
	for $entry in $empty_deleted {
		debug (["  " ($entry)] | str join)
	}

	info "Processing reports…"
	moz-webgpu-cts update-expected --glob ($wptreport_file_glob | into string) --preset $preset
	info "Done!"
}

def "webgpu ci process-reports preset" [] {
	[
		"new-fx"
		"same-fx"
		"merge"
		"reset-contradictory"
		"reset-all"
	]
}
