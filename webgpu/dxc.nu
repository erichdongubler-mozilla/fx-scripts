export def "cmake for-msvc-build" [
] {
  use std/log

  # TODO: Check some repo content to diagnose not being in a DXC checkout?
  let build_dir = (jj workspace root | path join build)
  log info $"using build dir: ($build_dir)"
  mkdir $build_dir
  cd $build_dir

  let clang = '~/.mozbuild/clang' | path expand
  let clang_cl = $clang | path join bin clang-cl.exe
  let vs_install_dir = '~/.mozbuild/vs' | path expand
  let win_sdk_version = open ($vs_install_dir | path join 'Windows Kits' '10' 'SDKManifest.xml')
    | get attributes.PlatformIdentity
    | parse --regex 'UAP, Version=(?P<version>\d+(?:\.\d+){3})'
    | first
    | get version

  (
    cmake ..
      -B $build_dir
      -C ../cmake/caches/PredefinedParams.cmake
      -DCMAKE_TOOLCHAIN_FILE=../cmake/platforms/WinMsvc.cmake
      $"-DCMAKE_C_COMPILER=($clang_cl)"
      $"-DCMAKE_CXX_COMPILER=($clang_cl)"
      $"-DLLVM_NATIVE_TOOLCHAIN=($clang)"
      $"-DLLVM_WINSYSROOT=($vs_install_dir)"
      $"-DDIASDK_INCLUDE_DIR=($vs_install_dir)/DIA SDK/include"
      $"-DWIN10_SDK_PATH=($vs_install_dir)/Windows Kits/10"
      $"-DWIN10_SDK_VERSION=($win_sdk_version)"
      -DLLVM_INFERRED_HOST_TRIPLE=x86_64-windows-msvc
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
      -G "Ninja"
  )
}

export def "cmake for-unix-like" [
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
      -G "Ninja"
  )
}
