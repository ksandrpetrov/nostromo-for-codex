#!/bin/zsh
set -u
setopt pipefail

project_dir=${0:A:h:h}
script_name=${0:t}
app_dir="$project_dir/dist/Nostromo Codex.app"
app_binary="$app_dir/Contents/MacOS/NostromoCodex"
preload_file="$project_dir/Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs"
smoke_file="$project_dir/Tests/preload-smoke.cjs"
mode=full
include_hardware_inventory=0
smoke_iterations=50
results_root=${NOSTROMO_TEST_RESULTS_DIR:-${TMPDIR:-/tmp}/nostromo-codex-deep-test}
if [[ "$results_root" != "/" ]]; then
  results_root=${results_root%/}
fi

usage() {
  print "Usage: $script_name [--full|--quick] [--hardware-inventory] [--results-dir PATH]"
  print
  print "  --full                Run all checks, including ASan and TSan (default)."
  print "  --quick               Skip sanitizers and run one preload smoke iteration."
  print "  --hardware-inventory  Add a read-only IORegistry inventory."
  print "  --results-dir PATH    Store logs below PATH instead of the system temp dir."
  print
  print "This script never opens Nostromo Codex and never stops or launches ChatGPT."
}

while (( $# > 0 )); do
  case "$1" in
    --full)
      mode=full
      ;;
    --quick)
      mode=quick
      smoke_iterations=1
      ;;
    --hardware-inventory)
      include_hardware_inventory=1
      ;;
    --results-dir)
      if (( $# < 2 )); then
        print -u2 "Missing value for --results-dir"
        exit 64
      fi
      shift
      results_root=$1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage >&2
      exit 64
      ;;
  esac
  shift
done

for required_command in swift node codesign lipo xcrun plutil tee; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    print -u2 "Required command is unavailable: $required_command"
    exit 69
  fi
done

run_id=$(date -u +"%Y%m%dT%H%M%SZ")
results_dir="$results_root/$run_id"
mkdir -p "$results_dir"
results_jsonl="$results_dir/results.jsonl"
summary_file="$results_dir/summary.md"
typeset -a result_names result_states result_durations
integer failure_count=0

record_result() {
  local name=$1
  local state=$2
  local exit_code=$3
  local duration=$4
  local log_path=$5

  result_names+=("$name")
  result_states+=("$state")
  result_durations+=("$duration")
  printf '{"step":"%s","status":"%s","exitCode":%d,"durationSeconds":%d,"log":"%s"}\n' \
    "$name" "$state" "$exit_code" "$duration" "$log_path" >> "$results_jsonl"
}

run_step() {
  local name=$1
  shift
  local log_file="$results_dir/$name.log"
  local started_at=$(date +%s)

  print
  print "[$name] $*"
  "$@" 2>&1 | tee "$log_file"
  local pipeline_status=("${pipestatus[@]}")
  local exit_code=${pipeline_status[1]:-1}
  local finished_at=$(date +%s)
  local duration=$(( finished_at - started_at ))

  if (( exit_code == 0 )); then
    print "[$name] PASS (${duration}s)"
    record_result "$name" PASS "$exit_code" "$duration" "$log_file"
  else
    print -u2 "[$name] FAIL, exit $exit_code (${duration}s)"
    record_result "$name" FAIL "$exit_code" "$duration" "$log_file"
    (( failure_count += 1 ))
  fi
}

capture_environment() {
  print "UTC: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  print "Architecture: $(uname -m)"
  sw_vers
  xcodebuild -version
  swift --version
  print "Node: $(node --version)"
  if [[ -r /Applications/ChatGPT.app/Contents/Info.plist ]]; then
    local version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      /Applications/ChatGPT.app/Contents/Info.plist 2>/dev/null || print unavailable)
    local build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
      /Applications/ChatGPT.app/Contents/Info.plist 2>/dev/null || print unavailable)
    print "Installed ChatGPT: $version ($build)"
  else
    print "Installed ChatGPT: not found at /Applications/ChatGPT.app"
  fi
}

repeat_preload_smoke() {
  local iterations=$1
  integer iteration
  for (( iteration = 1; iteration <= iterations; iteration += 1 )); do
    node "$smoke_file"
    print "preload smoke $iteration/$iterations"
  done
}

