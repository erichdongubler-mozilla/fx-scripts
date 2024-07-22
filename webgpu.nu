use std log [debug, info]

def quote-args-for-debugging []: list<string> -> string {
	$in | each { ['"' $in '"'] | str join } | str join ' '
}

export def "ci dl-reports" [
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
	let args = [--job-type-re ".*web-platform-tests-webgpu.*" --artifact 'public/test_info/wptreport.json' --out-dir $in_dir ...$revisions]
	info $"Downloading reports via `treeherder-dl ($args | quote-args-for-debugging)…"
	treeherder-dl ...$args
}

export def "ci dl-logs" [
	--in-dir: directory = "../wpt/",
	...revisions: string,
] {
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
	info $"Processing reports with `moz-webgpu-cts ($args | quote-args-for-debugging)`…"
	moz-webgpu-cts ...$args
	info "Done!"
}

export def "ci update-expected" [
	--remove-old,
	--preset: string@"ci process-reports preset",
	--in-dir: directory = "../wpt/",
	--implementation-status: list<string@"ci process-reports implementation-status">,
	...revisions: string,
] {
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

def wgpu_repo_pkgs [] {
	let wgpu_repo_url = "https://github.com/gfx-rs/wgpu"
	let id_pat = ["git+" $wgpu_repo_url "?rev={rev}#{name}@{ver}"] | str join
	^cargo metadata --format-version 1
		| from json
		| get packages
		| where source != null
		| where {|pkg| $pkg.source =~ $wgpu_repo_url }
		| each {|pkg|
			let parsed_id = $pkg.id | parse $id_pat | first
			{
				name: $pkg.name
				version: ($parsed_id | [$in.ver "@git:" $in.rev] | str join)
			}
		}
}

export def "revendor wgpu" [
	--revision: string,
] {
	let old_metadata = (wgpu_repo_pkgs)

	let cmd = "mach"
	mut args = [vendor --ignore-modified gfx/wgpu_bindings/moz.yaml]
	if $revision != null {
		$args = ($args | append ["--revision" $revision])
	}
	let args = $args
	info $"running `([$cmd] | append $args | str join ' ')`…"
	let vendor_output = (do { run-external $cmd ...$args } o+e>| complete)
	if $vendor_output.exit_code != 0 {
		error make --unspanned { msg: "failed to re-vendor, bailing" }
		return;
	}
	let vendor_output = $vendor_output | get stdout | lines
	let old_revision = (
		let REV_RE = 'Found   revision: (?P<revision>\w+)';
		$vendor_output | find --regex $REV_RE | first | parse --regex $REV_RE | first | get revision
	)
	info (["old revision: " $old_revision] | str join)
	let new_revision = (
		let REV_RE = ' \d+:\d+.\d+ Latest commit is (?P<revision>\w+?) from .*';
		$vendor_output | find --regex $REV_RE | first | parse --regex $REV_RE | first | get revision
	)
	info (["new revision: " $new_revision] | str join)

	let audits_to_do = (
		let AUDIT_ERR_RE = ([
			' ?\d+:\d+.\d+ E Missing audit for (?P<id>(?P<name>[\w-]+):(?P<version>\S+)) \(requires \['
			"'(?<criteria>[a-z-]+)'"
			'\]\).*'
		] | str join);
		$vendor_output
			| find --regex $AUDIT_ERR_RE
			| parse --regex $AUDIT_ERR_RE
			| each {|pkg_missing_audit|
				{
					pkg_name: $pkg_missing_audit.name
					old_version: ($old_metadata | where name == $pkg_missing_audit.name | first | get version)
					new_version: $pkg_missing_audit.version
					criteria: $pkg_missing_audit.criteria
				}
			}
	)

	info ([
		"audits to do:"
		($audits_to_do | each {||
			[
				"\n  "
				$in.pkg_name
				' '
				$in.old_version
				' -> '
				$in.new_version
				' as `'
				$in.criteria
				'`'
			] | str join
		} | str join)
	] | str join)
	$audits_to_do | each {|audit|
		let cmd = "mach"
		let args = [cargo vet certify --accept-all --criteria $audit.criteria $audit.pkg_name $audit.old_version $audit.new_version]
		info (["Running `" $cmd ' ' ($args | str join ' ' ) "`…"] | str join)
		run-external $cmd ...$args
	}

	info "running `mach vendor rust`, now that we've theoretically unblocked all audits…"
	mach vendor rust --ignore-modified
}
