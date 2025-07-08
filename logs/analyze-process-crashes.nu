export def "extract-logs" [
  --in-dir: directory,
] {
  # NOTE: Stupid, stupid Windows path separator.
  let rework_windows_path = {
    path split
      | update 0 { str replace ':\' ':' }
      | str join '/'
  }
  let in_dir = $in_dir | do $rework_windows_path

  rg 'PROCESS-CRASH' $in_dir --glob '**/live_backing.log'
    | lines
    | parse --regex '^(?P<file>(?:[A-Z]:[\\\/])?[^:]*):(?P<line>.*)$'
    | update file {
      do $rework_windows_path
        | str replace $in_dir ''
        | str replace --regex '(/0)?/public/logs/live_backing\.log$' ''
    }
    | group-by file --to-table
    | reject items.file
    | update items {
      get line
        | str replace --regex '.*PROCESS-CRASH \| ' ''
        | parse '{msg} | {url_path}'
        | each {|row|
          let url_parse = $row.url_path | parse --regex '^(?P<test_file>.*)\?.*?\bq=(?P<cts_path>.*)' | first
          {
            msg: $row.msg
            test_file: $url_parse.test_file
            cts_path: $url_parse.cts_path
          }
        }
    }
    | flatten items --all
    | group-by cts_path --to-table
    | reject items.cts_path
    | update items {
      group-by msg --to-table | reject items.msg | update items { get file }
    }
}

export def "main" [
  --in-dir: directory,
] {
  extract-logs --in-dir $in_dir
    | insert Assignee Erich
    | insert Resolution ''
    | insert Bugs ''
    | insert Type 'Perma'
    | insert 'Expectations File' {|row|
      $row.cts_path
        | str replace --regex '^webgpu:(.*?):.*' '$1'
        | str replace --all ',' '/'
        | str replace --regex '$' '/cts.https.html'
    }
    | rename --column { cts_path: Test }
    | update items { to json }
    | rename --column { items: Notes }
    | move --first Assignee Resolution Bugs Type 'Expectations File' Test Notes
}
