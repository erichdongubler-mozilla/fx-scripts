export def "main" [
  rev: string,
]: nothing -> string {
  http get $'https://hg-edge.mozilla.org/mozilla-central/json-rev/($rev)' | get git_commit
}
