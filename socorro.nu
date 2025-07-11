const HOST = "https://bugzilla.mozilla.org"

const USER_AGENT_HEADER = { "User-Agent": "ErichDonGubler-Socorro-Nushell/1.0" }

export def "auth-headers from-auth-token" [
  --required-for: oneof<string, nothing> = null,
] {
  use std/log

  const env_var_name = 'SOCORRO_AUTH_TOKEN'
  const config_path = $'($nu.home-dir)/.config/socorro.toml'
  const toml_key = 'auth_token'

  let sources = [
    {
      name: $"`($env_var_name)` environment variable"
      extractor: { $env | get --optional $env_var_name }
      fail_warning_msg: { $"no ($in) defined" }
    }
    {
      name: $"`($toml_key)` field in `($config_path)`"
      extractor: {
        try {
          open $config_path | get --optional $toml_key
        } catch {
          log debug $"unable to open path `($config_path)`"
        }
      }
      fail_warning_msg: { $"failed to find ($in)" }
    }
  ]

  $sources
    | each {|source|
      log debug $"attempting to get auth from ($source.name)…"
      do $source.extractor
        | each {
          { 'Auth-Token': $in }
        }
        | default {
          log debug ($source.name | do $source.fail_warning_msg $source.name)
          null
        }
    }
    | where $it != null
    | first --strict
    | default {
      if $required_for == null {
        {}
      } else {
        error make --unspanned {
          msg: ([
            "failed to get Socorro/crash stats auth. token from the following sources:"
            ""
            ...($sources | get name | each { $"- ($in)" })
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
  (
    _http get "Reprocessing/"
      --auth-required-for "reprocessing"
      { crash_ids: $crash_ids }
  )
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
  --auth-required-for: oneof<string, nothing> = null,
] {
  mut headers = { "User-Agent": "ErichDonGubler-Socorro-Nushell/1.0" }

  if $auth_required_for != null {
    $headers = $headers | merge (
      auth-headers from-auth-token --required-for $auth_required_for
    )
  }

  let req_url = $'https://crash-stats.mozilla.org/api/($url_path)?($query_params | url build-query)'
  http get --headers $headers $req_url
}
