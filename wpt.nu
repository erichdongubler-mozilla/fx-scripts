def extract-test-events []: binary -> list<record> {
  $in
    | lines
    | enumerate
    | rename line_num
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
      "SKIP" | "OK" => {
        let parsed = $evt.rest | parse '{rest} | took {wpt_duration}' | first
        let key = $parsed.rest
        $last_stop_timestamp = $evt.timestamp
        $test_timings = ($test_timings | update $key {
          insert end $evt.timestamp
            | insert log_duration { $in.end - $in.begin }
            | insert status { $evt.type }
            # | insert wpt_duration { $parsed.wpt_duration | into duration }
        })
      }
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

def aggregate-timings-webgpu []: list<record> -> list<record> {
  $in
    | update test {
      if ($in =~ '\?q=') {
        parse '{asdf}?q={path}' | get path | first
      } else {
        $in
      }
    }
    | where status != SKIP
    | group-by --to-table {
      $in.test
        | parse 'webgpu:{test_path}:{rest}'
        | first
        | get test_path
    }
    | insert aggregate_time {
      $in.items | reduce --fold 0ms {|item, acc|
          $acc + $item.log_duration
        }
    }
}

# Create an aggregated view of time spent in individual test files for WebGPU test runs.
#
# Pipe a `string` into this function, i.e., an `http get …` call that fetches the `live_backing.log`
# artifact from TreeHerder for the task you're interested in.
#
# Example: `http get 'https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/MJNEIlPjT3-wvAmSmZUN4A/runs/0/artifacts/public/logs/live_backing.log' | wpt aggregate-timings webgpu`
export def "aggregate-timings webgpu" []: string -> list<record> {
  let log_data = $in
  $log_data | extract-test-events | determine-test-timings | aggregate-timings-webgpu

}
