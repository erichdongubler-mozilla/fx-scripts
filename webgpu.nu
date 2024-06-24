use std log [debug, info]

export def "webgpu ci dl-reports" [
	--in-dir: string = "../wpt/",
	...revisions: string,
] {
	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/test_info/wptreport.json' --out-dir $in_dir ...$revisions
}

export def "webgpu ci dl-logs" [
	--in-dir: string = "../wpt/",
	...revisions: string,
] {
	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/logs/live_backing.log' --out-dir $in_dir ...$revisions
}

def "webgpu ci wptreport-glob" [in_dir: path] {
	[$in_dir "**/wptreport.json"] |
		path join |
		str replace --all '\' '/' | into glob
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
	let wptreport_file_glob = webgpu ci wptreport-glob $in_dir
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

export def "webgpu ci search wpt by-test-message" [
	term: string,
	--in-dir: string = "../wpt/",
] {
	let files = (ls (webgpu ci wptreport-glob $in_dir) | where type == file) | get name | sort
	let predicate = { $in | default "" | str contains $term }

	$files
		| par-each --keep-order {|file|
			use std
			std log info $"searching ($file)"
			open $file
				| get results
				| where {
					($in.message | do $predicate) or ($in.subtests | any { $in.message | do $predicate })
				}
				| each {
					{ file: $file test: $in }
				}
		}
		| webgpu ci search wpt clean-search-results $in_dir
}

export def "webgpu ci search wpt by-test-name" [
	term: string,
	--in-dir: string = "../wpt/",
] {
	let files = (ls (webgpu ci wptreport-glob $in_dir) | where type == file) | get name | sort

	$files
		| par-each --keep-order {|file|
			open $file
				| get results
				| where { $in.test | str contains $term }
				| each {
					{ file: $file test: $in }
				}
		}
		| webgpu ci search wpt clean-search-results $in_dir
}

def "webgpu ci search wpt clean-search-results" [in_dir: string] {
	flatten
	| update file {
		$in
			| str replace ($in_dir | path expand) ''
			| str replace ([public test_info wptreport.json] | path join) ''
	}
	| flatten
	| each {|entry|
		$entry | try {
			$entry | update test {
				['https://example.com' $in] | str join | url parse | get params | get q
			}
		} catch {
			$entry
		}
	}
}
