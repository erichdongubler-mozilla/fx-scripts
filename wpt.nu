export def task-timeout-regex [] {
  # NOTE: On macOS, `task` is capitalized, but _not_ on other platforms. 😱
  "[Tt]ask aborted - max run time exceeded"
}

def "find-timed-out-tasks report" [
  --dir: string,
  --artifact-path-re: string,
  --output: string@"nu-complete find-timed-out-tasks output" = "tree",
]: list<string> -> oneof<list<string>, string> {
  let found = $in | uniq | sort --natural

  match $output {
    "file-list" => $found
    "tree" => {
      let path_trim_re = [
        '^(.*?)/'
        '(?:0/)?'
        $artifact_path_re
        '$'
      ] | str join

      $found
        | str replace '\' '/' --all
        | str replace $dir ''
        | str replace --regex $path_trim_re '$1'
        | str join "\n"
        | treeify
    }
  }
}

# Find timed out tasks with `live_backing.log`s.
export def "find-timed-out-tasks via-log" [
  dir: string,
  # A directory containing `live_backing.log` files.
  --output: string@"nu-complete find-timed-out-tasks output" = "tree",
  # The output format to use for this script.
  #
  # If downloaded using `treeherder-dl` and `tree` is specified, printed results have their leading
  # `$dir` and trailing `public/logs/live_backing.log` trimmed. If the retry number (the segment
  # preceding `public`) is `0`, it is also omitted.
]: nothing -> oneof<list<string>, string> {
  rg --files-with-matches (task-timeout-regex) $dir --glob $'**/live_backing.log'
    | lines
    | find-timed-out-tasks report --dir $dir --artifact-path-re 'public/logs/live_backing\.log' --output $output
}

def "nu-complete find-timed-out-tasks output" [] {
  [
    "tree"
    "file-list"
  ]
}
