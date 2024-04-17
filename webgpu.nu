export def "webgpu ci dl-reports" [
	--in-dir: string,
	...revisions: string,
] {
	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --max-parallel 50 --artifact 'public/test_info/wptreport.json' --out-dir $in_dir ...$revisions
}

export def "webgpu ci process-reports" [
	--remove-old,
	--preset: string,
	--in-dir: string = "./wpt/",
	...revisions: string,
] {
	use std log [debug, info]

	alias debug = info

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
	let empty_deleted = ls wpt/**/*wptreport.json |
		filter {|entry| $entry.size == 0B } |
		each {|entry|
			rm $entry.name; $entry.name
		}
	for $entry in $empty_deleted {
		debug (["  " ($entry)] | str join)
	}

	info "Processing reports…"
	moz-webgpu-cts process-reports --glob ([$in_dir "/**/*wptreport.json"] | str join) --preset $preset
	info "Done!"
}
