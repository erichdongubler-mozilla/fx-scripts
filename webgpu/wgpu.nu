use std/log

const TIME = path self '../time.nu'
use $TIME

const WEBGPU_BUG = path self "../webgpu/bug.nu"
use $WEBGPU_BUG

const WEBGPU_CONSTANTS = path self './constants.nu'
use $WEBGPU_CONSTANTS [WGPU_REPO_PATH WGPU_REPO_URL]

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

  let new_revision = $revision | if $revision != null {
    # Normalize the commit ref. to a full SHA-1 hash.
    http get $'https://api.github.com/repos/($WGPU_REPO_PATH)/commits/($revision)'
      | get sha
  } else {
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
        msg: $"failed to fetch bugs depending on bug ($bug_id_webgpu_update_wgpu), bailing"
      }
    }

    let new_bug_id = try {
      (
        bug create
          --summary $"Update WGPU to upstream \(week of (time monday-of-this-week)\)"
          --extra {
            assigned_to: $assigned_to
            status: 'ASSIGNED'
            blocks: ($update_dependents | append $bug_id_webgpu_update_wgpu)
            priority: P1
          }
      ) | get id
    } catch {
      error make --unspanned {
        msg: $"failed to create new revendoring bug as dependency of bug ($bug_id_webgpu_update_wgpu)"
      }
    }

    log info $"filed bug ($new_bug_id)"

    try {
      bugzilla bug update $bug_id_webgpu_update_wgpu {
        assigned_to: $assigned_to
        blocks: { remove: $update_dependents }
      }
    } catch {
      log warning ([
        "failed to update `webgpu-update-wgpu`; "
        "please visit this URL, remove dependents, and update the assignee: "
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

  # Work around a bug with `mach vendor …` replacing line endings.
  open --raw $moz_yaml_path
    | str replace --all (char crlf) (char lf)
    | collect
    | save --raw --force $moz_yaml_path

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

export def "bindings use-local-wgpu" [
  --path: oneof<directory, nothing> = null,
] {
  use std/log [] # set up `log` cmd. state

  log debug "Fetching crates to patch from bindings deps…"
  let crates = (
    open (bindings moz.yaml path)
      | crates-from-bindings-moz.yaml
      | get crates
      | select name
  )
  log debug $"Working with the following crates: ($crates | to nuon --indent 2)"

  let local_crates = if $path == null {
    let third_party_rust_dir = './third_party/rust'
    log info $"Using workspace members from `($third_party_rust_dir)/`…"
    log warning "NOTE that this approach is broken since `wgpu-core` has crates in its subdirectories!"
    $crates | upsert abs_path {|row| $'($third_party_rust_dir)/($row.name)' }
  } else {
    let cargo_toml_path = $path | path join 'Cargo.toml'
    log info $"Fetching workspace members from `($cargo_toml_path)`…"
    workspace-members --path $cargo_toml_path | select name abs_path
  }

  $crates
    | join $local_crates --left name
    | reduce --fold {} {|crate, acc|
      $acc | upsert $crate.name { path: $crate.abs_path }
    }
    | wrap $'($WGPU_REPO_URL).git'
    | wrap patch
    | to toml
    | str replace --regex '^' "\n"
    | save --append Cargo.toml

  cargo update ...($crates | get name | each { ['--package' $in] } | flatten)
  print "You are now ready to run `mach vendor rust`!"
}

def "workspace-members" [
  --path: directory,
]: nothing -> record<> {
  (
    cargo metadata --format-version 1
      --manifest-path $path
      | from json
      | get workspace_members
      | parse 'path+file://{abs_path}#{version_fragment}'
      | update version_fragment {|entry|
        parse --regex '(?:(?P<name>[a-zA-Z0-9-]+)@)?(?P<version>\d+\.\d+\.\d+)'
          | first
          | update name {
            if ($in | is-empty) {
              ($entry.abs_path | path basename)
            } else { $in }
          }
      }
      | flatten version_fragment
  )
}
