"use strict";

// Usage: node scripts/coverage-summary.cjs <Swift coverage.json> <NODE_V8_COVERAGE directory>
// Coverage is reported, not used as a substitute for contract tests.
const fs = require("node:fs");
const path = require("node:path");
const [swiftFile, nodeDirectory] = process.argv.slice(2);
if (!swiftFile || !nodeDirectory) {
  console.error("Usage: node scripts/coverage-summary.cjs <Swift coverage.json> <Node coverage directory>");
  process.exit(64);
}
const groups = { core: { covered: 0, count: 0 }, app: { covered: 0, count: 0 }, ui: { covered: 0, count: 0 } };
for (const data of JSON.parse(fs.readFileSync(swiftFile, "utf8")).data) {
  for (const file of data.files) {
    if (!file.filename.includes("/Sources/")) continue;
    const group = file.filename.includes("/NostromoCodexCore/") ? groups.core
      : file.filename.includes("/UI/") ? groups.ui : groups.app;
    group.covered += file.summary.lines.covered;
    group.count += file.summary.lines.count;
  }
}
const functions = new Map();
for (const name of fs.readdirSync(nodeDirectory)) {
  if (!name.endsWith(".json")) continue;
  for (const script of JSON.parse(fs.readFileSync(path.join(nodeDirectory, name), "utf8")).result) {
    if (!script.url.endsWith("/Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs")) continue;
    for (const fn of script.functions) {
      const range = fn.ranges[0];
      const key = `${range.startOffset}:${range.endOffset}`;
      functions.set(key, (functions.get(key) || false) || range.count > 0);
    }
  }
}
if (functions.size === 0) throw new Error("No preload V8 coverage found");
groups.preloadFunctions = { covered: [...functions.values()].filter(Boolean).length, count: functions.size };
for (const group of Object.values(groups)) {
  group.percent = group.count ? Number((100 * group.covered / group.count).toFixed(2)) : null;
}
console.log(JSON.stringify(groups, null, 2));
