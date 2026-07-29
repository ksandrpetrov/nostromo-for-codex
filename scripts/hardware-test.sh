#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
script_name=${0:t}
mode=${1:---help}
hardware_snapshot=""

usage() {
  print "Usage: $script_name --inventory | --checklist | --launch-hid-only"
  print
  print "  --inventory  Read IORegistry and print matching Nostromo HID interfaces."
  print "  --checklist  Print the manual physical acceptance checklist."
  print "  --launch-hid-only  Open the built app with every ChatGPT action disabled."
  print
  print "Inventory/checklist never open HID. HID-only explicitly opens and may seize Nostromo."
}

inventory() {
  hardware_snapshot=$(mktemp -t nostromo-codex-ioreg)
  trap '[[ -n ${hardware_snapshot:-} ]] && rm -f -- "$hardware_snapshot"' EXIT
  ioreg -r -c IOHIDDevice -a > "$hardware_snapshot"

  local compact_output
  compact_output=$(plutil -p "$hardware_snapshot" | awk '
    /^  [0-9]+ => \{$/ {
      selected = ""
      nostromo = 0
      expected_vendor = 0
      expected_product = 0
      inside = 1
      next
    }
    inside && /^    "(LocationID|Manufacturer|MaxFeatureReportSize|MaxInputReportSize|MaxOutputReportSize|PrimaryUsage|PrimaryUsagePage|Product|ProductID|Transport|VendorID)" =>/ {
      selected = selected $0 "\n"
      if ($0 ~ /"Product" => "Razer Nostromo"/) nostromo = 1
      if ($0 ~ /"VendorID" => 5426$/) expected_vendor = 1
      if ($0 ~ /"ProductID" => 273$/) expected_product = 1
      if ($0 ~ /"MaxFeatureReportSize" => 90$/) interface_feature90 = 1
      if ($0 ~ /"PrimaryUsage" => 6$/) interface_keyboard = 1
      if ($0 ~ /"PrimaryUsage" => 2$/) interface_mouse = 1
    }
    inside && /^  \}$/ {
      if (nostromo && expected_vendor && expected_product) {
        count += 1
        printf "Interface %d\n%s", count, selected
        if (interface_feature90) feature90 = 1
        if (interface_keyboard) keyboard = 1
        if (interface_mouse) mouse = 1
      }
      inside = 0
      interface_feature90 = 0
      interface_keyboard = 0
      interface_mouse = 0
    }
    END {
      if (count == 0) exit 42
      if (count < 2 || !feature90 || !keyboard || !mouse) exit 43
    }
  ') || {
    local inventory_exit=$?
    if (( inventory_exit == 42 )); then
      print -u2 "Razer Nostromo 1532:0111 was not found in IORegistry."
      return 1
    fi
    if (( inventory_exit == 43 )); then
      print -u2 "Nostromo was found, but its keyboard/mouse topology or 90-byte feature report is missing."
      return 1
    fi
    return "$inventory_exit"
  }

  print "Read-only IORegistry inventory"
  print "Expected USB IDs: vendor 5426 (0x1532), product 273 (0x0111)"
  print -r -- "$compact_output"
  print "No IOHIDDevice was opened; no feature report was sent."
}

checklist() {
  sed -n '/^## Физическая матрица/,/^## /p' \
    "$project_dir/docs/hardware-acceptance.md" | sed '$d'
}

launch_hid_only() {
  local app_binary="$project_dir/dist/Nostromo Codex.app/Contents/MacOS/NostromoCodex"
  if [[ ! -x "$app_binary" ]]; then
    print -u2 "Built app is missing: $app_binary"
    print -u2 "Run ./scripts/build-app.sh release first."
    return 1
  fi
  if pgrep -x NostromoCodex >/dev/null 2>&1; then
    print -u2 "NostromoCodex is already running. Quit it first so HID-only cannot reuse a normal instance."
    return 1
  fi

  print "Launching HID-only mode."
  print "ChatGPT will not be started, stopped, focused, or sent actions."
  print "Nostromo may be seized according to the active profile; quit the app to release it."
  print "Export raw events from Dashboard → Диагностика → Экспорт JSON."
  exec env NOSTROMO_CODEX_HID_ONLY=1 "$app_binary"
}

case "$mode" in
  --inventory)
    inventory
    ;;
  --checklist)
    checklist
    ;;
  --launch-hid-only)
    launch_hid_only
    ;;
  --help|-h)
    usage
    ;;
  *)
    print -u2 "Unknown argument: $mode"
    usage >&2
    exit 64
    ;;
esac
