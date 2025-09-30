def "notify" [...args: any] {
	toastify send --app-name="Firefox build" ...$args
}

export def "build" [
	--clobber,
	--jobs: int | null = null,
] {
	notify $"Queued Firefox build in `($env.PWD)`."

	mut build_task_args = []
	if $clobber {
		let clobber_task_id = pueue add --print-task-id -- mach clobber
		$build_task_args = $build_task_args | append ["--after" $clobber_task_id]
	}

	mut build_cli_args = []
	if $jobs != null {
		$build_cli_args = $build_cli_args | append ["--jobs" $jobs]
	}
	let build_task_id = pueue add --print-task-id ...$build_task_args -- mach build ...$build_cli_args

	pueue wait $build_task_id
	_pueue report-status $build_task_id
}

def "_pueue report-status" [task_id: string] {
	let task_status = pueue status --json | from json | get tasks | get $task_id

	mut status = $task_status | get status | columns | first
	if $status == "Done" {
		$status = $task_status | get status.Done.result
	}
	let working_dir = $task_status | get path | path basename

	notify $"($status)\nFinished build in `($working_dir)`"
}

export def "bootstrap lines-to-disable" [] {
	[
		"# ac_add_options --disable-bootstrap"
		"# ac_add_options MOZ_WINDOWS_RS_DIR=…"
		"# ac_add_options --without-wasm-sandboxed-libraries"
	]
}

# Certify Rust crates a la `certify`, but en masse from `cargo vet check --output-format json`.
# Useful when prototyping, and you just want to get to `mach vendor rust` ASAP.
export def "certify-from-cargo-vet-check" [
	--reviewers (-r): list<string> = [],
	# Reviewer(s) to set for a revision message. `#supply-chain-reviewers` is always appended to
	# this list.
	--bug: int | null = null,
	# The Bugzilla bug number to use for a revision message. If unspecified, uses `???????` in
	# rendered commit message.
] {
	let suggestions = cargo vet check --output-format json
		| from json
		| get suggest.suggestions

	mut recs = []
	for suggestion in $suggestions {
		let positional_args = [
			$suggestion.name
			...(if $suggestion.suggested_diff.from != null {
				[$suggestion.suggested_diff.from]
			} else {
				[]
			})
			$suggestion.suggested_diff.to
		]

		(
			cargo vet certify
			...(
				$suggestion.suggested_criteria
					| each { ['--criteria' $in] }
					| flatten
			)
			--accept-all
			...$positional_args
		)
		$recs = $recs | append [$positional_args]
	}
	certify-generate-revision-msg $recs --reviewers $reviewers --bug $bug
}

# Certify Rust crates for usage in Mozilla source using `cargo vet -- certify`, returning the
# suggested commit message for the audits you perform
#
# # Examples
#
# - `git commit -m (fx certify [hashlink 0.9.0 0.10.0])`
# - `jj commit -m (fx certify --bug 99999999 [hashlink 0.9.0 0.10.0])`
export def "certify" [
	recs: list<list<string>>,
	--criteria: string = "safe-to-deploy",
	# A list of lists of positional arguments to provide to `cargo vet certify …` invocations.
	#
	# Typically, you'll want to provide `[$crate $version]` or `[$crate $old_version $new_version]`
	#
	# You do not need to specify `--accept-all` or `--criteria=safe-to-deploy` here; this is already
	# done for you.
	--reviewers (-r): list<string> = [],
	# Reviewer(s) to set for a revision message. `#supply-chain-reviewers` is always appended to
	# this list.
	--bug: int | null = null,
	# The Bugzilla bug number to use for a revision message. If unspecified, uses `???????` in
	# rendered commit message.
]: nothing -> string {
	for args in $recs {
		cargo vet certify --accept-all --criteria $criteria -- ...$args
	}

	certify-generate-revision-msg $recs --reviewers $reviewers --bug $bug
}

def "certify-generate-revision-msg" [
	recs: list<list<string>>,
	--reviewers (-r): list<string> = [],
	# Reviewer(s) to set for a revision message. `#supply-chain-reviewers` is always appended to
	# this list.
	--bug: int | null = null,
	# The Bugzilla bug number to use for a revision message. If unspecified, uses `???????` in
	# rendered commit message.
] {
	let list_summary = $recs | each {
		$'`($in.0)` ($in | slice 1.. | str join " → ")'
	} | str join ', '

	let bug = if $bug == null {
	  "???????"
	} else {
	  $bug | into string
	}

	let reviewers = $reviewers | append "#supply-chain-reviewers"

	$"Bug ($bug) - chore\(rust\): audit ($list_summary) r=($reviewers | str join ',')"
}
