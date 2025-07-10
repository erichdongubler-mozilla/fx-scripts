def "http-get-json" [
  url_path: string,
]: nothing -> any {
  (
    http get $'https://archive.mozilla.org/pub/($url_path)'
      --headers [Accept application/json]
      --headers [Content-Type application/json]
  )
}

export def "list" [
  path: string@"nu-complete get",
]: nothing -> record<prefixes: list<string> files: table<name: string size: filesize last_modified: datetime>> {
  http-get-json $path | update files {
    $in
      | update size { into filesize }
      | update last_modified { into datetime }
  }
}

export def "nu-complete get" [
  context: string,
  position: int,
  # TODO: use this
] {
  let context = $context | str replace --regex '^releases list ' ''
  let segments = $context | split row '/'
  let completing_partial = $segments | last | is-not-empty
  let candidate_segments = $segments | slice ..-2

  let prefix = $candidate_segments | each { $'($in)/' } | str join

  let response = list $prefix

  let partial = if $completing_partial {
    $segments | last
  } else {
    ''
  }

  mut candidates = $response.prefixes | each {
    {
      _name: $in
      value: $'($prefix)($in)'
      style: blue
    }
  }

  if ($response.files | is-not-empty) {
    $candidates = $candidates | append (
        $response.files
          | get name
          | each {
            {
              _name: $in
              value: $'($prefix)($in)'
              style: green
            }
          }
      )
  }

  $candidates | where ($it._name | str starts-with $partial)
}
