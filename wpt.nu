export def task-timeout-regex [] {
  # NOTE: On macOS, `task` is capitalized, but _not_ on other platforms. 😱
  "[Tt]ask aborted - max run time exceeded"
}
