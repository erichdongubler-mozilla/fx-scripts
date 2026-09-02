const USER_AGENT = "ErichDonGubler-Phabricator-Nushell/1.0"
const DEFAULT_HOST = 'https://phabricator.services.mozilla.com/api/'

# ---------------------------------------------------------------------------
# Query representation
#
# Conduit takes structured input as form-encoded keys with bracketed paths:
#
#     constraints[authorPHIDs][0]=PHID-USER-…&attachments[reviewers]=true&limit=50
#
# Nushell can't form-encode a nested record or a list at all (`http post`
# fails with `can't convert record<…> to string`), so we flatten to leaf paths
# ourselves and render the brackets at the end.
#
# The flat `{path, value}` form doubles as the reconciliation format: layered
# inputs (convenience flags vs. the `--params` escape hatch) collide at leaf
# granularity, which is both the finest and the most predictable place to
# resolve them. Paths are `list<string>` rather than dotted strings so that a
# key which itself contains a dot — `api.token`, Mozilla's `bugzilla.bug-id` —
# stays a single path segment.
# ---------------------------------------------------------------------------

# Flatten a nested record into a table of `{path, value}` leaf rows.
#
# Records recurse. Lists are *leaves*, not recursed into: reconciling at index
# granularity would let a two-layer override splice a new element 0 in front of
# a previous layer's stale elements 1..n. Indices are materialized in
# `conduit encode`, after reconciliation has picked a winning list.
#
# Null leaves are dropped, which is what makes an unpassed flag contribute
# nothing. Conduit has no use for an explicit null, so this costs nothing.
export def "conduit flatten" [
  path: list<string> = [],
]: record -> table<path: list<string>, value: any> {
  items {|key, value|
    if ($value | describe | str starts-with 'record') {
      $value | conduit flatten ($path | append $key)
    } else if $value == null {
      []
    } else {
      [{ path: ($path | append $key), value: $value }]
    }
  } | flatten
}

# Rebuild a nested record from `{path, value}` leaf rows.
export def "conduit unflatten" []: table<path: list<string>, value: any> -> record {
  reduce --fold {} {|row, acc|
    $acc | insert ($row.path | into cell-path) $row.value
  }
}

# Render a nested record as the flat, bracket-keyed record Conduit expects.
export def "conduit encode" []: record -> record {
  conduit flatten | reduce --fold {} {|row, acc|
    let key = $row.path
      | enumerate
      | each {|it| if $it.index == 0 { $it.item } else { $"[($it.item)]" } }
      | str join

    if ($row.value | describe | str starts-with 'list') {
      # An empty list emits no parameters at all, which Conduit reads as
      # "unconstrained" rather than "matches nothing". Callers wanting the
      # latter need a constraint value that says so.
      $row.value | enumerate | reduce --fold $acc {|it, inner|
        $inner | insert $"($key)[($it.index)]" (conduit scalar $it.item)
      }
    } else {
      $acc | insert $key (conduit scalar $row.value)
    }
  }
}

# Render one leaf value as Conduit expects it on the wire.
export def "conduit scalar" [value: any]: nothing -> string {
  if ($value | describe) == 'datetime' {
    # Conduit epoch fields (`createdStart`, `modifiedEnd`, …) are in seconds;
    # Nushell datetimes are nanoseconds.
    ($value | into int) // 1_000_000_000 | into string
  } else {
    $value | into string
  }
}

