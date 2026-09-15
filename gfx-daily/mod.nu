const DEFAULT_HOST = "https://mozilla.modular.im"   # mozilla.org/.well-known/matrix/client
const DEFAULT_CREDENTIALS_FILE = "~/.config/matrix/last-link-credentials.nuon"

# `mozilla.modular.im` delegates auth to a Matrix Authentication Service (MSC3861), so the only
# durable credential a CLI can hold is an OAuth refresh token. These are the scopes MSC2967 defines
# for the Matrix client-server API; there is no read-only variant.
const MATRIX_API_SCOPE = "urn:matrix:org.matrix.msc2967.client:api:*"
const MATRIX_DEVICE_SCOPE_PREFIX = "urn:matrix:org.matrix.msc2967.client:device:"

const FORM = "application/x-www-form-urlencoded"

# Discover the homeserver's authorization server. Done on every run rather than cached, so that a
# homeserver migrating to a different issuer heals itself instead of failing cryptically.
def auth-metadata [
  host: string,
] {
  let url = $"($host)/_matrix/client/unstable/org.matrix.msc2965/auth_metadata"
  let response = http get --allow-errors --full $url

  if $response.status != 200 {
    error make {
      msg: $"($host) did not advertise OAuth auth metadata (HTTP ($response.status))"
      help: "Only homeservers using delegated OIDC are supported by `login`; for others, pass
        `--access-token-file` with a token obtained some other way."
    }
  }

  $response.body
}

def read-credentials [
  credentials_file: path,
] {
  if not ($credentials_file | path exists) {
    error make {
      msg: $"no credentials at ($credentials_file)"
      help: "Run `last-link login` first."
    }
  }

  open $credentials_file
}

def write-credentials [
  credentials_file: path,
  credentials: record,
] {
  mkdir ($credentials_file | path dirname)
  $credentials | save --force $credentials_file

  # A refresh token grants full account access, so keep it owner-only. Windows profile
  # directories are already owner-only by ACL, and it has no `chmod`.
  if $nu.os-info.name != "windows" {
    ^chmod 600 $credentials_file
  }
}

# Exchange the stored refresh token for a fresh access token.
#
# The authorization server rotates the refresh token on every exchange, so the replacement is
# persisted *before* the access token is handed back: dropping it would strand the credential and
# force an interactive `login`.
def refresh-access-token [
  credentials_file: path,
  credentials: record,
  token_endpoint: string,
] {
  let response = http post --allow-errors --full --content-type $FORM $token_endpoint {
    grant_type: "refresh_token"
    refresh_token: $credentials.refresh_token
    client_id: $credentials.client_id
  }

  if $response.status != 200 {
    let detail = $response.body | get --optional error_description
      | default ($response.body | get --optional error)
      | default $response.body
    error make {
      msg: $"could not refresh the access token: ($detail)"
      help: $"The session may have been revoked, or its refresh token superseded by a concurrent
        run. Re-authorize with `last-link login --force`, and check
        ($credentials.account_management_uri? | default 'your homeserver account settings') for
        sessions named `last-link.nu`."
    }
  }

  let body = $response.body
  write-credentials $credentials_file ($credentials | merge { refresh_token: $body.refresh_token })

  $body.access_token
}

def auth-headers [
  credentials_file: path,
  access_token_file: any,
  host: string,
] {
  let access_token = if $access_token_file != null {
    open $access_token_file | str trim
  } else {
    let credentials = read-credentials $credentials_file
    refresh-access-token $credentials_file $credentials (auth-metadata $host).token_endpoint
  }

  { 'Authorization': $"Bearer ($access_token)" }
}

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

