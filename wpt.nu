def extract-test-events []: binary -> list<record> {
  $in
    | lines
    | enumerate
    | rename line_num
    | update line_num { $in + 1 }
    | where item =~ 'TEST-'
    | update item {
      parse '[task {timestamp}] {time_again}INFO - TEST-{type} | {rest}'
        | reject time_again
    }
    | flatten --all
    | update timestamp { into datetime }
}

def determine-test-timings []: list<record> -> list<record> {
  let test_events = $in
  mut curr_test = null
  mut test_timings = {}
  mut last_stop_timestamp = null
  let first_timestamp = $test_events | first | get timestamp
  for evt in $test_events {
    match $evt.type {
      "START" => {
        let key = $evt.rest
        if $key in $test_timings {
          error make {
            msg: ([
              $"duplicate entry detected for ($key); "
              "found on both "
              $"line (($test_timings | get $key | get line_num))"
              " and "
              $"line $($evt | get '#')"
            ] | str join)
            span: (metadata $evt.rest).span
            # TODO: labels for old and new
          }
        }
        $test_timings = ($test_timings | insert $key {
          begin: $evt.timestamp
          time_since_previous: ($evt.timestamp - ($last_stop_timestamp | default $evt.timestamp))
          time_since_task_start: ($evt.timestamp - $first_timestamp)
        })
      }
      "SKIP"
      | "OK"
      | "PASS"
      | "FAIL"
      | "TIMEOUT"
      | "NOTRUN"
      | "ERROR"
      | "CRASH"
      | "UNEXPECTED-PASS"
      | "UNEXPECTED-FAIL"
      | "UNEXPECTED-TIMEOUT"
      | "UNEXPECTED-NOTRUN"
      | "KNOWN-INTERMITTENT-FAIL"
      | "KNOWN-INTERMITTENT-TIMEOUT"
      | "KNOWN-INTERMITTENT-NOTRUN"
      | "KNOWN-INTERMITTENT-ERROR"
      => {
        let parsed = $evt.rest | parse '{rest} | took {wpt_duration}' | first
        let key = $parsed.rest
        $last_stop_timestamp = $evt.timestamp
        $test_timings = ($test_timings | update $key {
          insert end $evt.timestamp
            | insert log_duration { $in.end - $in.begin }
            | move log_duration --before begin
            | insert status { $evt.type }
            | move status --before begin
            # | insert wpt_duration { $parsed.wpt_duration | into duration }
        })
      }
      "INFO" => {}
      _ => {
        error make --unspanned {
          msg: $"I don't recognize the test event type `($evt.type)` from line ($evt | get line_num), sorry!"
        }
      }
    }
  }
  $test_timings
    | transpose
    | rename test timing
    | flatten
    | default null begin
    | default null end
    | default null status
    | default 0ms log_duration
    | reject begin end
}

def aggregate-timings-of-single-log []: list<record> -> list<record> {
  $in
    | insert file {
      if ($in.test =~ '\?') {
        $in.test | parse '{path}?{_params}' | get path | first
      } else {
        $in
      }
    }
    | where status != SKIP
    | group-by file --to-table
    | rename file
    | reject items.file
    | insert aggregate_time {
      $in.items | reduce --fold 0ms {|item, acc|
          $acc + $item.log_duration
        }
    }
    | move aggregate_time --after file
}

# Create an aggregated view of time spent in individual test files for WebGPU test runs.
#
# Pipe a `string` into this function, i.e., an `http get …` call that fetches the `live_backing.log`
# artifact from TreeHerder for the task you're interested in.
#
# Example: `http get 'https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/MJNEIlPjT3-wvAmSmZUN4A/runs/0/artifacts/public/logs/live_backing.log' | wpt aggregate-timings webgpu`
export def aggregate-timings []: binary -> list<record> {
  extract-test-events | determine-test-timings | aggregate-timings-of-single-log
}

export def aggregate-timings-from-logs [glob_pattern: glob] {
  ls $glob_pattern
    | where type == file
    | get name
    | par-each {
      let file = $in
      open --raw $file
        | aggregate-timings
        | insert log_file { $file }
    }
    | flatten
    | group-by log_file --to-table
    | rename log_file
    | reject items.log_file
}

export def task-timeout-string [] {
  "Task aborted - max run time exceeded"
}
