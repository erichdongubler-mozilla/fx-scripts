const TICKTICK_BIN_CARGO_MANIFEST_PATH = path self ./Cargo.toml

export def "summary-to-daily" --wrapped [...args]: string -> string {
    cargo run --manifest-path $TICKTICK_BIN_CARGO_MANIFEST_PATH --quiet -- --output-fmt markdown ...$args
}

export def "login" [] {
    let client_id = 'ux6PwQy0v5F8HBN7eG'
    let auth_object = {
        'client_id': $client_id
        'scope': 'tasks:read'
        'state': ''
        'redirect_uri': 'https://localhost/'
        'response_type': 'code'
    }
    start $'https://ticktick.com/oauth/authorize?($auth_object | url build-query)' | tee { print $in }

    let code = input "Now gimme the code! "
    let auth_object = {
        'client_id': $client_id
        'client_secret': '06hFSe66XcW43Ek!N!#xlmPU4(vG0(v3'
        'code': $code
        'grant_type': 'authorization_code'
        'scope': 'tasks:read'
        'redirect_uri': 'https://localhost/'
    }
    # TODO: ensure `token_type` == `bearer`, `access_token` is extracted, `expires_in` gets stored
    # with the token somewhere, and that `scope` matches.
    (
        http post $'https://ticktick.com/oauth/token'
            --headers { 'Content-Type': 'application/x-www-form-urlencoded' }
            ($auth_object | url build-query)
    ) | tee { print $in }

    # http get "https://api.ticktick.com/api/v2/project/all/completed/?from=&to=2025-10-29 21:47:46&limit=50"
}
