export def "cmake for-msvc-build" [
] {
  use std/log

  # TODO: Check some repo content to diagnose not being in a DXC checkout?
  let build_dir = (jj workspace root | path join build)
  log info $"using build dir: ($build_dir)"
  mkdir $build_dir
  cd $build_dir
  (
    cmake ..
      -B $build_dir
      -C ../cmake/caches/PredefinedParams.cmake
      -DCMAKE_BUILD_TYPE=Debug
      -DLLVM_DISABLE_ASSEMBLY_FILES=ON
      -DHLSL_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF
      -DHLSL_BUILD_DXILCONV=OFF -DSPIRV_WERROR=OFF
      -DENABLE_SPIRV_CODEGEN=OFF
      -DLLVM_ENABLE_ASSERTIONS=ON
      -DLLVM_ASSERTIONS_NO_STRINGS=ON
      -DLLVM_ASSERTIONS_TRAP=ON
      -DDXC_CODEGEN_EXCEPTIONS_TRAP=ON
      -DDXC_DISABLE_ALLOCATOR_OVERRIDES=ON
      -G "Visual Studio 17 2022"
  )
}
