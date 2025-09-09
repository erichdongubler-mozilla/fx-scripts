export def "env-vars" [
  --tracing-path: directory,
] {
  {
    MOZ_DISABLE_GPU_SANDBOX: 1
    MOZ_LOG: "WebGPU:3,wgpu_core::*:3,wgpu_hal::*:3,naga::*:3,d3d12::*:3"
  } | if $tracing_path != null {
    $in | insert WGPU_TRACE $tracing_path
  } else {
    $in
  }
}
