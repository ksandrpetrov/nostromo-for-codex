"use strict";

// Exercise the real shell checks with failing tools, without building or
// signing anything. A successful later command must never hide a failure.
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "nostromo-runner-test-"));
const library = path.resolve(__dirname, "../scripts/lib/deep-test-checks.zsh");
function run(body) {
  const result = spawnSync("/bin/zsh", ["-c", `
    set -u
    setopt pipefail
    source "$1"
    project_dir="$2"
    app_dir="$2/app"
    app_binary="$app_dir/Contents/MacOS/NostromoCodex"
    preload_file="$2/preload.cjs"
    results_dir="$2"
    results_jsonl="$2/results.jsonl"
    typeset -a result_names result_states result_durations
    integer failure_count=0
    ${body}
  `, "runner-test", library, root], { encoding: "utf8" });
  assert.equal(result.signal, null, result.stderr);
  return result;
}
try {
  fs.mkdirSync(path.join(root, "app/Contents/MacOS"), { recursive: true });
  fs.mkdirSync(path.join(root, "app/Contents/Resources"));
  fs.writeFileSync(path.join(root, "app/Contents/MacOS/NostromoCodex"), "", { mode: 0o700 });
  fs.writeFileSync(path.join(root, "app/Contents/Resources/chatgpt-preload.cjs"), "");
  fs.copyFileSync(path.resolve(__dirname, "../Resources/Info.plist"), path.join(root, "app/Contents/Info.plist"));
  for (const command of ["plutil", "cmp"]) {
    const result = run(`
      plutil() { return 0 }
      cmp() { return 0 }
      ${command}() { return 37 }
      verify_bundle
    `);
    assert.equal(result.status, 37, `${command} failure was masked: ${result.stdout}`);
  }
  const signature = run(`
    codesign() { if [[ "$1" == --verify ]]; then return 38; fi; return 0 }
    verify_codesign
  `);
  assert.equal(signature.status, 38, "signature verification failure was masked");
  const steps = run(`
    broken() { return 39 }
    run_step failed-child broken
    run_step successful-child true
    [[ $failure_count == 1 && $result_states[1] == FAIL && $result_states[2] == PASS ]]
  `);
  assert.equal(steps.status, 0, steps.stdout + steps.stderr);
  const records = fs.readFileSync(path.join(root, "results.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(records.map(r => r.exitCode), [39, 0]);
  const logFailure = run(`
    tee() { cat >/dev/null; return 40 }
    run_step failed-log true
    [[ $failure_count == 1 && $result_states[1] == FAIL ]]
  `);
  assert.equal(logFailure.status, 0, "log failure was ignored");
  console.log("deep-test runner fault injection passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
