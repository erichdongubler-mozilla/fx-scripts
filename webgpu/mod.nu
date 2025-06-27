use std/log

export def "begin-revendor cts" [
	--bug: oneof<nothing, int, string> = null,
	--revision: oneof<nothing, string> = null,
	--assigned-to: oneof<nothing, string> = null,
] {
	use std/log [] # set up `log` cmd. state

	let mach_cmd = try {
		which ./mach | first | get command
	} catch {
		error make --unspanned {
			msg: "failed to find `./mach` script in the CWD."
		}
	}

	let revision = $revision | default { gh current-mainline-commit gpuweb cts }

	let bug_id = $bug | default {
		const BUGZILLA = path self "../bugzilla.nu"
		use $BUGZILLA

		let assigned_to = $assigned_to | default { bugzilla whoami | get name }
		bug create {
			summary: $"Update WebGPU CTS to upstream \(week of (monday-of-this-week)\)"
			assigned_to: $assigned_to
			blocks: 1863146 # `webgpu-update-cts`
			priority: P1
		} | get id
	}

	let moz_yaml_path = 'dom/webgpu/tests/cts/moz.yaml'
	try {
		^$mach_cmd vendor $moz_yaml_path --revision $revision
	} catch {
		log error $"failed to revendor from `($moz_yaml_path)`"
	}

	$"Bug ($bug_id) - test\(webgpu\): update CTS to ($revision) r=#webgpu-reviewers"
}

export def "begin-revendor wgpu" [
	--bug: oneof<nothing, int, string> = null,
	--revision: oneof<nothing, string> = null,
	--assigned-to: oneof<nothing, string> = null,
] {
	use std/log [] # set up `log` cmd. state

	let mach_cmd = try {
		which ./mach | first | get command
	} catch {
		error make --unspanned {
			msg: "failed to find `./mach` script in the CWD."
		}
	}

	try {
		which cargo-vet | first
	} catch {
		error make --unspanned {
			msg: "failed to find `cargo vet` binary in `PATH`"
		}
	}

	let moz_yaml_path = 'gfx/wgpu_bindings/moz.yaml'
	let moz_yaml = open $moz_yaml_path

	if not (
		$moz_yaml.vendoring.flavor == 'rust' and
		$moz_yaml.vendoring.url == 'https://github.com/gfx-rs/wgpu' and
		true
	) {
		error make --unspanned {
			msg: $"unfamiliar `vendoring.{flavor,url}` at `($moz_yaml_path)`"
		}
	}

	let old_revision = $moz_yaml.origin.revision

	let new_revision = $revision | default {
		let new_revision = ^$mach_cmd vendor --check-for-update $moz_yaml_path

		if $env.LAST_EXIT_CODE != 0 {
			error make --unspanned {
				msg: $"internal error: failed to run `mach vendor --check-for-update ($moz_yaml_path)`"
			}
		}

		let new_revision = $new_revision | parse '{revision} {date}' | get revision
		let new_revision = match ($new_revision | length) {
			0 => {
				error make --unspanned {
					msg: "no new commits detected upstream"
				}
			}
			1 => {
				$new_revision | first
			}
			2 => {
				error make --unspanned {
					msg: "internal error: got more than one "
				}
			}
		}
	}

	let wgpu_crates_to_audit = cargo metadata --format-version 1
		| from json
		| get packages
		| where {
			$in.source != null and $in.source == $'git+($moz_yaml.vendoring.url)?rev=($old_revision)#($old_revision)'
		}
		| select name version

	let bug_id = $bug | default {
		const BUGZILLA = path self "../bugzilla.nu"
		use $BUGZILLA

		mut $assigned_to = $assigned_to | default { bugzilla whoami | get name }

		let bug_id_webgpu_update_wgpu = 1851881

		let update_dependents = try {
			bugzilla bug get --output-fmt full $bug_id_webgpu_update_wgpu | get blocks
		} catch {
			log error $"failed to fetch bugs depending on ($bug_id_webgpu_update_wgpu), bailing"
		}

		bug create {
			summary: $"Update WGPU to upstream \(week of (monday-of-this-week)\)"
			assigned_to: $assigned_to
			blocks: ($update_dependents | append $bug_id_webgpu_update_wgpu)
			priority: P1
		} | get id
	}

	try {
		^$mach_cmd vendor $moz_yaml_path --revision $new_revision
	} catch {
		log error $"failed to revendor from `($moz_yaml_path)`"
	}

	for crate in $wgpu_crates_to_audit {
		let old_dep = $'($crate.version)@git:($old_revision)'
		let new_dep = $'($crate.version)@git:($new_revision)'
		(
			cargo vet certify $crate.name
				--criteria safe-to-deploy
				--accept-all $old_dep $new_dep
		)
	}

	print "You are now ready to run `mach vendor rust`!"

	$"Bug ($bug_id) - build\(webgpu\): update WGPU to ($new_revision) r=#webgpu-reviewers!"
}

def "gh current-mainline-commit" [
	org: string,
	repo: string,
] {
	http get $'https://api.github.com/repos/($org)/($repo)/commits?({ per_page: 1 } | url build-query)'
		| get sha
		| first
}

def monday-of-this-week [] {
	seq date --reverse --days 7
		| into datetime
		| where { ($in | format date "%u") == "1" }
		| first
		| format date "%Y-%m-%d"
}

export def "bug create" [input: record<summary: string>] {
	const BUGZILLA = path self "../bugzilla.nu"
	use $BUGZILLA

	bugzilla bug create ({
		product: 'Core'
		component: 'Graphics: WebGPU'
		version: 'unspecified'
		type: 'task'
	} | merge $input)
}

