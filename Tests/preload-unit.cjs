"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const Module = require("node:module");
const path = require("node:path");

const preloadPath = path.resolve(
  __dirname,
  "../Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs",
);

process.env.NOSTROMO_CODEX_CHATGPT_VERSION = "26.721.81911";
process.env.NOSTROMO_CODEX_CHATGPT_BUILD = "5973";
process.env.NOSTROMO_CODEX_SERVICE_MODULE = ".vite/build/codex-micro-service-test.js";
process.env.NOSTROMO_CODEX_ADAPTER = "micro-v1";
process.env.NOSTROMO_CODEX_TEST_EXPORTS = "1";
const preload = require(preloadPath);
const bridgeActionManifest = JSON.parse(fs.readFileSync(
  path.resolve(__dirname, "Fixtures/bridge-actions.json"),
  "utf8",
));

assert.doesNotThrow(
  preload.assertCompatible,
  "compatibility check must not require Electron during NODE_OPTIONS bootstrap",
);
assert.deepEqual(
  preload.appActionContract,
  bridgeActionManifest,
  "preload action names and payload keys must match the shared bridge contract",
);

const framing = new preload.BridgeLineBuffer();
assert.equal(framing.append('{"v":'), true);
assert.equal(framing.takeLine(), null);
assert.equal(framing.append('2}\n\nnext\npartial'), true);
assert.equal(framing.takeLine(), '{"v":2}');
assert.equal(framing.takeLine(), "");
assert.equal(framing.takeLine(), "next");
assert.equal(framing.takeLine(), null);
assert.equal(framing.remainder, "partial");
const bounded = new preload.BridgeLineBuffer();
assert.equal(bounded.append("x".repeat(1024 * 1024)), true);
assert.equal(bounded.append("x"), false);

const state = {
  appFocus: 0,
  appShow: 0,
  focused: 0,
  minimizeCount: 0,
  minimized: true,
  movedTop: 0,
  restored: 0,
  shown: 0,
  visible: false,
};
const window = {
  isDestroyed: () => false,
  isMinimized: () => state.minimized,
  isVisible: () => state.visible,
  moveTop: () => { state.movedTop += 1; },
  minimize: () => {
    state.minimized = true;
    state.visible = false;
    state.minimizeCount += 1;
  },
  restore: () => {
    state.minimized = false;
    state.restored += 1;
  },
  show: () => {
    state.visible = true;
    state.shown += 1;
  },
  focus: () => { state.focused += 1; },
  webContents: {
    isDestroyed: () => false,
  },
};
const hiddenUtilityWindow = {
  isDestroyed: () => false,
  isMinimized: () => false,
  isVisible: () => false,
  webContents: {
    isDestroyed: () => false,
  },
};
const electron = {
  app: {
    focus(options) {
      state.appFocus += 1;
      assert.deepEqual(options, { steal: true });
    },
    show() {
      state.appShow += 1;
    },
  },
  BrowserWindow: {
    getFocusedWindow: () => null,
    // Hidden utility windows are not a valid substitute for the minimized
    // primary window, even when Electron returns them first.
    getAllWindows: () => [hiddenUtilityWindow, window],
  },
};

const originalLoad = Module._load;
Module._load = function mockElectron(request, parent, isMain) {
  if (request === "electron") return electron;
  return Reflect.apply(originalLoad, this, [request, parent, isMain]);
};
try {
  assert.strictEqual(
    preload.usableWindow(),
    window,
    "a minimized window must remain selectable for restoration",
  );
  preload.toggleChatGPT(false);
  preload.toggleChatGPT(true);
  preload.toggleChatGPT(true);
} finally {
  Module._load = originalLoad;
  delete process.env.NOSTROMO_CODEX_TEST_EXPORTS;
}

assert.deepEqual(state, {
  appFocus: 2,
  appShow: 2,
  focused: 2,
  minimizeCount: 1,
  minimized: false,
  movedTop: 2,
  restored: 2,
  shown: 2,
  visible: true,
});

process.stdout.write("preload socket-free regressions passed\n");
