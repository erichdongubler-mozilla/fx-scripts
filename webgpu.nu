use std log [debug, info]

export def "ci dl-reports" [
	--in-dir: string = "../wpt/",
	...revisions: string,
] {
	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/test_info/wptreport.json' --out-dir $in_dir ...$revisions
}

export def "ci dl-logs" [
	--in-dir: string = "../wpt/",
	...revisions: string,
] {
	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/logs/live_backing.log' --out-dir $in_dir ...$revisions
}

def "ci wptreport-glob" [in_dir: path] {
	[$in_dir "**/wptreport.json"] |
		path join |
		str replace --all '\' '/' | into glob
}

export def "ci update-expected" [
	--remove-old,
	--preset: string@"ci process-reports preset",
	--in-dir: string = "../wpt/",
    --implementation-status: string@"ci process-reports implementation-status",
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
	ci dl-reports --in-dir $in_dir ...$revisions

	let revision_glob_opts = $revisions | reduce --fold [] {|rev, acc|
		$acc | append [
			"--glob"
			($rev | parse '{_repo}:{hash}' | first | (ci wptreport-glob $"($in_dir)/($in.hash)/") | into string)
		]
	}

	info "Processing reports…"
	moz-webgpu-cts update-expected ...$revision_glob_opts --preset $preset --implementation-status $implementation_status
	info "Done!"
}

def "ci process-reports preset" [] {
	[
		"new-fx"
		"same-fx"
		"merge"
		"reset-contradictory"
		"reset-all"
	]
}

def "ci process-reports implementation-status" [] {
	[
		"implementing"
		"backlog"
		"not-implementing"
	]
}

export def "ci search wpt by-test-message" [
	term: string,
	--in-dir: string = "../wpt/",
] {
	let files = (ls (ci wptreport-glob $in_dir) | where type == file) | get name | sort
	let predicate = { $in | default "" | str contains $term }

	$files
		| par-each --keep-order {|file|
			use std
			log info $"searching ($file)"
			open $file
				| get results
				| where {
					($in.message | do $predicate) or ($in.subtests | any { $in.message | do $predicate })
				}
				| each {
					{ file: $file test: $in }
				}
		}
		| ci search wpt clean-search-results $in_dir
}

export def "ci search wpt by-test-name" [
	term: string,
	--in-dir: string = "../wpt/",
] {
	let files = (ls (ci wptreport-glob $in_dir) | where type == file) | get name | sort

	$files
		| par-each --keep-order {|file|
			let json = open $file
			if $json == null {
				return []
			}
			$json
				| get results
				| where { $in.test | str contains $term }
				| each {
					{ file: $file test: $in }
				}
		}
		| ci search wpt clean-search-results $in_dir
}

def "ci search wpt clean-search-results" [in_dir: string] {
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
