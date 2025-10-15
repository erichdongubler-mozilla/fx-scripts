const TICKTICK_BIN_CARGO_MANIFEST_PATH = path self ./Cargo.toml

export def "summary-to-daily" --wrapped [...args]: string -> string {
    cargo run --manifest-path $TICKTICK_BIN_CARGO_MANIFEST_PATH --quiet -- --output-fmt markdown ...$args
}
