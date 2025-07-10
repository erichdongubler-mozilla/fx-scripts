use std/log

const TIME = path self '../time.nu'
use $TIME

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

  let revision = $revision | default { gh current-mainline-commit gpuweb cts }

  let bug_id = $bug | default {
    const BUGZILLA = path self "../bugzilla.nu"
    use $BUGZILLA

    let assigned_to = $assigned_to | default { bugzilla whoami | get name }
    (
      bug create
        --summary $"Update WebGPU CTS to upstream \(week of (time monday-of-this-week)\)"
        --extra {
          assigned_to: $assigned_to
          blocks: 1863146 # `webgpu-update-cts`
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

def "gh current-mainline-commit" [
  org: string,
  repo: string,
] {
  http get $'https://api.github.com/repos/($org)/($repo)/commits?({ per_page: 1 } | url build-query)'
    | get sha
    | first
}
