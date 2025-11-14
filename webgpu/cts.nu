use std/log

const BUGZILLA = path self "../bugzilla.nu"
use $BUGZILLA

const TIME = path self '../time.nu'
use $TIME

const WEBGPU_CONSTANTS = path self './constants.nu'

const WEBGPU_UPDATE_CTS_BUG_ID = 1863146 # `webgpu-update-cts`

export def "begin-revendor" [
  --bug: oneof<nothing, int, string> = null,
  --revision: oneof<nothing, string> = null,
  --assigned-to: oneof<nothing, string> = null,
] {
  use std/log [] # set up `log` cmd. state

  let mach_cmd = try {
    which ./mach | first | get command
  } catch {
    error make --unspanned {
      msg: "failed to find `./mach` script in the CWD."
    }
  }

  let revision = $revision
    | each {
      # Normalize the commit ref. to a full SHA-1 hash.
      http get $'https://api.github.com/repos/gpuweb/cts/commits/($in)'
        | get sha
    }
    | default {
      gh current-mainline-commit gpuweb cts
    }

  let bug_id = $bug | default {
    let assigned_to = $assigned_to | default { bugzilla whoami | get name }
    let new_bug_id = try {
      (
        bugzilla bug create
          --summary $"Update WebGPU CTS to upstream \(week of (time monday-of-this-week)\)"
          --extra {
            assigned_to: $assigned_to
            blocks: $WEBGPU_UPDATE_CTS_BUG_ID
            priority: P1
          }
      ) | get id
    } catch {
      error make --unspanned {
        msg: $"failed to create new revendoring bug as dependency of bug ($WEBGPU_UPDATE_CTS_BUG_ID)"
      }
    }

    log info $"filed bug ($new_bug_id)"

    $new_bug_id
  }

  let moz_yaml_path = 'dom/webgpu/tests/cts/moz.yaml'
  try {
    ^$mach_cmd vendor $moz_yaml_path --revision $revision
  } catch {
    log error $"failed to revendor from `($moz_yaml_path)`"
  }

  $"Bug ($bug_id) - test\(webgpu\): update CTS to ($revision) r=#webgpu-reviewers"
}

export def "commandeer-updatebot-bug" [
  bug: int@"nu-complete updatebot bug cts",
  --dl-try-run-reports = true,
  --dl-try-run-reports-in-dir: directory = "../wpt/",
  --moz-phab-patch = true,
  --moz-phab-patch-apply-to-here,
] {
  use std/log

  mut fields = [
    'blocks'
    'flags'
  ]
  if $dl_try_run_reports {
    $fields = $fields | append 'comments'
  }
  if $moz_phab_patch {
    $fields = $fields | append 'attachments'
  }
  let original_bug_state = bugzilla bug get --include-fields $fields $bug
  let name = bugzilla whoami | get name

  if $WEBGPU_UPDATE_CTS_BUG_ID not-in $original_bug_state.blocks {
    error make --unspanned {
      msg: ([
        "specified bug "
        $bug
        " does not block `webgpu-update-cts` (bug "
        $WEBGPU_UPDATE_CTS_BUG_ID
        "); "
      ] | str join)
      help: ([
        "mark bug "
        $bug
        " as a blocker if you actually intended to commandeer it"
      ] | str join)
    }
  }

  log info "commandeering bug and updating classification…"
  bugzilla bug update $bug {
    assigned_to: $name
    status: 'ASSIGNED'
    type: task
    priority: P1
    flags: (
      $original_bug_state
        | get flags
        | where $it.name == 'needinfo' and $it.requestee == (bugzilla whoami).name
        | select name type_id id status
        | update status '-'
    )
  }

  if $moz_phab_patch {
    log info "attempting to create patch locally…"
    let phabricator_patches = $original_bug_state
      | get attachments
      | where $it.content_type == 'text/x-phabricator-request' and $it.is_obsolete == 0

    match ($phabricator_patches | length) {
      0 => {
        log warning "no patches detected against bug, expected 1; forgoing local patch application"
      }
      1 => {
        let patch_attachment_data = $phabricator_patches
          | first
          | get data
          | decode base64
          | decode utf-8

          let phabricator_patch_url_re = '^https://phabricator.services.mozilla.com/(?<rev_id>D\d+)$'
          let patch_revision_id = try {
            $patch_attachment_data
              | parse --regex $phabricator_patch_url_re
              | first
              | get rev_id
          } catch {
            error make --unspanned {
              msg: ([
                  " `"
                  $phabricator_patch_url_re
                  "` did not match attachment contents:\n\n"
                  $patch_attachment_data
              ] | str join)
            }
          }

        let apply_to_args = if $moz_phab_patch_apply_to_here {
          ['--apply-to=here']
        } else {
          []
        }
        (
          ^moz-phab patch
            $patch_revision_id
            ...$apply_to_args
        )
      }
      len => {
        log warning ([
          "multiple patches detected against bug, expected 1; "
          "forgoing local patch application"
        ] | str join)
      }
    }
  }

  if $dl_try_run_reports {
    const WEBGPU_CI = path self './ci.nu'
    use $WEBGPU_CI

    def exactly_one [
      what: string,
      --or-not,
    ]: list -> any {
      let values = $in

      match ($values | length) {
        1 => ($values | first)
        0 if $or_not => null
        len => {
          error make --unspanned {
            msg: $"expected single ($what), got ($values | length)"
          }
        }
      }
    }

    log info "searching for comment noting a Try run to download WPT reports from…"

    let try_run = $original_bug_state
      | get comments
      | where $it.creator == 'update-bot@bmo.tld'
      | get text
      | each --flatten {
        parse --regex ([
          "^I've submitted a try run for this commit: "
          '(?P<url>'
          (
            'https://treeherder.mozilla.org/jobs?'
              | str replace '.' '\.' --all
              | str replace '?' '\?' --all
          )
          '.*)$'
        ] | str join)
          | get url
      }
      | each {|url|
        def exactly_one_query_param [key: string]: list -> any {
          where $it.key == $key
            | get value
            | exactly_one $"`($key)` in query params. of ($url)"
        }

        let params = $url
          | url parse
          | get params

        let repo = $params | exactly_one_query_param 'repo'
        let revision = $params | exactly_one_query_param 'revision'

        $'($repo):($revision)'
      }
      | exactly_one --or-not "comment with Try push noted"

    if $try_run == null {
      log warning "unable to determine Try push, looks like ya gotta do it yourself"
    } else {
      (
        ci dl-reports
          $try_run
          --in-dir $dl_try_run_reports_in_dir
      )
    }
  }
}

def "gh current-mainline-commit" [
  org: string,
  repo: string,
] {
  http get $'https://api.github.com/repos/($org)/($repo)/commits?({ per_page: 1 } | url build-query)'
    | get sha
    | first
}

def "nu-complete updatebot bug cts" []: nothing -> list<int> {
  bugzilla search --criteria { blocked: $WEBGPU_UPDATE_CTS_BUG_ID }
    | where status != RESOLVED
    | get id
}
