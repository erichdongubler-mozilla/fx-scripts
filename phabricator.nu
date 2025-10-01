const FIND_UP = path self './find-up.nu'
use $FIND_UP

export def "submit" [] {
  let arcrc_path = match $nu.os-info.name {
    "windows" => ('~/AppData/Roaming/' | path expand)
    _ => $nu.home-path
  } | path join '.arcrc'
  let arcrc = open --raw $arcrc_path | from json

  let arcconfig_path = find-up ['.arcconfig']
  if $arcconfig_path == null {
    error make --unspanned {
      msg: "fatal: unable to find `.arcconfig`"
    }
  }
  let arcconfig = open $arcconfig_path | from json

  let host = $arcconfig
    | get 'phabricator.uri'
    | url parse
    | update path {
      str trim --left --char '/'
        | split row '/'
        | append 'api'
        | str join '/'
        | str replace --regex '$' '/'
    }
    | url join

  let auth = try {
    $arcrc.hosts | get $host
  } catch {
    error make --unspanned {
      msg: $"expected to find entry for host `($host)` in `($arcrc_path)`, but none was found"
    }
  }
}
