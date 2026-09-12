# Functions shared by the runner and its fault-injection tests.
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
  if (( exit_code == 0 )); then
    exit_code=${pipeline_status[2]:-1}
  fi
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
  sw_vers || return $?
  xcodebuild -version || return $?
  swift --version || return $?
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
    node "$smoke_file" || return $?
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
  plutil -lint "$app_dir/Contents/Info.plist" || return $?
  cmp "$preload_file" "$app_dir/Contents/Resources/chatgpt-preload.cjs" || return $?
  cmp "$project_dir/Sources/NostromoCodexApp/Resources/codex-compatibility.json" \
    "$app_dir/Contents/Resources/codex-compatibility.json" || return $?

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
  codesign --verify --deep --strict --verbose=2 "$app_dir" || return $?
  codesign --display --verbose=2 "$app_dir"
}

verify_architecture_and_minos() {
  local architecture=$(lipo -archs "$app_binary")
  local build_info=$(xcrun vtool -show-build "$app_binary")
  file "$app_binary" || return $?
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

