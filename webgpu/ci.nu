use std/log

const WPT_REPORT_ARTIFACT_PATH = 'public/test_info/wptreport.json'
const WPT_INSTRUMENTS_ARTIFACT_PATH = 'public/test_info/wpt_instruments.txt'

def quote-args-for-debugging []: list<string> -> string {
  each { $'"($in)"' } | str join ' '
}

export def "dl" [
  --in-dir: directory = "../wpt/",
  --what: string = "artifacts",
  --artifact: oneof<string, nothing> = null,
  ...revisions: string,
] {
  use std/log [] # set up `log` cmd. state

  if $artifact == null {
    error make --unspanned { msg: "no `--artifact` specified" }
  }

  if ($revisions | is-empty) {
    error make --unspanned { msg: "no revisions specified" }
  }

  let args = [
    --job-type-re ".*web-platform-tests-webgpu.*"
    --artifact $artifact
    --out-dir $in_dir
    ...$revisions
  ]
  log info $"Downloading ($what) via `treeherder-dl ($args | quote-args-for-debugging)`…"
  if (which treeherder-dl | is-empty) {
    error make --unspanned {
      msg: "`treeherder-dl` not found in `PATH`; do you need to install it?"
    }
  }
  treeherder-dl ...$args
}

export def "dl-reports" [
  --in-dir: directory = "../wpt/",
  ...revisions: string,
] {
  (
    dl
      --what "reports"
      --artifact $WPT_REPORT_ARTIFACT_PATH
      --in-dir $in_dir
      ...$revisions
  )
}

export def "dl-logs" [
  --in-dir: directory = "../wpt/",
  ...revisions: string,
] {
  (
    dl
      --what "logs"
      --artifact 'public/logs/live_backing.log'
      --in-dir $in_dir
      ...$revisions
  )
}

export def "dl-timings" [
  --in-dir: directory = "../wpt/",
  ...revisions: string,
] {
  (
    dl
      --what "timings logs"
      --artifact $WPT_INSTRUMENTS_ARTIFACT_PATH
      --in-dir $in_dir
      ...$revisions
  )
}

export def "device-init-fail-regex" []: nothing -> string {
  'WebGPU device failed to initialize'
}

export def "meta path-and-line" [
  cts_test_path: string,
]: nothing -> string {
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

def "artifact-glob" [in_dir: path, glob: string] {
  $in_dir
    | path join $glob
    | str replace --all '\' '/' | into glob
}

def "wptreport-glob" [in_dir: path] {
  artifact-glob $in_dir $'**/($WPT_REPORT_ARTIFACT_PATH)'
}

def "process-reports" [
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
    dl-reports --in-dir $in_dir ...$revisions
  }

  let revision_glob_opts = $revisions | reduce --fold [] {|rev, acc|
    $acc | append [
      "--glob"
      (
        $rev
          | parse '{_repo}:{hash}'
          | first
          | (wptreport-glob $"($in_dir)/($in.hash)/")
          | into string
      )
    ]
  }

  let args = [$verb ...$revision_glob_opts ...$additional_args]
  log info $"Processing reports with `moz-webgpu-cts ($args | quote-args-for-debugging)`…"
  moz-webgpu-cts ...$args
  log info "Done!"
}

export def "trim-reports" [
  --in-dir: directory = "../wpt/",
  ...task_ids: string,
]: nothing -> list<string> {
  use std/log [] # set up `log` cmd. state

  let abs_dir_path = $in_dir | path expand

  let files = fd '.' --type 'directory' $in_dir
    | lines
    | where ($it | path split | last) in $task_ids
    | each { path join '*' $WPT_REPORT_ARTIFACT_PATH | glob $in }
    | flatten

  if ($files | is-not-empty) {
    rm ...$files
  }

  $files
    | path relative-to $abs_dir_path
    | each {|p| $in_dir | path join $p }
}

