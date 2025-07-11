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

export def "cargo-vet-check-output" [
]: nothing -> record<conclusion: string, failures: table<any>, suggest: record<suggestions: table<name: string, suggested_criteria: list<string>, suggested_diff: record<from: oneof<string, nothing>, to: string>>>> {
	let output = cargo vet check --output-format json | complete
	let exit_code = $output.exit_code

	let output_json = $output.stdout | from json
	let bad_exit_code_err = {
		error make --unspanned {
			msg: "underlying invocation of `cargo vet` returned a non-zero exit code, bailing"
		}
	}

	if $exit_code == 101 {
		do $bad_exit_code_err
	}
	if $output_json == null or 'error' in ($output_json | columns) {
		let what_was_returned = if $output_json == null {
			"empty output"
		} else {
			"an `error`"
		}
		print $output
		error make --unspanned {
			msg: ([
				"underlying invocation of `cargo vet` returned "
				$what_was_returned
				" with exit code "
				$exit_code
				", bailing"
			] | str join)
		}
	}

	$output_json
}

# Certify Rust crates a la `certify`, but en masse from `cargo vet check --output-format json`'s
# `suggestions` (which are gathered for you).
#
# A convenience over `certify-from-cargo-vet-check-suggestions`.
#
# Useful when prototyping, and you just want to get to `mach vendor rust` ASAP.
export def "certify-automatically" [
    --reviewers (-r): list<string> = [],
    # Reviewer(s) to set for a revision message. `#supply-chain-reviewers` is always appended to
    # this list.
    --bug: int | null = null,
    # The Bugzilla bug number to use for a revision message. If unspecified, uses `???????` in
    # rendered commit message.
]: nothing -> oneof<string, nothing> {
    cargo-vet-check-output | get suggest.suggestions | certify-from-cargo-vet-check-suggestions
}

