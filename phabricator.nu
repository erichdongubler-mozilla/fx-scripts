const USER_AGENT = "ErichDonGubler-Phabricator-Nushell/1.0"
const DEFAULT_HOST = 'https://phabricator.services.mozilla.com/api/'

# A raw API call helper for Phabricator's Conduit API.
export def "conduit api" [
  method: string,
  params: record = {},
  --host: string = $DEFAULT_HOST,
] {
  let token = token-for-host $host

  let data = { 'api.token': $token } | merge $params

  let response = (
    http post
      --headers { 'User-Agent': $USER_AGENT }
      --content-type 'application/x-www-form-urlencoded'
      --allow-errors
      --full
      $'($host)($method)'
      $data
  )

  if ($response.status not-in 200..=299) or ($response.body.error_code != null) {
    error make --unspanned {
      msg: $"HTTP error ($response.status): ($response.body.error_code): ($response.body.error_info)"
    }
  }

  $response.body.result
}

export def "token-for-host" [
  host: string = $DEFAULT_HOST,
] {
  open ~/.arcrc
    | from json
    | get ([ hosts $host token ] | into cell-path)
}
