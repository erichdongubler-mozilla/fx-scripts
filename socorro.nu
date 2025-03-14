export def "api processed-crash" [
  crash_id: string,
] {
  _http get "ProcessedCrash/" { crash_id: $crash_id }
}

export def "api signatures-by-bugs" [
  ...bug_ids: int,
] {
  _http get "SignaturesByBugs/" { bug_ids: ($bug_ids | each { into string }) }
}

export def "api super-search" [
  arguments: record,
] {
  _http get "SuperSearch/" $arguments
}

export def reports-from-bug [
  bug_id: int,
] {
  let signatures = api signatures-by-bugs $bug_id | get hits.signature

  let reports = api super-search {
    signature: ($signatures | each { $'=($in)' }) # `=` is a string search operator for "exact match"
    product: Firefox
  } | get hits.uuid

  $reports | par-each { api processed-crash $in }
}

export def "_http get" [
  url_path: string,
  query_params: record,
] {
  const USER_AGENT_HEADER = ["User-Agent" "ErichDonGubler-Socorro-Nushell/1.0"]
  let req_url = $'https://crash-stats.mozilla.org/api/($url_path)?($query_params | url build-query)'
  http get --headers $USER_AGENT_HEADER $req_url
}

export def "signature-by-platform" [
  signature: string,
] {
  let pci_ids = pci-ids-db
  api super-search {
    product: 'Firefox'
    signature: $'=($signature)'
    '_columns': [
      'date'
      'build_id'
      'version'
      'platform'
      'platform_version'
      'adapter_vendor_id'
      'adapter_device_id'
      'adapter_driver_version'
    ]
  }
  | get hits
  | sort-by --natural adapter_vendor_id adapter_device_id adapter_driver_version
  | group-by adapter_vendor_id adapter_device_id --to-table
  | reject items.adapter_vendor_id items.adapter_device_id
  | each {|entry|
    try {
      mut adapter_vendor_id = $entry.adapter_vendor_id | to-u16
      mut adapter_device_id = $entry.adapter_device_id | to-u16

      let prettified = identify-pci-ids $pci_ids $adapter_vendor_id $adapter_device_id
      if $prettified != null {
        $adapter_vendor_id = $prettified.vendor
        if $prettified.device != null {
          $adapter_device_id = $prettified.device
        }
      }

      let adapter_vendor_id = $adapter_vendor_id
      let adapter_device_id = $adapter_device_id
      $entry
        | update adapter_vendor_id { $adapter_vendor_id }
        | update adapter_device_id { $adapter_device_id }
    } catch {
      $entry
    }
  }
}

export def "pci-ids-db" [] {
  use std log

  const URL = "https://pci-ids.ucw.cz/v2.2/pci.ids"

  const CACHE_PATH = (path self | path dirname | path join "pci.ids")
  if not ($CACHE_PATH | path exists) {
    log debug $"Downloading PCI device database from `($URL)` to `($CACHE_PATH)`…"
    http get $URL o> $CACHE_PATH
  }

  log debug $"Parsing PCI device database in `($CACHE_PATH)`…"
  let entries = open --raw $CACHE_PATH
    | lines
    | filter { not ($in | str starts-with '#') }
    | parse --regex ([
      '^'
      '(?P<leading_space>\t{1})?'
      '(?P<id>[0-9a-f]{4})'
      '  '
      '(?P<name>.+)'
      '$'
    ] | str join)
    | flatten
    | update id { decode hex }

  mut device_names_by_pid_by_vid = []
  mut current_vendor_name = null
  mut current_vendor_id = null
  mut current_vendor_devices = []
  for entry in $entries {
    if ($entry.leading_space | is-empty) {
      $device_names_by_pid_by_vid = $device_names_by_pid_by_vid | append {
        id: $current_vendor_id
        name: $current_vendor_name
        devices: $current_vendor_devices
      }
      $current_vendor_id = $entry.id
      $current_vendor_name = $entry.name
      $current_vendor_devices = []
    } else {
      $current_vendor_devices = $current_vendor_devices | append ($entry | reject leading_space)
    }
  }
  $device_names_by_pid_by_vid = $device_names_by_pid_by_vid | append {
    id: $current_vendor_id
    name: $current_vendor_name
    devices: $current_vendor_devices
  }

  $device_names_by_pid_by_vid
}

export def "identify-pci-ids" [
  pci_ids: any,
  vendor_id: binary,
  device_id: binary,
]: nothing -> any  {
  try {
    let vendor = $pci_ids | where id == $vendor_id | first
    let device = try {
      $vendor.devices | where id == $device_id | first
    } catch {
      null
    }


    {
      vendor: $vendor.name
      device: $device.name
    }
  } catch {
    null
  }
}

export def "to-u16" []: string -> binary {
  let raw = $in
  let parsed = $raw | parse '0x{hex}' | first | get hex | decode hex
  if ($parsed | bytes length) > 2 {
    error make {
      msg: "input too long"
      span: (metadata $raw).span
    }
  } else {
    $parsed | bytes at 0..1
  }
}
