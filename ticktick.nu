export def "summary-to-daily" []: string -> any {
  let chunks = split row "\n## "

  let _title = $chunks | first
  $chunks
    | slice 1..
    | each {
      parse --regex ([
        "(?P<Priority>\\w+)\n"
        "(?:###    Completed\n(?P<completed>.*?)\n)?"
        "(?:###    Won't Do\n(?P<wont_do>.*?)\n)?"
        "(?:###    Undone\n(?P<undone>.*?)\n)?"
      ] | str join)
    }
}
