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

const WGPU = path self './wgpu.nu'
use $WGPU

export def "generate cargo-profile-overrides" [] {
  let crates = open (wgpu bindings moz.yaml path) | wgpu crates-from-bindings-moz.yaml | get crates

  print "Add the following to `Cargo.toml`:"

  let suggested_config = {
    'profile': {
      'release': {
        'package': (
          $crates | get name | reduce --fold {} {|crate, acc|
            let entry =  {
              'opt-level': 0
              'debug': true
            } | wrap $crate

            $acc | merge $entry
          }
        )
      }
    }
  }
  print --no-newline $"\n```toml\n($suggested_config | to toml)```\n"

  print "…and your Rust code should be properly configured. Happy debugging!"
}
