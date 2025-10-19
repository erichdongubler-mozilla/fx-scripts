use std/log

const BUGZILLA = path self "../bugzilla.nu"
use $BUGZILLA

const TIME = path self '../time.nu'
use $TIME

const WEBGPU_CONSTANTS = path self './constants.nu'
use $WEBGPU_CONSTANTS [WGPU_REPO_PATH WGPU_REPO_URL]

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

  let new_revision = $revision | if $revision != null {
    # Normalize the commit ref. to a full SHA-1 hash.
    http get $'https://api.github.com/repos/($WGPU_REPO_PATH)/commits/($revision)'
      | get sha
  } else {
    gh current-mainline-commit gpuweb cts
  }

  let bug_id = $bug | default {
    let assigned_to = $assigned_to | default { bugzilla whoami | get name }
    (
      bug create
        --summary $"Update WebGPU CTS to upstream \(week of (time monday-of-this-week)\)"
        --extra {
          assigned_to: $assigned_to
          blocks: $WEBGPU_UPDATE_CTS_BUG_ID
          priority: P1
        }
    ) | get id
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
] {
  let original_bug_state = bugzilla bug get --include-fields [blocks flags] $bug
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

  print "Commandeering bug and updating classification…"
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
