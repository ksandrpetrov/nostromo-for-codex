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
mkdir -p "$results_root" || exit $?
results_dir=$(mktemp -d "$results_root/$run_id.XXXXXX") || exit $?
results_jsonl="$results_dir/results.jsonl"
summary_file="$results_dir/summary.md"
typeset -a result_names result_states result_durations
integer failure_count=0

source "$project_dir/scripts/lib/deep-test-checks.zsh"

cd "$project_dir" || exit $?
print "Nostromo Codex deep test"
print "Mode: $mode"
print "Logs: $results_dir"
print "Safety: ChatGPT will not be stopped or launched; HID will not be opened."

unset NOSTROMO_LIVE_E2E
run_step environment capture_environment
run_step runner-regressions node "$project_dir/Tests/deep-test-runner.cjs"
run_step docs-links node "$project_dir/Tests/docs-links.cjs"
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

write_summary || exit $?
print
print "Summary: $summary_file"
print "Machine-readable results: $results_jsonl"

if (( failure_count > 0 )); then
  print -u2 "Deep test failed: $failure_count check(s) failed."
  exit 1
fi

print "Deep test passed."
