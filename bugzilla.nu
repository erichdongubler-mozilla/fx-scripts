use std/log

const HOST = "https://bugzilla.mozilla.org"

def "auth-headers from-api-key" [
  --required-for: string | null = null,
] {
  try {
    {
      'X-BUGZILLA-API-KEY': $env.BUGZILLA_API_KEY
    }
  } catch {
    if $required_for == null {
      {}
    } else {
      error make --unspanned {
        msg: ([
          "failed to get Bugzilla API key via `BUGZILLA_API_KEY` environment variable, "
          $"and it's required for ($required_for)"
        ] | str join)
      }
    }
  }
}

def "rest-api get-json" [
  url_path: string,
  --auth-required-for: string | null = null,
]: nothing -> any {
  use std/log [] # set up `log` cmd. state

  let full_url = $"($HOST)/rest/($url_path)"
  log debug $"`GET`ting ($full_url | to nuon)"

  mut headers = {
    "Content-Type": "application/json"
    "Accept": "application/json"
  }
  $headers = $headers | merge (auth-headers from-api-key --required-for $auth_required_for)

  let response = http get $full_url --headers $headers
  if ("error" in $response and $response.error) {
    error make {
      msg: $"error returned ($response.code): ($response.message)"
      labels: [
        text: ""
        span: (metadata $url_path).span
      ]
    }
  }
  $response
}

def "rest-api post-json" [
  url_path: string,
  input: any,
  what: string = "`POST` request"
] {
  use std/log [] # set up `log` cmd. state

  let full_url = $"($HOST)/rest/($url_path)"
  log debug $"`POSTING`ting ($full_url | to nuon)"

  let headers = auth-headers from-api-key --required-for $what

  http post --headers $headers --content-type "application/json" $full_url $input
}

def "rest-api put-json" [
  url_path: string,
  input: any,
  what: string = "`PUT` request"
] {
  use std/log [] # set up `log` cmd. state

  let full_url = $"($HOST)/rest/($url_path)"
  log debug $"`PUT`ting ($full_url | to nuon)"

  let headers = auth-headers from-api-key --required-for $what

  http put --headers $headers --content-type "application/json" $full_url $input
}

# Create a bug via the `Create Bug` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#create-bug>
export def "bug create" [
  input: record<product: string component: string type: string version: string>,
] {
  rest-api post-json "bug" $input "bug creation"
}

# Fetch a single bug via the `Search Bugs` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#search-bugs>
export def "bug get" [
  id_or_alias: any
  --output-fmt: string@"nu-complete bugs output-fmt" = "buglist",
] {
  use std/log [] # set up `log` cmd. state

  let bugs = search $id_or_alias --output-fmt $output_fmt
  match ($bugs | length) {
    1 => { $bugs | first }
    0 => {
        error make --unspanned {
        msg: "no bug found"
      }
    }
    _ => {
      error make --unspanned {
        msg: $"multiple bugs found: ($bugs | get id | to nuon)"
      }
    }
  }
}

# Update a bug via the `Update Bug` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#rest-update-bug>
export def "bug update" [
  id_or_alias: any,
  input: any,
] {
  rest-api put-json $'bug/($id_or_alias)' $input "bug update"
}

# Apply a filter to the raw data of a bug returned by `bugzilla bug get` and the like.
export def "bugs apply-output-fmt" [
  fmt: string@"nu-complete bugs output-fmt"
]: table<id: any type: any summary: any product: any assigned_to_detail: record<email: string> status: any resolution: any last_change_time: any> -> any {
  use std/log [] # set up `log` cmd. state

  let bugs = $in
  match $fmt {
    "full" => { $bugs }
    "buglist" => {
      # NOTE: This tries to emulate the format found in `buglist.cgi`.
      $bugs
        | select id type summary product component assigned_to_detail status resolution last_change_time
        | update assigned_to_detail { get email }
        | rename --column { assigned_to_detail: assigned_to_detail.email }
        | into value
    }
    _ => {
      error make {
        msg: $"unrecognized output format ($fmt | to nuon)"
        label: {
          text: "provided here"
          span: (metadata $fmt).span
        }
      }
    }
  }
}

def "bugs parse-response" []: any -> any {
  let response = $in
  if not ("faults" in $response) or ($response.faults | is-empty) {
    $response.bugs
  } else {
    error make --unspanned {
      msg: $"`faults` found in response: ($response.faults | to nuon)"
    }
  }
}

def "nu-complete bugs output-fmt" [] {
  [
    "full"
    "buglist"
  ]
}

# Look up multiple bugs using the `quicksearch` field in the `Search Bugs` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#search-bugs>
export def "quicksearch" [
  query: string,
  --output-fmt: string@"nu-complete bugs output-fmt" = "buglist",
] {
  use std/log [] # set up `log` cmd. state

  search --criteria { quicksearch: $query } --output-fmt $output_fmt
}

# Look up multiple bugs via the `Search Bugs` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#search-bugs>
export def "search" [
  id_or_alias?: string,
  --criteria: record = {},
  --output-fmt: string@"nu-complete bugs output-fmt" = "buglist",
] {
  use std/log [] # set up `log` cmd. state

  mut criteria = $criteria
  let final_path_segment = if $id_or_alias == null {
    ""
  } else {
    $"/($id_or_alias)"
  }
  rest-api get-json $"bug($final_path_segment)?($criteria | url build-query)"
    | bugs parse-response
    | bugs apply-output-fmt $output_fmt
}

export def "whoami" []: nothing -> record<id: int real_name: string nick: string name: string> {
  rest-api get-json "whoami" --auth-required-for "`whoami` queries"
}