# Authorize this tool against a homeserver, once, via the OAuth 2.0 device authorization grant.
#
# This registers `last-link.nu` as its own Matrix device and stores the resulting refresh token, so
# later runs need no browser. Revoke it any time from your homeserver's account settings by ending
# the session named `last-link.nu`.
#
# Note that the stored refresh token is *not* scoped: it grants full access to the account you
# approve it with. It is written owner-only, but treat the file as equivalent to your password.
export def login [
  --host: string = $DEFAULT_HOST,
  # The homeserver to authorize against.
  --credentials-file: path = $DEFAULT_CREDENTIALS_FILE,
  # Where to store the client registration and refresh token.
  --force,
  # Overwrite existing credentials, ending the previously authorized session.
] {
  let credentials_file = $credentials_file | path expand --no-symlink

  if ($credentials_file | path exists) and (not $force) {
    error make {
      msg: $"credentials already exist at ($credentials_file)"
      help: "Pass `--force` to re-authorize and replace them."
    }
  }

  let metadata = auth-metadata $host

  # A public client: there is nowhere on a user's machine to keep a client secret, which is
  # precisely the case `token_endpoint_auth_method: none` exists for.
  let registration = http post --content-type application/json $metadata.registration_endpoint {
    client_name: "last-link.nu"
    application_type: "native"
    token_endpoint_auth_method: "none"
    grant_types: ["urn:ietf:params:oauth:grant-type:device_code" "refresh_token"]
    response_types: []
    redirect_uris: []
    client_uri: "https://github.com/ErichDonGubler"
  }

  let device_id = random chars --length 16
  let authorization = http post --content-type $FORM $metadata.device_authorization_endpoint {
    client_id: $registration.client_id
    scope: $"($MATRIX_API_SCOPE) ($MATRIX_DEVICE_SCOPE_PREFIX)($device_id)"
  }

  let verification_uri = $authorization
    | get --optional verification_uri_complete
    | default $authorization.verification_uri

  print --stderr $"Open ($verification_uri) and enter code: ($authorization.user_code)"
  print --stderr $"Waiting for approval \(expires in ($authorization.expires_in)sec\)..."

  # Poll per RFC 8628. Branch on the `error` field, not the status code: this authorization server
  # answers `authorization_pending` with HTTP 403 rather than the specified 400.
  mut interval = $authorization | get --optional interval | default 5
  let deadline = (date now) + ($authorization.expires_in * 1sec)
  mut tokens: any = null

  while $tokens == null {
    if (date now) > $deadline {
      error make { msg: "the authorization request expired before it was approved" }
    }

    sleep ($interval * 1sec)

    let response = http post --allow-errors --full --content-type $FORM $metadata.token_endpoint {
      grant_type: "urn:ietf:params:oauth:grant-type:device_code"
      device_code: $authorization.device_code
      client_id: $registration.client_id
    }

    if $response.status == 200 {
      $tokens = $response.body
      continue
    }

    match ($response.body | get --optional error) {
      "authorization_pending" => { continue }
      "slow_down" => { $interval = $interval + 5 }
      "access_denied" => { error make { msg: "the authorization request was denied" } }
      "expired_token" => { error make { msg: "the authorization request expired" } }
      $other => {
        let detail = $response.body | get --optional error_description | default $other
        error make { msg: $"device authorization failed: ($detail)" }
      }
    }
  }

  write-credentials $credentials_file {
    homeserver: $host
    issuer: $metadata.issuer
    account_management_uri: ($metadata | get --optional account_management_uri)
    client_id: $registration.client_id
    device_id: $device_id
    refresh_token: $tokens.refresh_token
  }

  print --stderr $"Authorized. Credentials stored at ($credentials_file)."
}

# Print a permalink to the last top-level message a `--sender` posted in a Matrix room.
#
 # Run `last-link login` once to authorize; after that this needs no interaction. See that
 # command's help for what the stored credential grants.
export def last-link [
  --room: string = "#gfx-daily:mozilla.org",
  # The room to look up `--sender`'s last message.
  --credentials-file: path = $DEFAULT_CREDENTIALS_FILE,
  # Credentials produced by `login`.
  --access-token-file: oneof<path, nothing> = null,
  # Bypass `login` and read a bare access token from this file instead. Useful for accounts on
  # homeservers that still issue non-expiring tokens.
  --sender: oneof<string, nothing> = null,
  # Whose messages to look for, i.e. `@someone:mozilla.org`. Defaults to the credential's own
  # account, looked up via Matrix's `/v3/account/whoami` endpoint (if necessary).
  --pages: int = 20,
  # How many 100-event windows to scan backwards.
  --host: string = $DEFAULT_HOST,
  # The host to point requests to.
] {
  let credentials_file = $credentials_file | path expand --no-symlink
  let auth_headers = auth-headers $credentials_file $access_token_file $host

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
