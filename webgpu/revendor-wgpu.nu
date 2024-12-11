def mach [...args: string] {
	use std/log

	let cmd = "mach"
	let args = $args
	log info $"running `([$cmd ...$args]| to nuon)`"
	run-external $cmd ...$args
}

def "cargo metadata" [] {
	^cargo metadata --format-version 1 | from json
}

export def extract_wgpu_repo_pkgs [] {
	let wgpu_repo_url = "https://github.com/gfx-rs/wgpu"
	let id_pat = ["git+" $wgpu_repo_url "?rev={rev}#{name}@{ver}"] | str join
	$in
		| get packages
		| where source != null
		| where {|pkg| $pkg.source =~ $wgpu_repo_url }
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