def quote-args-for-debugging []: list<string> -> string {
	each { $'"($in)"' } | str join ' '
}

export def "ci dl-reports" [
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	use std/log [] # set up `log` cmd. state

	let args = [
		--job-type-re ".*web-platform-tests-webgpu.*"
		--artifact 'public/test_info/wptreport.json'
		--out-dir $in_dir
		...$revisions
	]
	log info $"Downloading reports via `treeherder-dl ($args | quote-args-for-debugging)`…"
	treeherder-dl ...$args
}

export def "ci dl-logs" [
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	use std/log [] # set up `log` cmd. state

	let args = [
		--job-type-re
		".*web-platform-tests-webgpu.*"
		--artifact 'public/logs/live_backing.log'
		--out-dir $in_dir
		...$revisions
	]
	log info $"Downloading logs via `treeherder-dl ($args | quote-args-for-debugging)`…"
	treeherder-dl ...$args
}

export def "ci device-init-fail-regex" []: nothing -> string {
	'WebGPU device failed to initialize'
}

export def "ci meta path-and-line" [
	cts_test_path: string,
]: nothing -> nothing {
	use std/log [] # set up `log` cmd. state

	let parsed = $cts_test_path | parse 'webgpu:{test_group}:{rest}' | first
	let test_group_path_segments = $parsed.test_group | str replace --all ',' '/'

	let test_file_path = (
		$'testing/web-platform/mozilla/meta/webgpu/cts/webgpu/($test_group_path_segments)/cts.https.html.ini'
	)
	log debug $'test_file_path: ($test_file_path | to nuon)'
	if $parsed.rest == '*' {
		echo $test_file_path
	} else {
		let parsed = $parsed | merge ($parsed.rest | parse '{test_name}:{rest}' | first)

		let rg_search_term = (
			$'^\[cts.https.html\?.*?q=webgpu:($parsed.test_group):($parsed.test_name):\*\]$'
		)
		log debug $'rg_search_term: ($rg_search_term | to nuon)'

		let matching_line_nums = rg --line-number $rg_search_term $test_file_path
			| parse '{line_num}:{junk}'
			| get line_num

		let file_edit_args = $matching_line_nums | each { $'($test_file_path):($in)' }

		if ($matching_line_nums | length) != 1 {
			error make --unspanned {
				msg: $'internal error: expected 1 match, got ($matching_line_nums): ($file_edit_args | to nuon --indent 2)'
			}
		}

		let file_edit_arg = $file_edit_args | first
		if $parsed.rest == '*' {
			$file_edit_arg
		} else {
			'TODO'
		}
	}
}

def "ci wptreport-glob" [in_dir: path] {
	$in_dir
		| path join "**/wptreport.json"
		| str replace --all '\' '/' | into glob
}

def "ci process-reports" [
	verb: string,
	--remove-old,
	--in-dir: directory = "../wpt/",
	--revisions: list<string>,
	--dl = true,
	...additional_args
] {
	use std/log [] # set up `log` cmd. state

	let in_dir = do {
		let path_sep_chars = [$'\(char path_sep)' '\/'] | uniq
		$in_dir | str replace --regex $"[($path_sep_chars)]$" ""
	}

	if $remove_old {
		try {
			rm -r $in_dir
		}
	}

	if $dl {
		ci dl-reports --in-dir $in_dir ...$revisions
	}

	let revision_glob_opts = $revisions | reduce --fold [] {|rev, acc|
		$acc | append [
			"--glob"
			(
				$rev
					| parse '{_repo}:{hash}'
					| first
					| (ci wptreport-glob $"($in_dir)/($in.hash)/")
					| into string
			)
		]
	}

	let args = [$verb ...$revision_glob_opts ...$additional_args]
	log info $"Processing reports with `moz-webgpu-cts ($args | quote-args-for-debugging)`…"
	moz-webgpu-cts ...$args
	log info "Done!"
}

export def --wrapped "ci update-expected" [
	--remove-old,
	--preset: string@"ci process-reports preset",
	--on-skip-only: string@"ci update-expected on-skip-only",
	--in-dir: directory = "../wpt/",
	--implementation-status: list<string@"ci process-reports implementation-status"> = [],
	--dl = true,
	revisions: list<string>,
	...args,
] {
	use std/log [] # set up `log` cmd. state

	mut args = $args

	if $preset != null {
		$args = $args | append ["--preset" $preset]
	}

	if $on_skip_only != null {
		$args = $args | append ["--on-skip-only" $on_skip_only]
	}

	$args = $args | append ($implementation_status | each { ["--implementation-status" $in] } | flatten)

	(
		ci process-reports update-expected
			--remove-old=$remove_old
			--in-dir=$in_dir
			--revisions=$revisions
			--dl $dl ...$args
	)
}

export def "ci migrate" [
	--remove-old,
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	(
		ci process-reports migrate
			--remove-old=$remove_old
			--in-dir=$in_dir
			--revisions=$revisions
	)
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

def "ci update-expected on-skip-only" [] {
	[
		"reconcile"
		"ignore",
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
				| where test =~ $term
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
			let params = $'https://example.com($entry.test)'
				| url parse
				| get params
				| transpose --header-row
				| first

			let test = $params | get q
			let worker_type = try {
				$params | get worker
			} catch {
				null
			}

			$entry
				| update test { $test }
				| insert worker_type { $worker_type }
				| move worker_type --after subsuite
				| update duration { into duration --unit ms }
				| move status --before subtests
		}
}
