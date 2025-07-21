use std/log

const HOST = "https://bugzilla.mozilla.org"

const USER_AGENT_HEADER = { "User-Agent": "ErichDonGubler-Bugzilla-Nushell/1.0" }

def "auth-headers from-api-key" [
  --required-for: string | null = null,
] {
  use std/log [] # set up `log` cmd. state

  mut api_key = null

  const env_var_name = 'BUGZILLA_API_KEY'
  try {
    $api_key = $env | get $env_var_name
  } catch {
    log debug $"no `($env_var_name)` defined"
  }

  const config_path = $'($nu.home-path)/.config/bugzilla.toml'
  const toml_key = 'api_key'
  if $api_key == null {
    try {
      $api_key = open $config_path | get $toml_key
    } catch {
      log debug $"failed to access `($toml_key)` field in `($config_path)`"
    }
  }

  if $api_key != null {
    {
      'X-BUGZILLA-API-KEY': $api_key
    }
  } else {
    if $required_for == null {
      {}
    } else {
      error make --unspanned {
        msg: ([
          "failed to get Bugzilla API key from the following sources:"
          $"- `($env_var_name)` environment variable"
          $"- `($toml_key)` field in `($config_path)`"
          ""
          $"…and at least one is required for ($required_for)."
        ] | str join "\n")
      }
    }
  }
}

def "rest-api get-json" [
  url_path: string,
  --auth-required-for: oneof<nothing, string> = null,
]: nothing -> any {
  use std/log [] # set up `log` cmd. state

  let full_url = $"($HOST)/rest/($url_path)"
  log debug $"`GET`ting ($full_url | to nuon)"

  mut headers = {
    "Content-Type": "application/json"
    "Accept": "application/json"
  }
  $headers = $headers
    | merge $USER_AGENT_HEADER
    | merge (auth-headers from-api-key --required-for $auth_required_for)

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
  log debug $"`POST`ing to ($full_url | to nuon) with input ($input | to nuon)"

  let headers = auth-headers from-api-key --required-for $what
    | merge $USER_AGENT_HEADER

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
    | merge $USER_AGENT_HEADER

  http put --headers $headers --content-type "application/json" $full_url $input
}

# Create a bug via the `Create Bug` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#create-bug>
export def "bug create" [
  --assign-to-me,
  --type: oneof<nothing, string@"nu-complete bug type"> = null,
  --summary: oneof<nothing, string> = null,
  --description: oneof<nothing, string> = null,
  --product: oneof<nothing, string> = null,
  --component: oneof<nothing, string> = null,
  --priority: oneof<nothing, string@"nu-complete bug field priority"> = null,
  --severity: oneof<nothing, string@"nu-complete bug field severity"> = null,
  --version: string = "unspecified",
  --extra: record = {},
] {
  use std/log [] # set up `log` cmd. state

  let input = $extra
    | merge_with_input "assigned_to" "--assign-to-me" (
      if $assign_to_me { (whoami | get name) } else { null }
    )
    | merge_with_input "type" "--type" $type
    | merge_with_input "summary" "--summary" $summary
    | merge_with_input "description" "--description" $description
    | merge_with_input "product" "--product" $product
    | merge_with_input "component" "--component" $component
    | merge_with_input "priority" "--priority" $priority
    | merge_with_input "severity" "--severity" $severity
    | merge_with_input "version" "--version" $version

  rest-api post-json "bug" $input "bug creation"
}

export def "bug field" [
  id_or_name: oneof<int, string>,
]: nothing -> record<name: string, id: int, type: int, display_name: string, values: list<record<name: string>>> {
  let fields = rest-api get-json $'field/bug/($id_or_name)'
    | parse-response get "fields"

  match ($fields | length) {
    0 => (error make --unspanned {
      msg: "internal error: service returned an empty list of matching fields"
    })
    1 => ($fields | first )
    $len => (error make --unspanned {
      msg: $"internal error: service returned ($len) matching fields"
    })
  }
}

def "bug field-values to-completions" [
]: record<values: list<record<name: string>>> -> list<string> {
  get values | get name
}

# Fetch a single bug via the `Bug Get` API:
# <https://bmo.readthedocs.io/en/latest/api/core/v1/bug.html#get-bug>
export def "bug get" [
  id_or_alias: oneof<int, string>,
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
  id_or_alias: oneof<int, string>,
  input: any,
] {
  rest-api put-json $'bug/($id_or_alias)' $input "bug update" | get bugs
}

