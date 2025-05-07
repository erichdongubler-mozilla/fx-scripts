def "diff tags" [] {
  http get 'https://phabricator.services.mozilla.com/typeahead/class/PhabricatorProjectDatasource/?q=te&__ajax__=true'
    | str replace --regex '^for \(;;\);(.*)$' '$1'
    | from json
    | get payload
    | each {
      {
        display: $in.4
        name: ($in.0 | lines | get 1)
        color: $in.11
        proj_phid: $in.2
      }
    }
    | where color != disabled
}

def "nu-complete diff tags" [] {
  diff tags | each {
    {
      value: $in.name
      name: $in.display
      style: {
        fg: $in.color
      }
    }
  }
}

export def "diff submit-comment" [
  diff_id: string,
  fields: record<
    comment: string,
    tags: list<string@"nu-complete diff tags">,
  >,
] {
  let extracted_diff_id = $diff_id | str replace --regex '^D(\d+)$' '$1'
  if $extracted_diff_id == $diff_id {
    error make {
      msg: $"failed to extract Differential ID from ($diff_id | to nuon)"
      span: (metadata $diff_id).span
    }
  }

  mut edit_engine_actions = []

  if $fields.tags != null {
    let known_tags = diff tags
    let tags = $fields.tags | each {|specified_tag|
      let matches = $known_tags | where name == $specified_tag
      if (matches | is-empty) {
        error make {
          msg: $"unrecognized tag name ($specified_tag)"
          span: (metadata $specified_tag).span
        }
      }
      matches | first | get proj_phid
    }
    $edit_engine_actions = $edit_engine_actions | append {
      type:"projectPHIDs"
      value: ["PHID-PROJ-cspmf33ku3kjaqtuvs7g"]
    }
  }

  http post $'https://phabricator.services.mozilla.com/differential/revision/edit/()/comment/' --content-type 'application/x-www-form-urlencoded' {
    'editengine.actions': ($edit_engine_actions | to json)
  }
}