verify_bundle() {
  [[ -d "$app_dir" ]] || {
    print -u2 "App bundle does not exist: $app_dir"
    return 1
  }
  [[ -x "$app_binary" ]] || {
    print -u2 "App executable is missing: $app_binary"
    return 1
  }
  [[ -r "$app_dir/Contents/Resources/chatgpt-preload.cjs" ]] || {
    print -u2 "Preload resource is missing from the app bundle"
    return 1
  }
  plutil -lint "$app_dir/Contents/Info.plist"
  cmp "$preload_file" "$app_dir/Contents/Resources/chatgpt-preload.cjs"
  cmp "$project_dir/Sources/NostromoCodexApp/Resources/codex-compatibility.json" \
    "$app_dir/Contents/Resources/codex-compatibility.json"

  local executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
    "$app_dir/Contents/Info.plist")
  local minimum_version=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
    "$app_dir/Contents/Info.plist")
  [[ "$executable_name" == "NostromoCodex" ]] || {
    print -u2 "Unexpected CFBundleExecutable: $executable_name"
    return 1
  }
  [[ "$minimum_version" == "26.0" ]] || {
    print -u2 "Unexpected LSMinimumSystemVersion: $minimum_version"
    return 1
  }
  print "Bundle contents and Info.plist are consistent."
}

verify_codesign() {
  codesign --verify --deep --strict --verbose=2 "$app_dir"
  codesign --display --verbose=2 "$app_dir"
}

verify_architecture_and_minos() {
  local architecture=$(lipo -archs "$app_binary")
  local build_info=$(xcrun vtool -show-build "$app_binary")
  file "$app_binary"
  print -r -- "$build_info"

  [[ "$architecture" == "arm64" ]] || {
    print -u2 "Expected arm64-only executable, found: $architecture"
    return 1
  }
  [[ "$build_info" == *"platform MACOS"* ]] || {
    print -u2 "LC_BUILD_VERSION does not target macOS"
    return 1
  }
  [[ "$build_info" == *"minos 26.0"* ]] || {
    print -u2 "Expected minimum macOS 26.0"
    return 1
  }
  print "Architecture: arm64 only; deployment target: macOS 26.0."
}

write_summary() {
  {
    print "# Nostromo Codex deep-test run"
    print
    print -- "- Run: \`$run_id\`"
    print -- "- Mode: \`$mode\`"
    print -- "- Result directory: \`$results_dir\`"
    print -- "- Failures: \`$failure_count\`"
    print
    print "| Check | Result | Duration |"
    print "|---|---:|---:|"
    integer index
    for (( index = 1; index <= ${#result_names}; index += 1 )); do
      print "| \`${result_names[$index]}\` | ${result_states[$index]} | ${result_durations[$index]}s |"
    done
    print
    print "The runner did not open the app, seize HID interfaces, write LEDs, or restart ChatGPT."
  } > "$summary_file"
}

cd "$project_dir"
print "Nostromo Codex deep test"
print "Mode: $mode"
print "Logs: $results_dir"
print "Safety: ChatGPT will not be stopped or launched; HID will not be opened."

run_step environment capture_environment
run_step debug-tests swift test -c debug --arch arm64
run_step release-tests swift test -c release --arch arm64
run_step warnings-as-errors swift build -c release --arch arm64 \
  -Xswiftc -warnings-as-errors

if [[ "$mode" == full ]]; then
  run_step address-sanitizer swift test -c debug --arch arm64 --sanitize address
  run_step thread-sanitizer swift test -c debug --arch arm64 --sanitize thread
fi

run_step preload-syntax node --check "$preload_file"
run_step preload-unit node "$project_dir/Tests/preload-unit.cjs"
run_step preload-smoke repeat_preload_smoke "$smoke_iterations"
run_step package-app "$project_dir/scripts/build-app.sh" release
run_step bundle-contents verify_bundle
run_step codesign verify_codesign
run_step architecture-minos verify_architecture_and_minos

if (( include_hardware_inventory == 1 )); then
  run_step hardware-inventory "$project_dir/scripts/hardware-test.sh" --inventory
fi

write_summary
print
print "Summary: $summary_file"
print "Machine-readable results: $results_jsonl"

if (( failure_count > 0 )); then
  print -u2 "Deep test failed: $failure_count check(s) failed."
  exit 1
fi

print "Deep test passed."
