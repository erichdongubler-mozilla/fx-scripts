const MOZCONFIG = path self '../mozconfig.nu'
use $MOZCONFIG

export def "generate" [] {
  (
    mozconfig generate
      --optimize 'webgpu'
  )
}
