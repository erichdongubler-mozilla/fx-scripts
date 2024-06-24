use std/log

const TIME = path self '../time.nu'
use $TIME

const WEBGPU_BUG = path self "../webgpu/bug.nu"
use $WEBGPU_BUG

const WGPU_REPO_URL = 'https://github.com/gfx-rs/wgpu'

export def "bindings begin-revendor" [
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

  try {
    which cargo-vet | first
  } catch {
    error make --unspanned {
      msg: "failed to find `cargo vet` binary in `PATH`"
    }
  }

  let moz_yaml_path = bindings moz.yaml path
  let moz_yaml = open $moz_yaml_path

  if not (
    $moz_yaml.vendoring.flavor == 'rust' and
    $moz_yaml.vendoring.url == $WGPU_REPO_URL and
    true
  ) {
    error make --unspanned {
      msg: $"unfamiliar `vendoring.{flavor,url}` at `($moz_yaml_path)`"
    }
  }

  let wgpu_crates = $moz_yaml | crates-from-bindings-moz.yaml

  let new_revision = $revision | default {
    let new_revision = ^$mach_cmd vendor --check-for-update $moz_yaml_path

    if $env.LAST_EXIT_CODE != 0 {
      error make --unspanned {
        msg: $"internal error: failed to run `mach vendor --check-for-update ($moz_yaml_path)`"
      }
    }

    let new_revision = $new_revision | parse '{revision} {date}' | get revision
    let new_revision = match ($new_revision | length) {
      0 => {
        error make --unspanned {
          msg: "no new commits detected upstream"
        }
      }
      1 => {
        $new_revision | first
      }
      2 => {
        error make --unspanned {
          msg: ([
            "internal error: got more than one line in `stdout` from "
            $"`mach vendor --check-for-update ($moz_yaml_path)`"
          ] | str join)
        }
      }
    }

    log info $"new revision: ($new_revision)"

    $new_revision
  }

  let bug_id = $bug | default {
    const BUGZILLA = path self "../bugzilla.nu"
    use $BUGZILLA

    mut $assigned_to = $assigned_to | default { bugzilla whoami | get name }

    let bug_id_webgpu_update_wgpu = 1851881

    let update_dependents = try {
      bugzilla bug get --output-fmt full $bug_id_webgpu_update_wgpu | get blocks
    } catch {
      error make --unspanned {
        msg: $"failed to fetch bugs depending on ($bug_id_webgpu_update_wgpu), bailing"
      }
    }

    let new_bug_id = (
      bug create
        --summary $"Update WGPU to upstream \(week of (time monday-of-this-week)\)"
        --extra {
          assigned_to: $assigned_to
          blocks: ($update_dependents | append $bug_id_webgpu_update_wgpu)
          priority: P1
        }
    ) | get id

    log info $"filed bug ($new_bug_id)"

    try {
      bugzilla bug update $bug_id_webgpu_update_wgpu {
        blocks: { remove: $update_dependents }
      }
    } catch {
      log warning ([
        "failed to remove dependents from `webgpu-update-wgpu`; "
        "please visit this URL and remove them: "
        "https://bugzilla.mozilla.org/show_bug.cgi?id=webgpu-update-wgpu"
      ] | str join)
    }

    $new_bug_id
  }

  try {
    ^$mach_cmd vendor $moz_yaml_path --revision $new_revision
  } catch {
    error make --unspanned {
      msg: $"failed to revendor from `($moz_yaml_path)`"
    }
  }

  for crate in $wgpu_crates.crates {
    let old_dep = $'($crate.version)@git:($wgpu_crates.revision)'
    let new_dep = $'($crate.version)@git:($new_revision)'
    (
      cargo vet certify $crate.name
        --criteria safe-to-deploy
        --accept-all $old_dep $new_dep
    )
  }

  print "You are now ready to run `mach vendor rust`!"

  $"Bug ($bug_id) - build\(webgpu\): update WGPU to ($new_revision) r=#webgpu-reviewers!"
}

export def "bindings moz.yaml path" [] {
  'gfx/wgpu_bindings/moz.yaml'
}

export def "crates-from-bindings-moz.yaml" [
]: record<vendoring: record<url: string> origin: record<revision: string>> -> record<revision: string crates: table<name: string version: string>>  {
  let moz_yaml = $in

  let revision = $moz_yaml.origin.revision

  {
    revision: $revision
    crates: (
      cargo metadata --format-version 1
        | from json
        | get packages
        | where {
          $in.source != null and $in.source == $'git+($moz_yaml.vendoring.url)?rev=($revision)#($revision)'
        }
        | select name version
    )
  }
}
