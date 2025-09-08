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

# Find timed out tasks with `wptreport.json`s.
export def "find-timed-out-tasks via-report" [
  dir: string,
  # A directory containing `live_backing.log` files.
  --output: string@"nu-complete find-timed-out-tasks output" = "tree",
  # The output format to use for this script.
  #
  # If downloaded using `treeherder-dl` and `tree` is specified, printed results have their leading
  # `$dir` and trailing `public/test_info/wptreport.json` trimmed. If the retry number (the segment
  # preceding `public`) is `0`, it is also omitted.
]: nothing -> oneof<list<string>, string> {
  # NOTE: A present, but empty, `wptreport.json` indicates that `wptrunner` didn't successfully
  # write the report. We assume this is due to a task timeout, rather than some other cause.
  rg --files --glob '**/wptreport.json' $dir
    | lines
    | ls ...$in
    | where size == 0B
    | get name
    | find-timed-out-tasks report --dir $dir --artifact-path-re 'public/test_info/wptreport\.json' --output $output
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

export def "parse-wpt_instruments.txt" [
]: string -> table<thread_name: string fn_name: string activity: oneof<string, nothing> rest: oneof<string, nothing>, duration: duration> {
  let lines = lines | enumerate | where { get item | str trim | is-not-empty }
  let parse_line = {
    parse --regex '^(?P<thread_name>.*?);(?P<fn_name>.*?)(?:;(?P<activity>.*?)(?:;(?P<rest>.*?))?)? (?P<duration>-?\d+)$'
  }
  let parsed_lines = $lines | get item | do $parse_line
  if ($lines | length) != ($parsed_lines | length) {
    let problem_line = $lines
      | where {
        (get item | do $parse_line) | is-empty
      }
      | first
    error make --unspanned {
      msg: $"failed to parse line ($problem_line.index):\n\n($problem_line.item)"
    }
  }

  $parsed_lines
    | each {
      if $in.fn_name == 'testrunner' and $in.activity == 'test' {
        update rest {
          parse --regex '^(?P<path>.*?)(?P<query>\?.*)?$'
            | first
            | update path { split row ';' | str join '/' }
            | $"($in.path)($in.query)"
        }
      } else {
        $in
      }
    }
    | update duration { into duration --unit ms }
}

def "nu-complete find-timed-out-tasks output" [] {
  [
    "tree"
    "file-list"
  ]
}
