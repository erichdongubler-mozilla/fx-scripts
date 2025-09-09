export def "env-vars" [
  --tracing-path: directory,
] {
  use std/log

  {
    MOZ_DISABLE_GPU_SANDBOX: 1
    MOZ_LOG: "WebGPU:3,wgpu_core::*:3,wgpu_hal::*:3,naga::*:3,d3d12::*:3"
  } | if $tracing_path != null {
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
