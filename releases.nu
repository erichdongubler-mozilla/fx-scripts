def "http-get-json" [
  url_path: string,
]: nothing -> any {
  (
    http get $'https://archive.mozilla.org/pub/($url_path)'
      --headers [Accept application/json]
      --headers [Content-Type application/json]
  )
}

export def "by-date" [
  --limit: oneof<int, nothing> = null,
] {
  mut releases = uvx mozregression --list-releases
    | lines
    | skip 1
    | sort --natural --reverse
    | each { str trim }
    | where { is-not-empty }
    | parse '{release}: {date}'
    | update release { into int }
    | update date { into datetime }

  if $limit != null {
    $releases = $releases | take $limit
  }

  $releases
}

export def "ftp list" [
  ...segments: string,
]: nothing -> record<prefixes: list<string> files: table<name: string size: filesize last_modified: datetime>> {
  http-get-json $'firefox/($segments | each { $'($in)/' } | str join)' | update files {
    $in
      | update size { into filesize }
      | update last_modified { into datetime }
  }
}
