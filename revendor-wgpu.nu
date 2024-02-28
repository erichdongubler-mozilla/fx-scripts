export def wgpu_repo_pkgs [] {
	let wgpu_repo_url = "https://github.com/gfx-rs/wgpu"
	let id_pat = ["{name} {ver} (git+" $wgpu_repo_url "?rev={rev}#{_rev_frag}"] | str join
	^cargo metadata --format-version 1 --locked
		| from json
		| get packages
		| where source != null
		| where {|pkg| $pkg.source =~ $wgpu_repo_url }
		| each {|pkg|
			let parsed_id = $pkg.id | parse $id_pat | reject _rev_frag | first
			{
				name: $pkg.name
				version: ($parsed_id | [$in.ver "@git:" $in.rev] | str join)
			}
		}
}

export def main [
	--revision: string,
] {
	use std log [error, info]

	let old_metadata = (wgpu_repo_pkgs)

	let cmd = "mach"
	mut args = [vendor --ignore-modified gfx/wgpu_bindings/moz.yaml]
	if $revision != null {
		$args = ($args | append ["--revision" $revision])
	}
	let args = $args
	info "running `mach vendor gfx/wgpu_bindings/moz.yaml`…"
	let vendor_output = (do { run-external --redirect-combine $cmd ...$args } | complete)
	if $vendor_output.exit_code != 0 {
		error make --unspanned { msg: "failed to re-vendor, bailing" }
		return;
	}
	let vendor_output = $vendor_output | get stdout | lines
	let old_revision = (
		let REV_RE = 'Found   revision: (?P<revision>\w+)';
		$vendor_output | find --regex $REV_RE | first | parse --regex $REV_RE | first | get revision
	)
	info (["old revision: " $old_revision] | str join)
	let new_revision = (
		let REV_RE = ' \d+:\d+.\d+ Latest commit is (?P<revision>\w+?) from .*';
		$vendor_output | find --regex $REV_RE | first | parse --regex $REV_RE | first | get revision
	)
	info (["new revision: " $new_revision] | str join)

	let audits_to_do = (
		let AUDIT_ERR_RE = ([
			' ?\d+:\d+.\d+ E Missing audit for (?P<id>(?P<name>[\w-]+):(?P<version>\S+)) \(requires \['
			"'(?<criteria>[a-z-]+)'"
			'\]\).*'
		] | str join);
		$vendor_output
			| find --regex $AUDIT_ERR_RE
			| parse --regex $AUDIT_ERR_RE
			| each {|pkg_missing_audit|
				{
					pkg_name: $pkg_missing_audit.name
					old_version: ($old_metadata | where name == $pkg_missing_audit.name | first | get version)
					new_version: $pkg_missing_audit.version
					criteria: $pkg_missing_audit.criteria
				}
			}
	)

	info ([
		"audits to do:"
		($audits_to_do | each {||
			[
				"\n  "
				$in.pkg_name
				' '
				$in.old_version
				' -> '
				$in.new_version
				' as `'
				$in.criteria
				'`'
			] | str join
		} | str join)
	] | str join)
	$audits_to_do | each {|audit|
		let cmd = "mach"
		let args = [cargo vet certify --accept-all --criteria $audit.criteria $audit.pkg_name $audit.old_version $audit.new_version]
		info (["Running `" $cmd ' ' ($args | str join ' ' ) "`…"] | str join)
		run-external $cmd ...$args
	}

	info "running `mach vendor rust`, now that we've theoretically unblocked all audits…"
	mach vendor rust --ignore-modified
}
