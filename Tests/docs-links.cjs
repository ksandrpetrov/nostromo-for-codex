"use strict";

const fs = require("node:fs");
const path = require("node:path");

const repositoryRoot = path.resolve(__dirname, "..");
const ignoredDirectories = new Set([".build", ".git", ".idea", ".swiftpm", "dist"]);
const markdownLinkPattern = /!?\[[^\]]*]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const htmlSourcePattern =
  /<(?:img|a|source)\b[^>]*(?:src|srcset|href)="([^"]+)"/g;
const externalSchemePattern = /^[a-z][a-z0-9+.-]*:/i;

function collectMarkdownFiles(directory) {
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) {
      continue;
    }
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectMarkdownFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith(".md")) {
      files.push(entryPath);
    }
  }
  return files;
}

function localTarget(rawTarget, sourceFile) {
  const target = rawTarget.replace(/^<|>$/g, "");
  if (
    target === ""
    || target.startsWith("#")
    || target.startsWith("//")
    || externalSchemePattern.test(target)
  ) {
    return null;
  }

  const withoutFragment = target.split("#", 1)[0].split("?", 1)[0];
  if (withoutFragment === "") {
    return null;
  }

  let decoded;
  try {
    decoded = decodeURIComponent(withoutFragment);
  } catch {
    return { error: `некорректный URL encoding: ${rawTarget}` };
  }

  return {
    path: decoded.startsWith("/")
      ? path.join(repositoryRoot, decoded)
      : path.resolve(path.dirname(sourceFile), decoded),
  };
}

const failures = [];
const markdownFiles = collectMarkdownFiles(repositoryRoot).sort();

for (const sourceFile of markdownFiles) {
  const contents = fs.readFileSync(sourceFile, "utf8");
  for (const pattern of [markdownLinkPattern, htmlSourcePattern]) {
    pattern.lastIndex = 0;
    for (const match of contents.matchAll(pattern)) {
      const target = localTarget(match[1], sourceFile);
      if (target === null) {
        continue;
      }
      if (target.error) {
        failures.push(`${path.relative(repositoryRoot, sourceFile)}: ${target.error}`);
      } else if (!fs.existsSync(target.path)) {
        failures.push(
          `${path.relative(repositoryRoot, sourceFile)}: отсутствует ${match[1]}`,
        );
      }
    }
  }
}

if (failures.length > 0) {
  console.error("Broken local documentation links:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exitCode = 1;
} else {
  console.log(`Documentation links OK (${markdownFiles.length} Markdown files).`);
}