export def --wrapped "update-expected" [
  --remove-old,
  --preset: string@"process-reports preset",
  --on-skip-only: string@"update-expected on-skip-only",
  --in-dir: directory = "../wpt/",
  --implementation-status: list<string>@"process-reports implementation-status" = [],
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

  $args = $args | append (
    $implementation_status
      | each { ["--implementation-status" $in] }
      | flatten
  )

  (
    process-reports update-expected
      --remove-old=$remove_old
      --in-dir=$in_dir
      --revisions=$revisions
      --dl $dl ...$args
  )
}

export def "migrate" [
  --remove-old,
  --in-dir: directory = "../wpt/",
  ...revisions: string,
] {
  (
    process-reports migrate
      --remove-old=$remove_old
      --in-dir=$in_dir
      --revisions=$revisions
  )
}

def "process-reports preset" [] {
  [
    "new-fx"
    "same-fx"
    "merge"
    "reset-contradictory"
    "reset-all"
  ]
}

def "process-reports implementation-status" [] {
  [
    "implementing"
    "backlog"
    "not-implementing"
  ]
}

def "update-expected on-skip-only" [] {
  [
    "reconcile"
    "ignore",
  ]
}

export def "search reports by-test-message" [
  term: string,
  --in-dir: directory = "../wpt/",
  --include-skipped = false,
] {
  use std/log [] # set up `log` cmd. state

  let files = (ls (wptreport-glob $in_dir) | where type == file) | get name | sort
  let predicate = { $in | default "" | str contains $term }

  $files
    | par-each --keep-order {|file|
      use std
      log debug $"searching ($file)"
      open $file
        | get results
        | where {
          (
            ($in.message | do $predicate)
              or ($in.subtests | any { $in.message | do $predicate })
          )
        }
        | each {
          { file: $file test: $in }
        }
    }
    | search reports clean-search-results $in_dir
}

export def "search reports by-test-name" [
  term: string,
  --regex,
  --in-dir: directory = "../wpt/",
  --include-skipped = false,
] {
  use std/log [] # set up `log` cmd. state

  let search_for_term = test-searcher --regex $term

  let files = (
    ls (wptreport-glob $in_dir) | where type == file
  ) | get name | sort

  $files
    | par-each --keep-order {|file|
      let json = open $file
      if $json == null {
        return []
      }
      $json
        | get results
        | where { get test | do $search_for_term }
        | each {
          { file: $file test: $in }
        }
    }
    | search reports clean-search-results $in_dir
}

def "search clean-search-results" [
  in_dir: string,
  --artifact-path: string,
  --extra-per-item: closure,
]: table<file: path, test: record<test: string>> -> table<file: path test: string, worker_type: oneof<string, nothing>> {
  let results = $in

  let sanitize_windows_paths = { str replace '\' '/' --all }

  let in_dir_absolute = $in_dir | path expand | do $sanitize_windows_paths

  $results
    | flatten
    | update file {
      $in
        | path expand
        | do $sanitize_windows_paths
        | str replace $in_dir_absolute ''
        | str replace $artifact_path ''
        | str replace --regex '/0/$' '/'
    }
    | flatten
    | each {|entry|
      let params = $'https://example.com($entry.test)'
        | url parse
        | get params

      if $params == [] {
        # This might happen if we're not running a CTS test in the standalone framework, like an IDL
        # test, or a reftest.
        $entry | insert worker_type null
      } else {
        let params = $params
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
      }
        | do $extra_per_item
    }
}

def "search reports clean-search-results" [
  in_dir: string,
  --include-skipped = false,
] {
  let pre_filtered = (
    search clean-search-results
      $in_dir
      --artifact-path $WPT_REPORT_ARTIFACT_PATH
      --extra-per-item {
        move worker_type --after subsuite
          | update duration { into duration --unit ms }
          | move status --before subtests
          | reject subsuite
      }
  )

  if $include_skipped {
    $pre_filtered
  } else {
    $pre_filtered | where status != 'SKIP'
  }
}

def "test-searcher" [
  term: string,
  --regex,
]: nothing -> closure {
  if $regex {
    { $in =~ $term }
  } else {
    { $in | str contains $term }
  }
}
