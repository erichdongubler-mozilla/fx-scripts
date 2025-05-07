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
# See also: <https://phabricator.services.mozilla.com/conduit/method/differential.diff.search/>
export def "conduit differential revision search" [
  # Asdf
  --ids: list<int> = [],
  --query-key: string@'nu-complete differential revision search query-key' = 'active', # A built-in or saved query key.
  --fields: record = {}, # Specify search fields manually
] {
  mut query = {}

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

  conduit api 'differential.revision.search' $query
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
