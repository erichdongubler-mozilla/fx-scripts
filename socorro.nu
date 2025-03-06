export def "api processed-crash" [
  crash_id: string,
] {
  _http get "ProcessedCrash/" { crash_id: $crash_id }
}

export def "api signatures-by-bugs" [
  ...bug_ids: int,
] {
  _http get "SignaturesByBugs/" { bug_ids: ($bug_ids | each { into string }) }
}

export def "api super-search" [
  arguments: record,
] {
  _http get "SuperSearch/" $arguments
}

export def "_http get" [
  url_path: string,
  query_params: record,
] {
  const USER_AGENT_HEADER = ["User-Agent" "ErichDonGubler-Socorro-Nushell/1.0"]
  let req_url = $'https://crash-stats.mozilla.org/api/($url_path)?($query_params | url build-query)'
  http get --headers $USER_AGENT_HEADER $req_url
}
