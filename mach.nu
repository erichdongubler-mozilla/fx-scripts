use std/log

const JJ = path self ./jj/
use $JJ

def "check-mach" [] {
  if (which ./mach | is-empty) {
    error make --unspanned {
      msg: "no `./mach` script found; is your CWD at the root of a Gecko checkout?"
    }
  }
}

def "queue-bg-job" --wrapped [
  --pueue-args: list<string> = [],
  ...args,
]: nothing -> record<task_id: int> {
  use std/log [] # set up `log` cmd. state

  log info $"queueing `($args | str join ' ')`…"
  (
    pueue add
      --print-task-id
      --group 'firefox'
      ...$pueue_args
      --
      ...$args
  ) | into int | wrap task_id
}

export def "bg build" [
  --clobber,
  --pin,
  --jobs: oneof<int, nothing> = null,
]: nothing -> record<task_id: int> {
  use std/log [] # set up `log` cmd. state

  check-mach

  mut pueue_args = []

  if $clobber {
    let clobber_task_id = bg clobber | get task_id
    log info $"clobbering with task ID ($clobber_task_id)"
    $pueue_args = $pueue_args | append ["--after" $clobber_task_id]
  }

  mut mach_args = ['./mach' 'build']

  let jobs = $jobs | default {
    let remaining_mem = sys mem | get free
    if ($jobs == null) and ($remaining_mem < 32GiB) {
      let maybe_good_job_count = $remaining_mem / 1.1GiB | into int
      log warning $"less than 32 GiB of memory remaining, defaulting to ($maybe_good_job_count) jobs"
      $maybe_good_job_count
    }
  }
  if $jobs != null {
    $mach_args = $mach_args | append ["--jobs" $jobs]
  }

  jj moz pin build add
  queue-bg-job --pueue-args=$pueue_args ...$mach_args
}

export def "bg clobber" [
]: nothing -> record<task_id: int> {
  check-mach
  try { jj moz pin build remove }
  queue-bg-job ./mach clobber
}
