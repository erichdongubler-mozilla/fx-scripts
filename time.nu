# Date- and time-related utilities, primarily those used by other scripts.

export def "monday-of-this-week" [] {
  seq date --reverse --days 7
    | into datetime
    | where { ($in | format date "%u") == "1" }
    | first --strict
    | format date "%Y-%m-%d"
}
