const MOZCONFIG = path self '../mozconfig.nu'
use $MOZCONFIG

export def "generate mozconfig" [] {
  const BUILD_HOOK = path self './buildhook.py'

  (
    mozconfig generate
      # This is the default, but I want this to be _super_ clear.
      --optimize=true

      # This, on the other hand, disables optimization for C++ code related to WebGPU.
      --build-hook $BUILD_HOOK
  )
}
