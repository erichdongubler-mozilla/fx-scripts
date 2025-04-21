def mach [...args: string] {
	use std/log

	let cmd = "mach"
	let args = $args
	log info $"running `([$cmd ...$args]| to nuon)`"
	run-external $cmd ...$args
}

def "cargo metadata" --wrapped [...args] {
	^cargo metadata --format-version 1 ...$args | from json
}

const WGPU_REPO_URL = "https://github.com/gfx-rs/wgpu"

export def extract_wgpu_repo_pkgs [] {
	let id_pat = ["git+" $WGPU_REPO_URL "?rev={rev}#{name}@{ver}"] | str join
	$in
		| get packages
		| where source != null
		| where {|pkg| $pkg.source =~ $WGPU_REPO_URL }
		| each {|pkg|
			let parsed_id = $pkg.id | parse $id_pat | first
			{
				name: $pkg.name
				version: ($parsed_id | [$in.ver "@git:" $in.rev] | str join)
			}
		}
}

export def main [
	--revision: string,
] {
	use std/log

	let old_metadata = cargo metadata | extract_wgpu_repo_pkgs

	try {
		mut revision_args = []
		if $revision != null {
			$revision_args = ["--revision" $revision]
		}
		mach ...[
			"vendor"
			"gfx/wgpu_bindings/moz.yaml"
			...$revision_args
		]
	} catch {
		error make --unspanned { msg: "failed to update WGPU deps. specs., bailing" }
		return;
	}

	let new_metadata = cargo metadata | extract_wgpu_repo_pkgs

	let audits_to_do = (
		$new_metadata
			| rename --column {version: new_version}
			| insert old_version {
				let entry = $in
				let entry = $old_metadata | where name == $entry.name
				if ($entry | is-empty) {
					null
				} else {
					$entry | first | get version
				}
			}
			| insert criteria "safe-to-deploy"
	)

	log info ([
		"audits to do:"
		($audits_to_do | each {||
			let old_version = if $in.old_version == null {
				''
			} else {
				$'($in.old_version) -> '
			}
			$"\n	($in.name) ($old_version)($in.new_version)"
		} | str join)
	] | str join)
	for audit in $audits_to_do {
		try {
			mach ...[
				cargo
				vet
				certify
				"--accept-all"
				"--criteria"
				$audit.criteria
				$audit.name
				...($audit.old_version | append $audit.new_version)
			]
		} catch {
			error make --unspanned { msg: "failed to re-vendor Rust deps., bailing" }
		}
	}

	mach vendor rust "--ignore-modified"
}

export def "with-local" [
  wgpu_ckt_dir: directory,
  --crates: list<string> | null = null,
] {
  let wgpu_ckt_dir = $wgpu_ckt_dir | str replace --all '\' '/' | str replace --regex '/$' ''

  mut resolved_crates = $crates
  let cargo_manifest_path = cargo locate-project | from json | get root
  if $resolved_crates == null {
    $resolved_crates = cargo metadata | extract_wgpu_repo_pkgs | get name
    if ($resolved_crates | is-empty) {
      error make --unspanned {
        msg: $"no crates associated with `($WGPU_REPO_URL)` were found with `cargo metadata`; are you already using local `path` dependencies?"
      }
    }
  } else if ($resolved_crates | is-empty) {
    error make --unspanned {
      msg: "no `--crates` specified; did you make a scripting mistake?"
      label: {
        text: "this was an empty list"
        span: (metadata $crates).span
      }
    }
  }

  let wgpu_metadata = cargo metadata --manifest-path ($wgpu_ckt_dir | path join Cargo.toml)
  let wgpu_workspace_members = $wgpu_metadata.workspace_members
    | parse --regex '^path\+file:///(?P<path>.*)#(?:(?P<original_name>[\w-]+)@)?(?P<version>\d+\.\d+\.\d+)$'
    | insert name {
      if ($in.original_name | is-not-empty) {
        $in.original_name
      } else {
        $in.path | path basename
      }
    }
    | reject original_name

  let patches_section = [
    $'[patch."($WGPU_REPO_URL)"]'
    ...(
      $resolved_crates
        | wrap name
        | join --left $wgpu_workspace_members name
        | each {
          $'"($in.name)" = { path = "($in.path)" }'
        }
    )
  ] | str join "\n"

  if $WGPU_REPO_URL in (open $cargo_manifest_path | get patch | columns) {
    error make --unspanned {
      msg: $"`patch.(WGPU_REPO_URL)` already in Gecko checkout's `Cargo.toml`; please remove it before continuing"
    }
  }

  $"\n($patches_section)" | save --append $cargo_manifest_path
  cargo fetch --manifest-path $cargo_manifest_path
}
