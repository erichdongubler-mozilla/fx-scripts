use std/log

def quote-args-for-debugging []: list<string> -> string {
	$in | each { ['"' $in '"'] | str join } | str join ' '
}

export def "ci dl-reports" [
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	use std/log [] # set up `log` cmd. state

	let args = [--job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/test_info/wptreport.json' --out-dir $in_dir ...$revisions]
	log info $"Downloading reports via `treeherder-dl ($args | quote-args-for-debugging)…"
	treeherder-dl ...$args
}

export def "ci dl-logs" [
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	use std/log [] # set up `log` cmd. state

	treeherder-dl --job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/logs/live_backing.log' --out-dir $in_dir ...$revisions
}

def "ci wptreport-glob" [in_dir: path] {
	[$in_dir "**/wptreport.json"] |
		path join |
		str replace --all '\' '/' | into glob
}

def "ci process-reports" [
	verb: string,
	--remove-old,
	--in-dir: directory = "../wpt/",
	--revisions: list<string>,
	...additional_args
] {
	let in_dir = do {
		let path_sep_chars = [$'\(char path_sep)' '\/'] | uniq
		$in_dir | str replace --regex $"[($path_sep_chars)]$" ""
	}

	if $remove_old {
		try {
			rm -r $in_dir
		}
	}

	ci dl-reports --in-dir $in_dir ...$revisions

	let revision_glob_opts = $revisions | reduce --fold [] {|rev, acc|
		$acc | append [
			"--glob"
			($rev | parse '{_repo}:{hash}' | first | (ci wptreport-glob $"($in_dir)/($in.hash)/") | into string)
		]
	}

	let args = [$verb ...$revision_glob_opts ...$additional_args]
	log info $"Processing reports with `moz-webgpu-cts ($args | quote-args-for-debugging)`…"
	moz-webgpu-cts ...$args
	log info "Done!"
}

export def "ci update-expected" [
	--remove-old,
	--preset: string@"ci process-reports preset",
	--in-dir: directory = "../wpt/",
	--implementation-status: list<string@"ci process-reports implementation-status">,
	...revisions: string,
] {
	use std/log [] # set up `log` cmd. state

	let implementation_status_opts = $implementation_status | reduce --fold [] {|status, acc|
		$acc | append ["--implementation-status" $status]
	}
	ci process-reports update-expected --remove-old=$remove_old --in-dir=$in_dir --revisions=$revisions "--preset" $preset ...$implementation_status_opts 
}

export def "ci migrate" [
	--remove-old,
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	ci process-reports migrate --remove-old=$remove_old --in-dir=$in_dir --revisions=$revisions
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
	--in-dir: directory = "../wpt/",
] {
	use std/log [] # set up `log` cmd. state

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
	--in-dir: directory = "../wpt/",
] {
	use std/log [] # set up `log` cmd. state

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
