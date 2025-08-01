export def env-from-vcvars [
  bat_path: string@"nu-complete vcvars-paths",
]: nothing -> record<> {
  check-windows

  env-from-bat $bat_path
}

export def env-from-bat [
  ...cmd: string # The batch command to run
]: nothing -> record<> {
  check-windows

  let tmp = mktemp --tmpdir
  let cmd = ($cmd | append ["&&" "set" $">($tmp)"])
  run-external cmd.exe /c ...$cmd
  let exit_code = $env.LAST_EXIT_CODE
  let vars = open --raw $tmp
  rm $tmp

  # Source: https://stackoverflow.com/questions/77383686/set-environment-variables-from-file-of-key-value-pairs-in-nu
  # Convert the output of `set` into a record.
  def "from env" []: string -> record {
    lines
      | split column '#'
      | get column1
      | where { is-not-empty }
      | parse '{key}={value}'
      | update value { str trim --char '"' }
      | transpose --header-row --as-record
  }

  let path_conv = {
    from_string: {|s| $s | split row (char esep) | path expand --no-symlink }
    to_string: {|v| $v | path expand --no-symlink | str join (char esep) }
  }
  $env.ENV_CONVERSIONS = $env.ENV_CONVERSIONS | upsert PATH $path_conv | upsert Path $path_conv

  $vars
    | from env
    | transpose
    | rename key value
    | where { $in.key not-in ['PWD'  'CURRENT_FILE' 'FILE_PWD'] }
    | each {|env_var|
      if $env_var.key in $env.ENV_CONVERSIONS {
        $env_var | update value {
          do ($env.ENV_CONVERSIONS | get $env_var.key | get from_string) $in
        }
      } else {
        $env_var
      }
    }
    | transpose --header-row --as-record
    | rename --column { PATH: Path }
    # NOTE: ^ If the casing isn't right, one can't set `$env` in a way that binaries will be picked
    # up (even through `load-env`).
}

export def "nu-complete vcvars-paths" [] {
  check-windows

  (
    fd vcvars
      --extension bat
      --search-path 'C:/Program Files/Microsoft Visual Studio/'
      --path-separator '/'
  ) | lines | each { to nuon }
}

export def --wrapped "vswhere" [
  ...args,
] {
  check-windows

  (
    `C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe`
      ...$args
  )
}

def "check-windows" [] {
  if $nu.os-info.name != 'windows' {
    error make --unspanned {
      msg: "bruh! You're not on Windows."
    }
  }
}
