def notify [body: string] {
	printf "\e]777;notify;%s;%s\e\\" "title" "body"
}

export def main [] {
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
