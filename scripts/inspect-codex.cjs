"use strict";

// Read-only compatibility report. Never loads Electron, native modules or HID.
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const manifest = require("../Sources/NostromoCodexApp/Resources/codex-compatibility.json");

function inspectArchive(archive) {
  if (archive.length < 16) throw new Error("Truncated ASAR header");
  const headerSize = archive.readUInt32LE(4);
  const jsonSize = archive.readUInt32LE(12);
  if (headerSize < 8 || headerSize > 16777216 || !jsonSize || jsonSize > headerSize - 8 || 8 + headerSize > archive.length) {
    throw new Error("Invalid ASAR header bounds");
  }
  const header = JSON.parse(archive.subarray(16, 16 + jsonSize).toString("utf8"));
  const files = header.files?.[".vite"]?.files?.build?.files;
  if (!files || Object.keys(files).length > 4096) throw new Error("Missing or oversized build directory");
  const matches = [];
  let inspected = 0;
  for (const [name, entry] of Object.entries(files).sort(([a], [b]) => a.localeCompare(b))) {
    if (!name.endsWith(".js") || /[\\/]/.test(name) || entry.unpacked) continue;
    const offset = Number(entry.offset), size = entry.size;
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(size) || size < 0 || size > 16777216 || inspected + size > 67108864) continue;
    const start = 8 + headerSize + offset;
    if (start > archive.length || size > archive.length - start) continue;
    inspected += size;
    const source = archive.subarray(start, start + size);
    if (manifest.serviceMarkers.every((marker) => source.includes(marker))) matches.push(`.vite/build/${name}`);
  }
  return {
    serviceModule: matches.length === 1 ? matches[0] : null,
    matchingServices: matches.length,
    missingRendererSurfaces: manifest.rendererMarkers.filter((marker) => !archive.includes(marker)),
  };
}

function inspectInstallation(bundle = "/Applications/ChatGPT.app") {
  const info = JSON.parse(execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", path.join(bundle, "Contents/Info.plist")], { encoding: "utf8" }));
  const version = info.CFBundleShortVersionString, build = info.CFBundleVersion;
  const result = inspectArchive(fs.readFileSync(path.join(bundle, "Contents/Resources/app.asar")));
  const missingFiles = ["Contents/MacOS/ChatGPT", "Contents/Resources/native/hid-topology-watcher.node", "Contents/Resources/app.asar.unpacked/node_modules/@worklouder/device-kit-oai"]
    .filter((file) => !fs.existsSync(path.join(bundle, file)));
  const entry = manifest.builds.find((entry) => entry.version === version && entry.build === build);
  const structurallyCompatible = info.CFBundleIdentifier === "com.openai.codex" && result.serviceModule !== null && result.missingRendererSurfaces.length === 0 && missingFiles.length === 0;
  return { version, build, status: !structurallyCompatible ? "incompatible" : entry?.verified ? "verified" : entry ? "candidate-needs-live-test" : "unverified-build", ...result, missingFiles };
}

module.exports = { inspectArchive, inspectInstallation };
if (require.main === module) {
  try { process.stdout.write(JSON.stringify(inspectInstallation(), null, 2) + "\n"); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
