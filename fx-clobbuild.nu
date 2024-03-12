export def main [] {
	use erichdongubler wezterm notify
	mach clobber
	try {
		# load-env {
		# 	MOZ_SCM_LEVEL: "1"
		# }
		mach build
		notify "Build succeeded!"
	} catch {
		notify "Build failed…"
	}
}
