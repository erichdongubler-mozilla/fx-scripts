const DEFAULT_HOST = "https://mozilla.modular.im"   # mozilla.org/.well-known/matrix/client

def is-original-top-level-non-reply-msg [
] {
  let event = $in
  let relates_to = $event | get --optional content."m.relates_to" | default {}
  let relates_to_type = $relates_to | get --optional rel_type | default ""

  (
    $relates_to_type not-in ["m.thread" "m.replace"]
  ) and (
    ($relates_to | get --optional "m.in_reply_to") == null
  )
}

# Print a permalink to the last top-level message a `--sender` posted in a Matrix room.
#
# You will need an access token for an account that has access to `--room`, stored as text file
# (i.e., `~/.config/matrix/token`) with safe permissions (i.e., Unix mode 0600). Note that a Matrix
# access token is not scoped: it grants full access to the associated account. So, prefer
# credentials for an account that can do the least damage possible.
#
# To get the token used by your existing Element client: access `Element` -> `Settings` -> `Help
# & About` -> `Advanced` -> `Access Token`.
export def last-link [
  --room: string = "#gfx-daily:mozilla.org",
  # The room to look up `--sender`'s last message.
  --access-token-file: path = ~/.config/matrix/token,
  # The file containing your personal access token.
  --sender: oneof<string, nothing> = null,
  # Whose messages to look for, i.e. `@someone:mozilla.org`. Defaults to the token's own account,
  # looked up via Matrix's `/v3/account/whoami` endpoint (if necessary).
  --pages: int = 20,
  # How many 100-event windows to scan backwards.
  --host: string = $DEFAULT_HOST,
  # The host to point requests to.
] {
  let auth_headers = { 'Authorization': $"Bearer (open $access_token_file | str trim)" }

  let room_id = (
    http get --headers $auth_headers
      $"($host)/_matrix/client/v3/directory/room/($room | url encode --all)"
  ) | get room_id

  let sender = $sender | default {
    http get --headers $auth_headers $"($host)/_matrix/client/v3/account/whoami"
      | get user_id
  }

  let base_query = {
    'dir': 'b'
    'limit': 100
    'filter': ({
      senders: [$sender],
      types: ["m.room.message"]
    } | to json --raw)
  }

  let room_id_url_encoded = $room_id | url encode --all

  mut from: string = ""
  mut found: any = null
  for _ in 1..$pages {
    mut query = $base_query
    if ($from | is-not-empty) {
      $query = $query | merge { 'from': $from }
    }
    let query = $query | url build-query

    let response = (
      http get --headers $auth_headers
        $"($host)/_matrix/client/v3/rooms/($room_id_url_encoded)/messages?($query)"
    )

    let hit = $response.chunk
      | where { is-original-top-level-non-reply-msg }
      | first
    if $hit != null {
      $found = $hit
      break
    }

    if ($response.end? | is-empty) {
      break
    }

    $from = $response.end
  }

  if $found == null {
    print --stderr $"no top-level message from ($sender) found in ($room)"
    exit 1
  }

  let origin_server_ts = $found.origin_server_ts * 1_000_000 | into datetime
  {
    'link': $"https://matrix.to/#/($room_id)/($found.event_id)?via=mozilla.org"
    'origin_server_ts': $origin_server_ts
    'found': $found
  }
}
