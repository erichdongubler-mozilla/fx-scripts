export def "fx-gfx env-vars" [] {
	{
		MOZ_DISABLE_GPU_SANDBOX: 1
		MOZ_DISABLE_CONTENT_SANDBOX: 1
	}
}

# TODO: `profile-default` or a fresh one every time?
export def "fx-renderdoc cli-args" [] {
	[
		"-no-remote"
		"--wait-for-browser" # TODO: maybe only on Windows?
		# # TODO: 
		# "-profile"
		# [(ls obj-* | first | get name) objdir dbg tmp profile-default] | path join
	]
}

export def "fx-renderdoc prefs" [] {
	[ 
		{
			name: "browser.launcherProcess.enabled"
			value: "false"
		}
		{
			name: "gfx.webrender.compositor"
			value: "false"
		}
		{
			name: "gfx.webrender.enabled"
			value: "true"
		}
	]
}
