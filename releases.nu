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
