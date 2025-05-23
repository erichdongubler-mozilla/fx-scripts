export def task-timeout-regex [] {
  # NOTE: On macOS, `task` is capitalized, but _not_ on other platforms. 😱
  "[Tt]ask aborted - max run time exceeded"
}

# Find timed out tasks with `live_backing.log`s.
export def "find-timed-out-tasks" [
  dir: string,
  # A directory containing `live_backing.log` files.
  --output: string@"nu-complete find-timed-out-tasks output" = "tree",
  # The output format to use for this script.
  #
  # If downloaded using `treeherder-dl` and `tree` is specified, printed results have their leading
  # `$dir` and trailing `public/logs/live_backing.log` trimmed. If the retry number (the segment
  # preceding `public`) is `0`, it is also omitted.
] {
  let found = rg --files-with-matches (task-timeout-regex) $dir --glob $'**/live_backing.log'
    | lines
    | uniq
    | sort --natural

  match $output {
    "file-list" => $found
    "tree" => {
      $found
        | str replace '\' '/' --all
        | str replace $dir ''
        | str replace --regex '^(.*?)/(?:0/)?public/logs/live_backing\.log$' '$1'
        | str join "\n"
        | treeify
    }
  }
}

def "nu-complete find-timed-out-tasks output" [] {
  [
    "tree"
    "file-list"
  ]
}