# Reconcile layered query inputs into one flat table of leaf rows.
#
# Input is a table of `{source, query}`, ordered *lowest precedence first*.
# `source` is a human-readable label (`--author`, `--params`, `(default)`)
# carried through purely so that a collision can name who set what.
#
# `--on-conflict`:
#   error  — refuse when two layers set the same leaf (default)
#   last   — highest-precedence layer wins
#   first  — lowest-precedence layer wins
#
# `error` is the default because it's the only policy that stays open: it can
# be relaxed to `last`/`first` later without breaking callers, where the
# reverse would break them.
export def "conduit reconcile" [
  --on-conflict: string = 'error',
]: table<source: string, query: record> -> table<path: list<string>, value: any, source: string> {
  # Captured up front: a statement between here and the `each` below would
  # drain the implicit pipeline input.
  let layers = $in

  if $on_conflict not-in ['error' 'last' 'first'] {
    error make --unspanned {
      msg: $"`--on-conflict` must be one of `error`, `last`, `first`; got `($on_conflict)`"
    }
  }

  let grouped = $layers
    | each {|layer| $layer.query | conduit flatten | insert source $layer.source }
    | flatten
    | group-by {|row| $row.path | str join '.' }

  # Checked before the mapping below rather than inside it: `error make` from
  # within a closure gets wrapped as "Eval block failed with pipeline input",
  # which buries the message. Reporting up front also surfaces every collision
  # at once instead of only whichever one is visited first.
  if $on_conflict == 'error' {
    let conflicts = $grouped
      | items {|key, rows| { key: $key, rows: $rows } }
      | where {|group| ($group.rows | length) > 1 }

    if ($conflicts | is-not-empty) {
      let detail = $conflicts
        | each {|conflict|
            let who = $conflict.rows
              | each {|row| $"($row.source) = ($row.value | to nuon)" }
              | str join ', '
            $"  ($conflict.key): ($who)"
          }
        | str join "\n"
      error make --unspanned {
        msg: ([
          "conflicting query values:"
          $detail
          "Pass `--on-conflict last` or `--on-conflict first` to pick a winner."
        ] | str join "\n")
      }
    }
  }

  $grouped | items {|key, rows|
    if $on_conflict == 'first' { $rows | first } else { $rows | last }
  }
}

