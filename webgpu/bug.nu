const BUGZILLA = path self "../bugzilla.nu"
use $BUGZILLA

export def "create" [
  --assign-to-me,
  --summary: string,
  --type: string = "task",
  --priority: oneof<nothing, string> = null,
  --severity: oneof<nothing, string> = null,
  --version: string = "unspecified",
  --extra: record = {},
] {
  (
    bugzilla bug create
      --assign-to-me=$assign_to_me
      --product 'Core'
      --component 'Graphics: WebGPU'
      --summary=$summary
      --type=$type
      --priority=$priority
      --severity=$severity
      --version=$version
      --extra=$extra
  )
}
