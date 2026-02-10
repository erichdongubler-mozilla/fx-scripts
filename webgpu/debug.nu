export def "env-vars" [
  --tracing-path: directory,
] {
  use std/log

  {
    MOZ_DISABLE_GPU_SANDBOX: 1
    MOZ_LOG: "WebGPU:3,wgpu_core::*:3,wgpu_hal::*:3,naga::*:3,d3d12::*:3"
  } | if $tracing_path != null {
    let tracing_path = $tracing_path | path expand
    if not ($tracing_path | path exists) {
      if not ($tracing_path | path dirname | path exists) {
        log warning $"`($tracing_path)`'s parent directory for did not exist, creating both…"
      } else {
        log info $"`($tracing_path)` does not yet exist, creating…"
      }
      mkdir $tracing_path
    }
    $in | insert WGPU_TRACE $tracing_path
  } else {
    $in
  }
}

# Runs using `uvx mozregression`.
export def --wrapped "run-with-trace" [
  --build: oneof<string, nothing> = null,
  # Which Firefox build to run. Default's to yesterday's Nightly build.
  --for-bug: oneof<int, nothing> = null,
  # If specified, output is written to `~/Downloads/bug-<id>`. If not specified, output is written
  # to `~/Downloads/<date>-wgpu-traces`.
  ...args,
  # All other arguments, which get forwarded to `mozregression`.
] {
  if (which uvx | is-empty) {
    error make --unspanned {
      msg: "no `uvx` binary detected in `PATH`"
    }
  }

  let build = $build | default (date now | $in - 1day | format date "%Y-%m-%d")

  let path = '~/Downloads/' | path join (if $for_bug != null {
    $'bug-($for_bug)'
  } else {
    $'(date now | format date '%Y-%m-%d')-wgpu-traces'
  })

  with-env (env-vars --tracing-path $path) {
    uvx mozregression --launch $build ...$args
  }
}