# Merge layered query inputs down to a single nested record.
export def "conduit merge-layers" [
  --on-conflict: string = 'error',
]: table<source: string, query: record> -> record {
  conduit reconcile --on-conflict $on_conflict | conduit unflatten
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------
# A raw API call helper for Phabricator's Conduit API.
#
# `params` is a *nested* record mirroring the shapes in Conduit's method docs;
# bracket-encoding is handled here.
export def "conduit api" [
  method: string,
  params: record = {},
  --host: string = $DEFAULT_HOST,
  --dry-run, # Return the encoded parameters instead of sending them.
] {
  let encoded = $params | conduit encode

  if $dry_run {
    # NOTE: Do this before the token to exclude it.
    return $encoded
  }

  let token = token-for-host $host

  let data = { 'api.token': $token } | merge $encoded

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

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

# Make an API call to Phabricator's `differential.revision.edit` endpoint.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/differential.revision.edit/>
export def "conduit differential revision edit" [
  phid: oneof<nothing, string> = null,
  --author: oneof<nothing, string@"nu-complete conduit differential revision author">
  --reviewers: oneof<nothing, record<add: list<string> remove: list<string> set: list<string>>>
  --children: record<add: list<string> remove: list<string> set: list<string>>
  --parents: record<add: list<string> remove: list<string> set: list<string>>
  --fields: record = {}, # Specify transaction fields manually.
] {
  mut transaction = {}

  $transaction = $transaction | merge $fields

  conduit api 'differential.revision.edit' $transaction
}

# Make an API call to Phabricator's `differential.revision.search` endpoint.
#
# Convenience flags and the `--params` escape hatch are reconciled at leaf
# granularity, so `--params` may carry whole subtrees the flags don't model
# without clobbering what the flags did set. Setting the same leaf both ways
# is an error unless `--on-conflict` says otherwise.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/differential.revision.search/>
export def "conduit differential revision search" [
  # Asdf
  --ids: list<int> = [],
  --query-key: string@'nu-complete differential revision search query-key' = 'active', # A built-in or saved query key.
  --ids: list<int>, # Revision IDs, e.g. `[123456]` for D123456
  --phids: list<string>, # Revision PHIDs
  --authors: list<string>, # Author PHIDs
  --reviewers: list<string>, # Reviewer PHIDs
  --responsible: list<string>, # PHIDs of users responsible (author or reviewer)
  --repositories: list<string>, # Repository PHIDs
  --statuses: list<string>, # e.g. `[open]`, `[needs-review abandoned]`
  --created-after: datetime,
  --created-before: datetime,
  --modified-after: datetime,
  --modified-before: datetime,
  --search: string, # Fulltext query
  --attachments: list<string>, # e.g. `[reviewers projects]`
  --order: any, # An order constant, or a list of columns
  --limit: int,
  --page-after: string, # Paging cursor from a previous `cursor.after`
  --page-before: string, # Paging cursor from a previous `cursor.before`
  --params: record, # Escape hatch: arbitrary envelope parameters
  --on-conflict: string = 'error', # `error`, `last`, or `first`
  --dry-run, # Return the encoded parameters instead of sending them
] {
  let query = [
    # Lowest precedence first. Any default belongs in a layer of its own here,
    # *below* the escape hatch — a default that outranks `--params` welds the
    # escape hatch shut for that leaf.
    { source: '--params', query: ($params | default {}) }
    {
      source: '(flags)',
      query: {
        constraints: {
          ids: $ids,
          phids: $phids,
          authorPHIDs: $authors,
          reviewerPHIDs: $reviewers,
          responsiblePHIDs: $responsible,
          repositoryPHIDs: $repositories,
          statuses: $statuses,
          createdStart: $created_after,
          createdEnd: $created_before,
          modifiedStart: $modified_after,
          modifiedEnd: $modified_before,
          query: $search,
        },
        attachments: (
          $attachments
            | default []
            | reduce --fold {} {|name, acc| $acc | insert $name true }
        ),
        order: $order,
        limit: $limit,
        after: $page_after,
        before: $page_before,
      },
    }
  ] | conduit merge-layers --on-conflict $on_conflict

  $query = $query | merge $fields

  if ($ids | is-not-empty) {
    let id_constraints = $ids
      | enumerate
      | reduce --fold {} {|it, acc|
        $acc | merge {
          $'constraints[ids][($it.index)]': $it.item
        }
      }
    $constraints = $constraints | merge $id_constraints
  }

  let query = ({
    'queryKey': $query_key
  } | merge $constraints)

  conduit api 'differential.revision.search' $query --dry-run=$dry_run
}

def "nu-complete differential revision search query-key" [] {
  [
    'active'
    'all'
  ]
}

def "nu-complete revision author" [] {
  conduit api 'users.search'
}

def "nu-complete revision testing-tag" [] {
  revision testing-tags | each {
    {
      value: $in.phid
      description: $in.fields.name
      style: {
        fg: $in.fields.color.key
      }
    }
  }
}

export def "revision testing-tags" [] {
  conduit api 'project.search' {
    'constraints[icons][0]': 'tag'
    'constraints[query]': 'testing'
  } | get data
}

# A convenience API over `phabricator conduit differential revision edit`.
export def "revision submit-comment" [
  object_identifier: oneof<nothing, string> = null,
  --comment: oneof<nothing, string> = null,
  --testing-tag: oneof<nothing, string@'nu-complete revision testing-tag'> = null,
  --author: oneof<nothing, string@"nu-complete revision author"> = null,
  --commandeer,
  # A convenience that does the same as `--author (phabricator conduit user whoami).phid`.
] {
  # Get the current revision
  mut search_fields = {
    'queryKey': 'all'
  }

  # if ($phid != null) {
  #   # TODO: validate this works
  #   $search_fields = $search_fields | merge { 'constraints[phids][0]': $phid }
  # }
  # 
  # if ($id != null) {
  #   # TODO: validate this works
  #   $search_fields = $search_fields | merge { 'constraints[ids][0]': $id }
  # }
  # 
  # if ($diff_id != null) {
  #   # TODO: validate this works
  #   let id = $diff_id | parse 'D{id}' | first --strict
  #   $search_fields = $search_fields | merge { 'constraints[ids][0]': $diff_id }
  # }

  let search_results = conduit differential revision search --fields $search_fields
    | get data

  let current_revision_fields = match ($search_results | length) {
    0 => {
      # TODO: refine
      error make {
        msg: "no thingy found"
      }
    }
    1 => {
      $search_results | first --strict
    }
    _ => {
      # TODO: refine
      error make {
        msg: "too many thingies"
      }
    }
  }

  mut transaction = {}

  if ($author != null) and $commandeer {
    error make {
      msg: "`--author` and `--commandeer` cannot be used at the same time"
      labels: [
        {
          text: ''
          span: (metadata $author).span
        }
        {
          text: ''
          span: (metadata $commandeer).span
        }
      ]
    }
  }

  if $commandeer {
    $transaction = $transaction | merge { 'author': (conduit user whoami).phid }
  }

  if ($author != null) {
    $transaction = $transaction | merge { 'author': $author }
  }

  if ($comment != null) {
    $transaction = $transaction | merge { 'comment': $comment }
  }

  if ($testing_tag != null) {
    # TODO: Validate this works.
    $transaction = $transaction | merge { 'project': $comment }
  }

  conduit differential revision edit $current_revision_fields.phid --fields $transaction
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
