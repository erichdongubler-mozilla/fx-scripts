def "notify" [...args: any] {
	toastify send --app-name="Firefox build" ...$args
}

export def "build" [
	--clobber,
	--jobs: int | null = null,
] {
	notify $"Queued Firefox build in `($env.PWD)`."

	mut build_task_args = []
	if $clobber {
		let clobber_task_id = pueue add --print-task-id -- mach clobber
		$build_task_args = $build_task_args | append ["--after" $clobber_task_id]
	}

	mut build_cli_args = []
	if $jobs != null {
		$build_cli_args = $build_cli_args | append ["--jobs" $jobs]
	}
	let build_task_id = pueue add --print-task-id ...$build_task_args -- mach build ...$build_cli_args

	pueue wait $build_task_id
	_pueue report-status $build_task_id
}

def "_pueue report-status" [task_id: string] {
	let task_status = pueue status --json | from json | get tasks | get $task_id

	mut status = $task_status | get status | columns | first
	if $status == "Done" {
		$status = $task_status | get status.Done.result
	}
	let working_dir = $task_status | get path | path basename

	notify $"($status)\nFinished build in `($working_dir)`"
}

export def "bootstrap lines-to-disable" [] {
	[
		"# ac_add_options --disable-bootstrap"
		"# ac_add_options MOZ_WINDOWS_RS_DIR=…"
		"# ac_add_options --without-wasm-sandboxed-libraries"
	]
}
