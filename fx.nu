# Certify Rust crates for usage in Mozilla source using `mach cargo vet -- certify`.
export def "certify" [
	--reviewer (-r): list<string>, # Reviewer(s) to set for a revision message.
	--bug: int, # The Bugzilla bug number to use for a revision message.
	recs: list<list<string>>, # A list of lists of either two elements (name and version) or three elements (name, old version, and new version) to be used as arguments for separate invocations of `mach cargo vet -- certify …`.
] {
	for args in $recs {
		mach cargo vet certify --accept-all --criteria safe-to-deploy ...$args
	}

	let list_summary = $recs | each {
		$'`($in.0)` ($in | range 1.. | str join " → ")'
	} | str join ', '
	let msg = $"WIP: Bug ($bug) - chore: audit ($list_summary) r=#webgpu-reviewers!"
	git commit --all --message $msg
}