# Apply a filter to the raw data of a bug returned by `bugzilla bug get` and the like.
export def "bugs apply-output-fmt" [
  fmt: string@"nu-complete bugs output-fmt"
]: table<id: int type: any summary: any product: any assigned_to_detail: record<email: string> status: any resolution: any last_change_time: any> -> any {
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

def "ids-or-names to-record" []: list<oneof<int, string>> -> record<ids: list<int>, names: list<string>> {
  reduce --fold {} {|id_or_name, acc|
    match ($id_or_name | describe) {
      "int" => {
        $acc | upsert ids { default [] | append $id_or_name }
      }
      "string" => {
        $acc | upsert names { default [] | append $id_or_name }
      }
      $type => {
        error make --unspanned {
          msg: ([
            $"internal error: unexpected type `($type)` "
            "in element of `$ids_or_names`"
          ] | str join)
        }
      }
    }
  }
}

def "ids-or-names to-url" []: list<oneof<int, string>> -> record<ids: list<int>, names: list<string>> {
  let ids_or_names = $in

  match ($ids_or_names | length) {
    0 => {
      error make {
        msg: "internal error: empty list provided to `ids-or-names to-url`"
        span: (metadata $ids_or_names).span
      }
    }
    1 => {
      $"/($ids_or_names | first)"
    }
    _ => {
      $ids_or_names | ids-or-names to-record | $"?($in | url build-query)"
    }
  }
}

def "merge_with_input" [
  field_name: string,
  option_name: string,
  option_value: any,
]: record -> record {
  mut input = $in

  if $option_value != null {
    if $field_name in $input {
      log warning ([
        "conflicting assignment info. provided; "
        $"both the option `($option_name)` and the `($field_name)` field "
        $"in `extra` \(($input | get $field_name | to nuon)\) "
        "were specified; resolving with the option's value"
      ] | str join)
    }
    $input = $input | merge ({} | insert $field_name $option_value)
  }

  $input
}

def "nu-complete bug field priority" [] {
  bug field 'priority' | bug field-values to-completions
}

def "nu-complete bug field severity" [] {
  bug field 'bug_severity' | bug field-values to-completions
}

def "nu-complete product list output-fmt" [] {
  [
    "full"
    "ids-only"
  ]
}

def "nu-complete product type" [] {
  [
    "selectable"
    "enterable"
    "accessible"
  ]
}

def "nu-complete bug type" [] {
  [
    "defect"
    "task"
    "enhancement"
  ]
}

def "parse-response get" [success_field_name: string]: any -> any {
  let response = $in
  if not ("faults" in $response) or ($response.faults | is-empty) {
    $response | get $success_field_name
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

export def "product get" [
  ...ids_or_names: oneof<int, string>,
]: nothing -> list<record<products: list<record>>> {
  if ($ids_or_names | is-empty) {
    error make --unspanned {
      msg: "no ID(s) or name(s) specified"
      label: {
        span: (metadata $ids_or_names).span
      }
    }
  }

  rest-api get-json $'product($ids_or_names | ids-or-names to-url)'
    | parse-response get "products"
}

export def "product list" [
  --type: string@"nu-complete product type" = "enterable",
  --output-fmt: string@"nu-complete product list output-fmt" = "full",
]: nothing -> record<ids: list<int>> {
  match $output_fmt {
    "full" => {
      # NOTE: We don't use `product get` here to sidestep validation for a non-zero number of ID(s)
      # or name(s).
      rest-api get-json $'product?type=($type)' | parse-response get "products"
    }
    "ids-only" => {
      rest-api get-json $'product_($type)' | parse-response get "ids"
    }
    _ => {
      error make {
        msg: $"unrecognized output format `($output_fmt)`"
        label: {
          span: (metadata $output_fmt).span
        }
      }
    }
  }
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
  id_or_alias?: oneof<int, string>,
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
    | parse-response get "bugs"
    | bugs apply-output-fmt $output_fmt
}

export def "user get" [
  --match: oneof<nothing, string> = null,
  ...ids_or_names: oneof<int, string>,
]: nothing -> record<> {
  if $match == null and ($ids_or_names | is-empty) {
    error make --unspanned {
      msg: "no ID(s), name(s), or `--match` string provided"
    }
  }

  if $match != null and ($ids_or_names | is-not-empty) {
    error make {
      msg: ([
        "both `--match` and ID(s)/name(s) were specified"
      ] | str join)
      label: {
        text: ""
        span: (
          [
            (metadata $ids_or_names).span
            (metadata $match).span
          ] | {
            start: ($in | get start | math min)
            end: ($in | get end | math max)
          }
        )
      }
      help: "only one at a time is supported"
    }
  }

  match ($ids_or_names | length) {
    0 => {
      # NOTE: We checked that `--match` must be populated above.
      rest-api get-json $"user?match=($match)"
    }
    _ => {
      # NOTE: We checked that `--match` must not be populated above.
      rest-api get-json $'user($ids_or_names | ids-or-names)'
    }
  }
    | parse-response get "users"
}

export def "whoami" []: nothing -> record<id: int real_name: string nick: string name: string> {
  rest-api get-json "whoami" --auth-required-for "`whoami` queries"
}
