const repos_dir = path self './repos'

export def "config copy" [
  repo: string@"nu-complete config copy repo",
] {
  let resolved = [$repos_dir $repo 'config.toml'] | path join
  if not ($resolved | path exists) {
    error make {
      msg: $"`($resolved)` does not exist"
      span: (metadata $repo).span
    }
  }
  let config_path = jj config path --repo
  cp $resolved ($config_path)
  print $"Copied `($resolved)` to `($config_path)`"
}

def "nu-complete config copy repo" [] {
  glob $'($repos_dir)/**/config.toml' | each {
    $in
      | path relative-to $repos_dir
      | str replace --regex '/config\.toml' ''
  }
}
