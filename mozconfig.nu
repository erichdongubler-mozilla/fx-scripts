# Generate the contents of a `mozconfig` entry with the given configuration.
#
# Generally, you'll be writing this command's output into a file, i.e., `mozconfig generate o>
# mozconfig`.
export def "generate" [
  --as-milestone: string@"nu-complete generate as-milestone" | null = null,
  --optimize: string@"nu-complete generate optimize" = "enable",
]: nothing -> string {
  const SCRIPT_PATH = path self

  mut options = [
    'ac_add_options --with-ccache=sccache'
    'ac_add_options --enable-debug'
    'ac_add_options --enable-clang-plugin'
  ]

  if $as_milestone != null {
    $options = $options | append $'ac_add_options --as-milestone=($as_milestone)'
  }

  match $optimize {
    "disable" => {
      $options = $options | append 'ac_add_options --disable-optimize'
    }
    "disable-webgpu" => {
      $options = $options
        | append $'ac_add_options MOZ_BUILD_HOOK=($SCRIPT_PATH | path dirname | path join webgpu buildhook.py)'
    }
    "enable" => {}
  }

  $options | append '' | str join "\n"
}

def "nu-complete generate as-milestone" [] {
  [
    "release"
    "early-beta"
    "late-beta"
  ]
}

def "nu-complete generate optimize" [] {
  [
    "enable"
    "disable-webgpu"
    "disable"
  ]
}
