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

    $acc | merge (conduit encode-value $key $row.value)
  }
}

# Expand one flattened leaf into the bracket-keyed pairs Conduit expects.
#
# `conduit flatten` stops descending at lists, so what arrives here is either a
# scalar or a list — and a list's elements may themselves be records, as in
# `differential.revision.edit`'s `transactions`:
#
#     transactions[0][type]=commandeer&transactions[0][value]=true
#
# Everything below a list index is therefore materialized here rather than in
# `conduit flatten`, which is the same reason indices themselves are: it all
# happens after reconciliation has picked a winning list.
export def "conduit encode-value" [
  key: string,
  value: any,
]: nothing -> record {
  let type = $value | describe

  # `table<…>` rather than `list<…>` is what `describe` reports for a list
  # whose elements are records of a uniform shape — `transactions`, notably —
  # so both spellings have to be treated as the same indexed sequence.
  if ($type | str starts-with 'list') or ($type | str starts-with 'table') {
    # An empty list emits no parameters at all, which Conduit reads as
    # "unconstrained" rather than "matches nothing". Callers wanting the
    # latter need a constraint value that says so.
    $value | enumerate | reduce --fold {} {|it, acc|
      $acc | merge (conduit encode-value $"($key)[($it.index)]" $it.item)
    }
  } else if ($type | str starts-with 'record') {
    $value
      | items {|name, inner| conduit encode-value $"($key)[($name)]" $inner }
      | reduce --fold {} {|pairs, acc| $acc | merge $pairs }
  } else {
    {} | insert $key (conduit scalar $value)
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

  # Conduit reports its own errors in a 200 body, so the two failure modes are
  # worth distinguishing: a non-2xx means the request never reached the method,
  # while `error_code` means it did and the method refused.
  if $response.status not-in 200..=299 {
    error make --unspanned {
      msg: $"HTTP ($response.status) from `($method)`: ($response.body | to text)"
    }
  }

  if $response.body.error_code != null {
    error make --unspanned {
      msg: $"`($method)` failed: ($response.body.error_code): ($response.body.error_info)"
    }
  }

  $response.body.result
}

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

# The verbs Conduit pairs with every list-valued field on `revision.edit`:
# `reviewers.add`, `projects.set`, `parents.remove`, and so on.
#
# Ordered `set`, `remove`, `add` rather than alphabetically, because that's the
# order in which combining them stays meaningful: `set` replaces wholesale, so
# emitting it first lets `--reviewers {set: [a], add: [b]}` read as "replace
# with `a`, plus `b`". The reverse order would have `set` silently eat the
# `add`.
const EDIT_VERBS = ['set' 'remove' 'add']

# Emit zero or one transaction, so an unpassed flag contributes nothing.
#
# `conduit flatten` drops nulls for exactly this reason, but it can't help
# here: a null sitting *inside* a list is invisible to it, and `transactions`
# is a list.
def "conduit edit-transaction" [
  type: string,
  value: any,
]: nothing -> list<record> {
  if $value == null { [] } else { [{ type: $type, value: $value }] }
}

# Expand one `{set?, remove?, add?}` record into `<field>.<verb>` transactions.
#
# The flags feeding this are typed as a bare `record`, not
# `record<add: list<string>, remove: list<string>, set: list<string>>`:
# Nushell's record annotations are *exact*, so the fully-spelled type rejects
# `{add: [x]}` at parse time and would force every caller to pad out all three
# keys. Validating here costs a runtime check and buys a usable signature —
# and `span` is threaded in so a typo'd key can point at the caller's argument
# instead of at this module.
def "conduit edit-verb-transactions" [
  field: string,
  value: any,
  span: any,
]: nothing -> list<record> {
  if $value == null { return [] }

  let unknown = $value | columns | where {|key| $key not-in $EDIT_VERBS }
  if ($unknown | is-not-empty) {
    error make {
      msg: $"`--($field)` has unrecognized key\(s\): ($unknown | str join ', ')"
      label: {
        text: $"expected only: ($EDIT_VERBS | str join ', ')"
        span: $span
      }
    }
  }

  $EDIT_VERBS
    | where {|verb| $verb in ($value | columns) }
    | each {|verb| { type: $"($field).($verb)", value: ($value | get $verb) } }
}

# Make an API call to Phabricator's `differential.revision.edit` endpoint.
#
# Unlike `search`, this endpoint's payload is an *ordered list* of
# `{type, value}` transactions rather than a tree of constraints, so the
# convenience flags here concatenate instead of reconciling: each one that is
# passed appends *zero or more* transactions, in the order the parameters are
# declared below, and `--transactions` is appended last so a raw transaction
# can follow whatever the flags built. The body is one flat ordered list so
# that "declaration order" is literally true rather than merely intended.
#
# `revision` is an `objectIdentifier`, which accepts any of a bare ID
# (`123456`), a monogram (`D123456`), or a revision PHID.
#
# The list-valued fields — `--reviewers`, `--projects`, `--parents`, … — take a
# `{set?, remove?, add?}` record rather than one flag per verb, which is what
# keeps six fields from spending eighteen flags. See
# `conduit edit-verb-transactions` for why they aren't annotated as
# `record<add: …, remove: …, set: …>`.
#
# Note that `--commandeer` takes over as *the user owning the API token* and
# takes no PHID. To install someone else as author, use `--author`, which is a
# Mozilla-local transaction type not present upstream. Passing both is refused,
# since they'd race to write the same field.
#
# The authoritative list of transaction types for a given instance can be
# coaxed out of Conduit by sending a bogus one — the rejection enumerates them:
#
#     conduit differential revision edit 1 --transactions [{type: 'x', value: true}]
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/differential.revision.edit/>
export def "conduit differential revision edit" [
  revision: oneof<int, string>, # Revision ID, monogram, or PHID
  --title: string,
  --summary: string,
  --test-plan: string,
  --author: string, # Author PHID. Mozilla-specific; upstream has no such type
  --bug: oneof<int, string>, # Bugzilla bug ID
  --repository: string, # Repository PHID
  --diff: string, # Diff PHID to update the revision to
  # Each of these takes any subset of `{set, remove, add}` of PHIDs, e.g.
  # `--reviewers {add: [PHID-USER-…]}`.
  --reviewers: record,
  --subscribers: record,
  --projects: record,
  --parents: record,
  --children: record,
  --tasks: record,
  # A `projects.add` shorthand that can actually be tab-completed, which
  # `--projects` can't be: Nushell hangs completers off a flag's value, and
  # there's no completion for record keys.
  --testing-tag: string@"nu-complete conduit project testing-tag",
  --commandeer, # Take over authorship, as the user owning the API token
  --request-review,
  --plan-changes,
  --accept,
  --reject,
  --resign,
  --abandon,
  --reclaim,
  --draft,
  --comment: string, # Appended after the flags above, so it reads as one action
  --transactions: list<record>, # Escape hatch: raw `{type, value}` rows
  --dry-run, # Return the encoded parameters instead of sending them
] {
  # Both write the `author` field, so allowing both would make the outcome
  # depend on which transaction Phabricator happens to apply last.
  if ($author != null) and $commandeer {
    error make {
      msg: "`--author` and `--commandeer` both set authorship"
      label: {
        text: "conflicts with `--commandeer`, which installs the token's owner"
        span: (metadata $author).span
      }
      help: "drop one; `--commandeer` needs no PHID"
    }
  }

  let transactions = [
    (conduit edit-transaction 'title' $title)
    (conduit edit-transaction 'summary' $summary)
    (conduit edit-transaction 'testPlan' $test_plan)
    (conduit edit-transaction 'author' $author)
    (conduit edit-transaction 'bugzilla.bug-id' ($bug | each { into string }))
    (conduit edit-transaction 'repositoryPHID' $repository)
    (conduit edit-transaction 'update' $diff)
    (conduit edit-verb-transactions 'reviewers' $reviewers (metadata $reviewers).span)
    (conduit edit-verb-transactions 'subscribers' $subscribers (metadata $subscribers).span)
    (conduit edit-verb-transactions 'projects' $projects (metadata $projects).span)
    (conduit edit-verb-transactions 'parents' $parents (metadata $parents).span)
    (conduit edit-verb-transactions 'children' $children (metadata $children).span)
    (conduit edit-verb-transactions 'tasks' $tasks (metadata $tasks).span)
    (conduit edit-transaction 'projects.add' ($testing_tag | each { [$in] }))
    # Conduit reads these as booleans, and a form-encoded `false` is a
    # non-empty string — i.e. still truthy. So an unset flag must drop the
    # whole row rather than send `false`.
    (conduit edit-transaction 'commandeer' (if $commandeer { true }))
    (conduit edit-transaction 'request-review' (if $request_review { true }))
    (conduit edit-transaction 'plan-changes' (if $plan_changes { true }))
    (conduit edit-transaction 'accept' (if $accept { true }))
    (conduit edit-transaction 'reject' (if $reject { true }))
    (conduit edit-transaction 'resign' (if $resign { true }))
    (conduit edit-transaction 'abandon' (if $abandon { true }))
    (conduit edit-transaction 'reclaim' (if $reclaim { true }))
    (conduit edit-transaction 'draft' (if $draft { true }))
    (conduit edit-transaction 'comment' $comment)
    ($transactions | default [])
  ] | flatten

  if ($transactions | is-empty) {
    error make --unspanned {
      msg: "no transactions to apply; `differential.revision.edit` would be a no-op"
      help: "pass a convenience flag or `--transactions`"
    }
  }

  (
    conduit api 'differential.revision.edit' {
      objectIdentifier: ($revision | conduit revision-identifier)
      transactions: $transactions
    }
      --dry-run=$dry_run
  )
}

# Normalize a revision reference into something `objectIdentifier` accepts.
#
# A bare int is rendered as a monogram rather than passed through: Conduit
# resolves a bare number as an ID, but the monogram is what shows up in error
# messages, and `D123456` is unambiguous against a PHID.
export def "conduit revision-identifier" []: oneof<int, string> -> string {
  let revision = $in

  if ($revision | describe) == 'int' {
    $"D($revision)"
  } else if ($revision | str starts-with 'PHID-') {
    $revision
  } else if ($revision | str starts-with 'D') {
    $revision
  } else {
    $"D($revision)"
  }
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
  # A builtin or saved query key. Deliberately undefaulted: Conduit treats an
  # absent `queryKey` as "constraints only", so defaulting it to `active` (as
  # an earlier draft of this module did) silently narrows every search that
  # didn't ask for it.
  --query-key: string@"nu-complete conduit differential revision query-key",
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
        queryKey: $query_key,
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

  conduit api 'differential.revision.search' $query --dry-run=$dry_run
}

# Phabricator's builtin revision queries. Saved queries have opaque key
# strings too, so this is a menu of the common ones rather than a closed set —
# `--query-key` stays a plain `string`, and Conduit rejects a bad key clearly:
# `Query key "…" does not correspond to a valid query.`
def "nu-complete conduit differential revision query-key" [] {
  {
    completions: [
      { value: 'active', description: 'Open revisions relevant to you' }
      { value: 'authored', description: 'Revisions you authored' }
      { value: 'all', description: 'All revisions' }
    ]
    options: { sort: false }
  }
}

# Make an API call to Phabricator's `project.search` endpoint.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/project.search/>
export def "conduit project search" [
  --ids: list<int>,
  --phids: list<string>,
  --slugs: list<string>, # Project hashtags, without the `#`
  --icons: list<string>, # e.g. `[tag]`, `[group]`, `[folder]`
  --colors: list<string>,
  --search: string, # Fulltext query
  --limit: int,
  --params: record, # Escape hatch: arbitrary envelope parameters
  --on-conflict: string = 'error', # `error`, `last`, or `first`
  --dry-run, # Return the encoded parameters instead of sending them
] {
  let query = [
    { source: '--params', query: ($params | default {}) }
    {
      source: '(flags)',
      query: {
        constraints: {
          ids: $ids,
          phids: $phids,
          slugs: $slugs,
          icons: $icons,
          colors: $colors,
          query: $search,
        },
        limit: $limit,
      },
    }
  ] | conduit merge-layers --on-conflict $on_conflict

  conduit api 'project.search' $query --dry-run=$dry_run
}

# Mozilla's review-testing tags: `testing-approved`, `needs-testing-tag`, and
# the `testing-exception-*` family.
#
# There's no endpoint for these — they're ordinary Phabricator projects, so the
# only handle on them is the `tag` icon (which is what makes a project render
# as a review tag) narrowed by a `testing` fulltext query.
export def "conduit project testing-tags" [] {
  conduit project search --icons ['tag'] --search 'testing' | get data
}

# Completions for `--testing-tag`, carrying each tag's own Phabricator color
# through to the menu.
#
# The `value` has to be the PHID, since that's what `projects.add` accepts —
# which makes this a *pick-from-menu* completer, not a type-a-prefix one. That
# works because there are only a handful of tags. The same treatment does not
# work for users, which is why there's no `--author` completer: matching is
# done against `value`, so a PHID-valued menu of thousands of users can't be
# narrowed by typing a username.
def "nu-complete conduit project testing-tag" [] {
  conduit project testing-tags | each {|tag|
    {
      value: $tag.phid
      description: $tag.fields.name
      style: { fg: $tag.fields.color.key }
    }
  }
}

# Make an API call to Phabricator's `user.search` endpoint.
#
# Note the singular: `users.search` (as an earlier draft of this module had it)
# does not exist.
#
# Beware that `--usernames` *silently drops* names it can't resolve rather than
# erroring, so anything resolving a name to a PHID should compare the result
# count against the input count itself.
#
# See also: <https://phabricator.services.mozilla.com/conduit/method/user.search/>
export def "conduit user search" [
  --ids: list<int>,
  --phids: list<string>,
  --usernames: list<string>,
  --name-like: string,
  --search: string, # Fulltext query
  --limit: int,
  --params: record, # Escape hatch: arbitrary envelope parameters
  --on-conflict: string = 'error', # `error`, `last`, or `first`
  --dry-run, # Return the encoded parameters instead of sending them
] {
  let query = [
    { source: '--params', query: ($params | default {}) }
    {
      source: '(flags)',
      query: {
        constraints: {
          ids: $ids,
          phids: $phids,
          usernames: $usernames,
          nameLike: $name_like,
          query: $search,
        },
        limit: $limit,
      },
    }
  ] | conduit merge-layers --on-conflict $on_conflict

  conduit api 'user.search' $query --dry-run=$dry_run
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
