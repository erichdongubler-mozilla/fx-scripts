# Generate the contents of a `mozconfig` entry with the given configuration.
#
# Generally, you'll be writing this command's output into a file, i.e., `mozconfig generate o>
# mozconfig`.
export def "generate" [
  --as-milestone: string@"nu-complete generate as-milestone" = "nightly",
  # Build as a specific release train. Specifying `nightly` emits no option, as it's the default.
  --optimize = true,
  # Enable optimization of compiled code.
  --enable-debug = true,
  # Enables debug symbols for compiled code.
  --enable-clang-plugin = true,
  # Enables `moz-clang-plugin` as a source of diagnostics for compiled code.
  --with-ccache: oneof<string, nothing>@"nu-complete generate with-ccache" = "sccache",
  # Enables intermediate build artifact caching via the provided binary.
  --build-hook: oneof<path, nothing> = null,
  --windows-rs-dir: oneof<directory, nothing> = null,
  # Hook a Python script into the handling of each `moz.build` file by setting
  # `MOZ_BUILD_HOOK=<path>`. Canonicalizes the provided path, and replaces backslashes with forward
  # slash.
  --disable-sandbox,
]: nothing -> string {
  const SCRIPT_PATH = path self

  mut options = []

  if not $optimize {
    $options = $options | append 'ac_add_options --disable-optimize'
  }

  if $with_ccache != null {
    $options = $options | append $'ac_add_options --with-ccache=($with_ccache)'
  }

  if $enable_debug {
    $options = $options | append 'ac_add_options --enable-debug'
  }

  if $enable_clang_plugin {
    $options = $options | append 'ac_add_options --enable-clang-plugin'
  }

  if $disable_sandbox {
    $options = $options | append 'ac_add_options --disable-sandbox'
  }

  if $as_milestone != "nightly" {
    let valid_values = nu-complete generate as-milestone
    if $as_milestone not-in $valid_values {
      error make {
        msg: $"`--as-milestone` cannot be assigned `($as_milestone)`"
        label: {
          text: $"expected one of ($valid_values | each { to nuon })"
          span: (metadata $as_milestone).span
        }
      }
    }
    $options = $options | append $'ac_add_options --as-milestone=($as_milestone)'
  }

  if $build_hook != null {
      let hook_script_path = $build_hook
        | path expand
        | str replace '\' '/' --all # `mach build` doesn't handle native Windows hook script paths. >:(
      $options = $options | append $'ac_add_options MOZ_BUILD_HOOK=($hook_script_path)'
  }

  if $windows_rs_dir != null {
      let hook_script_path = $windows_rs_dir
        | path expand
        | str replace '\' '/' --all # `mach build` doesn't handle native Windows hook script paths. >:(
      $options = $options | append $'ac_add_options MOZ_WINDOWS_RS_DIR=($hook_script_path)'
  }

  $options | append '' | str join "\n"
}

def "nu-complete generate as-milestone" [] {
  [
    "nightly"
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

def "nu-complete generate with-ccache" [] {
  [
    "sccache"
  ]
}
