const HOST = "https://bugzilla.mozilla.org"

const USER_AGENT_HEADER = { "User-Agent": "ErichDonGubler-Socorro-Nushell/1.0" }

def "auth-headers from-auth-token" [
  --required-for: string | null = null,
] {
  use std/log [] # set up `log` cmd. state

  mut auth_token = null

  const env_var_name = 'SOCORRO_AUTH_TOKEN'
  try {
    $auth_token = $env | get $env_var_name
  } catch {
    log debug $"no `($env_var_name)` defined"
  }

  const config_path = $'($nu.home-path)/.config/socorro.toml'
  const toml_key = 'auth_token'
  if $auth_token == null {
    try {
      $auth_token = open $config_path | get $toml_key
    } catch {
      log debug $"failed to access `($toml_key)` field in `($config_path)`"
    }
  }

  if $auth_token != null {
    {
      'Auth-Token': $auth_token
    }
  } else {
    if $required_for == null {
      {}
    } else {
      error make --unspanned {
        msg: ([
          "failed to get Socorro/crash stats auth. token from the following sources:"
          $"- `($env_var_name)` environment variable"
          $"- `($toml_key)` field in `($config_path)`"
          ""
          $"…and at least one is required for ($required_for)."
        ] | str join "\n")
      }
    }
  }
}

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

export def "api reprocess" [
  --crash-ids: list<string>,
] {
  _http get "Reprocessing/" { crash_ids: $crash_ids }
}

export def reports-from-bug [
  bug_id: int,
] {
  let signatures = api signatures-by-bugs $bug_id | get hits.signature

  let reports = api super-search {
    signature: ($signatures | each { $'=($in)' }) # `=` is a string search operator for "exact match"
    product: Firefox
  } | get hits.uuid

  $reports | par-each { api processed-crash $in }
}

export def "_http get" [
  url_path: string,
  query_params: record,
  --auth-required-for: oneof<nothing, string> = null,
] {
  mut headers = { "User-Agent": "ErichDonGubler-Socorro-Nushell/1.0" }

  if $auth_required_for != null {
    $headers = $headers | merge (auth-headers from-auth-token)
  }

  let req_url = $'https://crash-stats.mozilla.org/api/($url_path)?($query_params | url build-query)'
  http get --headers $headers $req_url
}
