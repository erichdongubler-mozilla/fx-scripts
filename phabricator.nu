const USER_AGENT = "ErichDonGubler-Phabricator-Nushell/1.0"
const DEFAULT_HOST = 'https://phabricator.services.mozilla.com/api/'

# A raw API call helper for Phabricator's Conduit API.
export def "conduit api" [
  method: string,
  params: record = {},
  --host: string = $DEFAULT_HOST,
] {
  let token = token-for-host $host

  let data = { 'api.token': $token } | merge $params

  let response = (
    http post
      --headers { 'User-Agent': $USER_AGENT }
      --content-type 'application/x-www-form-urlencoded'
      --allow-errors
      --full
      $'($host)($method)'
      $data
  )

  if ($response.status not-in 200..=299) or ($response.body.error_code != null) {
    error make --unspanned {
      msg: $"HTTP error ($response.status): ($response.body.error_code): ($response.body.error_info)"
    }
  }

  $response.body.result
}

# Make an API call to Phabricator's `differential.revision.edit` endpoint.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/differential.revision.edit/>
export def "conduit differential revision edit" [
  --fields: record = {}, # Specify transaction fields manually.
] {
  mut transaction = {}

  $transaction = $transaction | merge $fields

  conduit api 'differential.revision.edit' $transaction
}

# Resolve Phabricator monograms to PHIDs via the `phid.lookup` endpoint.
#
# This is the general answer to "what's the PHID for this thing", as opposed to
# reaching for whichever per-type `*.search` endpoint happens to match: one
# call takes a mix of `#project`, `Dnnn`, `@user`, `Tnnn`, and `rREPO`.
#
#     conduit phid lookup '#webgpu-reviewers' --strict | first | get phid
#
# The result is reshaped from `phid.lookup`'s name-keyed record into a table so
# it's pipeline-shaped. The requested monogram is kept as `query`, because the
# endpoint's own `name` field holds the *canonical* name and would collide —
# `#webgpu-reviewers` comes back with `name: webgpu-reviewers`.
#
# `--strict` exists because Conduit **silently omits** names it can't resolve
# rather than erroring, so a typo'd monogram otherwise reads as "no reviewers
# to add" instead of as a mistake.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/phid.lookup/>
export def "conduit phid lookup" [
  ...names: string, # e.g. `#webgpu-reviewers`, `D324727`, `@ErichDonGubler`
  --strict, # Fail if any name did not resolve
]: nothing -> table {
  if ($names | is-empty) {
    # Guarded rather than passed through: `phid.lookup` with no names returns
    # an empty *list*, not an empty record, which the reshaping below can't
    # take.
    error make --unspanned {
      msg: "`conduit phid lookup` needs at least one name"
      help: "e.g. `conduit phid lookup '#webgpu-reviewers'`"
    }
  }

  let resolved = conduit api 'phid.lookup' (
    $names
      | enumerate
      | reduce --fold {} {|it, acc| $acc | insert $"names[($it.index)]" $it.item }
  )
    | transpose query info
    | each {|row| { query: $row.query } | merge $row.info }

  if $strict {
    let missing = $names | where {|name| $name not-in $resolved.query }
    if ($missing | is-not-empty) {
      error make --unspanned {
        msg: $"failed to resolve ($missing | length) name\(s\): ($missing | str join ', ')"
        help: "monograms need their sigil: `#project`, `@user`, `Dnnn`, `Tnnn`"
      }
    }
  }

  $resolved
}

# Make an API call to Phabricator's `user.whoami` endpoint.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/user.whoami/>
export def "conduit user whoami" [
] {
    conduit api 'user.whoami' {}
}

export def "token-for-host" [
  host: string = $DEFAULT_HOST,
] {
  open ~/.arcrc
    | from json
    | get ([ hosts $host token ] | into cell-path)
}