# Certify Rust crates a la `certify`, but en masse from `cargo vet check` `suggestions`.
#
# It is recommended that you use this with `fx cargo-vet-check-output` if you know what you're
# doing, or use `certify-automatically` instead.
export def "certify-from-cargo-vet-check-suggestions" [
	--reviewers (-r): list<string> = [],
	# Reviewer(s) to set for a revision message. `#supply-chain-reviewers` is always appended to
	# this list.
	--bug: int | null = null,
	# The Bugzilla bug number to use for a revision message. If unspecified, uses `???????` in
	# rendered commit message.
]: table<name: string, suggested_criteria: list<string>, suggested_diff: record<from: oneof<string, nothing>, to: string>> -> oneof<string, nothing> {
	let suggestions = $in

	if ($suggestions | is-empty) {
		log warning "no suggestions to apply"
		return
	}

	mut recs = []
	for suggestion in $suggestions {
		let positional_args = [
			$suggestion.name
			...($suggestion.suggested_diff.from | each { [$in] })
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

export def "workspace create" [
  --name: string,
  # The name of the workspace to create.
  --dir: oneof<directory, nothing> = null,
  # The directory in which the new workspace should be placed.
  #
  # If unspecified, the parent of root directory of the current repo is used.
  --type: string@"nu-complete workspace create type" = "full",
  --vcs: string@"nu-complete workspace create vcs" = "jj",
]: nothing -> nothing {
  use std

  let specified_dir = $dir

  match $vcs {
    # # TODO: make this work
    # "git" => {
    #
    # }
    "jj" => {
      let dir = $specified_dir | default { jj workspace root | path dirname }
      if ($dir == "") {
        mut msg: oneof<string, nothing> = null
        mut hints: oneof<list<string>, nothing> = null
        mut span = null

        if $specified_dir == null {
          $msg = "inferred `--dir` value came up empty"
          $hints = [
            ([
              "`--dir` was unspecified, so this path was inferred: "
              $dir
            ] | str join)
            "you can probably resolve this by explicitly specify `--dir`"
          ]
        } else {
          $msg = "`--dir` cannot be an empty string"
          $span = ($specified_dir | metadata).span
        }

        error make {
          msg: $msg
          label: {
            span: $span
          }
          help: ($hints | str join "\n\n")
        }
      }
      std assert ($dir != "") "internal error: no `$dir` specified"

      # TODO: Use `path basename` of root instead of `firefox`?
      let dir = [$dir $'firefox-($name)'] | path join
      let recognized_types = nu-complete workspace create type
      let recognized_type_results = $recognized_types | where value == $type
      let recognized_type = match ($recognized_type_results | length) {
        0 => {
          error make {
            msg: $"unrecognized checkout type: ($type | to nuon)"
            labels: [
              {
                text
              }
            ]
          }
        }
        1 => {
          $recognized_type_results | first --strict
        }
        n => {
          error make {
            msg: $"internal error: ($type | to nuon) matched multiple types"
          }
        }
      }

      mut args = []
      if ($recognized_type.sparse_patterns == null) {
        std log warning $"`($recognized_type.value)` checkout type has no sparse patterns, this will take a while…"
      } else {
        $args = $args | append ['--sparse-patterns' 'empty']
      }

      ^jj workspace add --name $name $dir ...$args
      # NOTE: `jj workspace add` should have informed the user of the end of this step already.

      if ($recognized_type.sparse_patterns != null) {
        cd $dir

        let patterns_args = $recognized_type.sparse_patterns | each --flatten { ['--add' $in] }

        jj sparse set ...$patterns_args
      }
    }
    _ => {
      error make {
        msg: $"unrecognized VCS: ($vcs | to nuon)"
        labels: [
          {
            text: ""
            span: (metadata $vcs).span
          }
        ]
      }
    }
  }
}

def "nu-complete workspace create type" [] {
  let mach_entry_points = [
    "build/"
    "mach"
    "mach.cmd"
    "mach.ps1"
    "python/mach/"
    "python/mozboot/"
    "python/mozbuild/"
    "python/mozversioncontrol/"
    "python/sites/"
    "third_party/python/"
  ]

  let mach_configure_files = [
    ...$mach_entry_points
    "configure.py"
    "moz.configure"
    "js/"
  ]

  let mach_vendor_files = [
    ...$mach_entry_points
    "testing/mozbase/"
  ]

  let mach_try_files = [
    ...$mach_entry_points
    "python/mozlint/"
    "python/mozterm/"
    "taskcluster/"
  ]

  [
    {
      value: "full"
      description: "Full checkout (warning: heavy)"
      sparse_patterns: null
    }
    {
      value: "almost-empty"
      description: "Almost empty checkout"
      sparse_patterns: []
    }
    {
      value: "webgpu-cts"
      description: "WebGPU CTS triage"
      sparse_patterns: [
        # CTS-specific stuff
        "dom/webgpu/tests/cts/"
        "testing/web-platform/mozilla/meta/webgpu/"
        "testing/web-platform/mozilla/tests/webgpu/"
        "testing/web-platform/tests/tools/third_party/"

        ...$mach_try_files
        ...$mach_vendor_files
      ]
    }
    {
      # TODO: Validate that this works.
      value: "cargo"
      description: "Cargo lockfile inspection"
      sparse_patterns: [
        "**/Cargo.lock",
        "**/Cargo.toml",
      ]
    }
    {
      # TODO: Validate that this works.
      value: "angle"
      description: "ANGLE revendoring"
      sparse_patterns: ([
        "gfx/angle/"
        "third_party/angle/"

        ...$mach_try_files
        ...$mach_vendor_files
      ])
    }
  ] | update sparse_patterns {
    if $in == null {
      $in
    } else {
      $in
        | append [
          '.arcconfig' # NOTE: Needed so that `moz-phab` actually works.
          '.gitignore'
          '.hgignore'
        ]
        | sort --natural
        | uniq
    }
  }
}

def "nu-complete workspace create vcs" [] {
  [
    # # TODO: make this work
    # {
    #   value: "git"
    #   description: "Git"
    # }
    {
      value: "jj"
      description: "Jujutsu"
    }
  ]
}
