const PIN_TAG_PREFIX = 'pin/ci'

const PIN_BUILD_PREFIX = 'pin/build'

def build_tag_prefix [
  --hostname: oneof<string, nothing> = null,
] {
  let hostname = $hostname | default { sys host | get hostname }
  $'($PIN_BUILD_PREFIX)/($hostname)'
}

def effective-wc [] {
  let wc_is_empty = jj log --no-graph --revisions '@' --template "self.empty()" | into bool
  if $wc_is_empty {
    '@-'
  } else {
    '@'
  }
}

def "nu-complete pin build hostname" [] {
  git tag --list $'($PIN_BUILD_PREFIX)/*'
    | lines
    | parse $'($PIN_BUILD_PREFIX)/{hostname}/{rest}'
    | get hostname
    | uniq
}

def "nu-complete pin build remove workspace" [] {
  let build_tag_prefix = build_tag_prefix
  git tag --list $'($build_tag_prefix)/*'
    | lines
    | str replace --regex $'^($build_tag_prefix)/' ''
}

def "nu-complete pin ci remove push-revision" [] {
  git tag --list $'($PIN_TAG_PREFIX)/*'
    | lines
    | str replace --regex $'($PIN_TAG_PREFIX)/' ''
    | each {|entry|
      parse '{repo}/{revision}' | first | { value: $in.revision display: $entry }
    }
}

export def "pin add build" [
  --revision (-r): oneof<string, nothing> = null,
  # Defaults to `@`, or `@-` if `@` is empty.
  --workspace (-w): oneof<string, nothing> = null,
  # Defaults to the current workspace name, found via `jj workspace root`.
] {
  let revision = $revision | default { effective-wc }
  let commits = rev-parse $revision
  let tag_name = tag-name build --workspace $workspace
  tag add --name $tag_name ...$commits
  print $"Set tag `($tag_name)` to ($revision)"
}

export def "pin remove build" [
  --hostname: oneof<string, nothing>@"nu-complete pin build hostname" = null,
  --workspace: oneof<string, nothing>@"nu-complete pin build remove workspace" = null,
] {
  let tag_name = tag-name build --workspace $workspace --hostname $hostname
  tag remove $tag_name
}

export def "pin add ci" [
  --revision (-r): oneof<string, nothing> = null,
  # Defaults to `@`, or `@-` if `@` is empty.
  --repo: string = "try",
  --push-revision (-p): string,
] {
  let revision = $revision | default { effective-wc }
  let commits = rev-parse $revision
  let tag_name = tag-name ci --repo $repo --push-revision $push_revision
  tag add --name $tag_name ...$commits
}

export def "pin remove ci" [
  --repo: string = "try",
  --push-revision (-p): string@"nu-complete pin ci remove push-revision",
] {
  let tag_name = tag-name ci --repo $repo --push-revision $push_revision
  tag remove $tag_name
}

def "rev-parse" [
  revset: string
]: nothing -> list<string> {
  (
    jj log
      --no-graph
      --template 'commit_id.short() ++ "\n"'
      --revisions $revset
  ) | lines
}

def "tag add" [
  --name: string
  ...commits: string
] {
  load-env {
    GIT_DIR: (jj git root)
  }
  git tag --force $name ...$commits
  git push --force origin $name
  jj git import
}

def "tag remove" [
  ...names: string,
] {
  load-env {
    GIT_DIR: (jj git root)
  }
  git tag --delete ...$names
  git push origin --delete ...$names
  jj git import
}

def "tag-name build" [
  --hostname: oneof<string, nothing> = null,
  --workspace: oneof<string, nothing> = null,
] {
  let build_tag_prefix = build_tag_prefix --hostname $hostname
  let workspace = $workspace | default { jj workspace root | path basename }
  $'($build_tag_prefix)/($workspace)'
}

def "tag-name ci" [
  --repo: string,
  --push-revision: string,
] {
  $'($PIN_TAG_PREFIX)/($repo)/($push_revision)'
}
