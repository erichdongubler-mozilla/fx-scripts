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
