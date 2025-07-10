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
  ...segments: string@"nu-complete get",
]: nothing -> record<prefixes: list<string> files: table<name: string size: filesize last_modified: datetime>> {
  http-get-json $'firefox/($segments | each { $'($in)/' } | str join)' | update files {
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
  let completing_partial = ($context | is-not-empty) and ($context == ($context | str trim --right))
  let segments = $context | split words

  let candidate_segments = if $completing_partial {
    $segments | slice ..-2
  } else {
    $segments
  }

  let response = list ...$candidate_segments

  let partial = if $completing_partial {
    $segments | last
  } else {
    ''
  }

  mut candidates = $response.prefixes
    | str replace --regex '/$' ''
    | each {
      {
        value: $in
        style: blue
      }
    }

  if ($response.files | is-not-empty) {
    $candidates = $candidates | append (
        $response.files
          | get name
          | each {
            {
              value: $in
              style: green
            }
          }
      )
  }

  $candidates | where ($it.value | str starts-with $partial)
}
