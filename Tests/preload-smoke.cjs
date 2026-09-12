"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const Module = require("node:module");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");

const PRELOAD_PATH = path.resolve(
  __dirname,
  "../Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs",
);
const SYNTHETIC_PATH = "nostromo-codex://project2077";
const PROTOCOL_VERSION = 2;
const REPORT_LENGTH = 64;
const SUPPORTED_VERSION = "26.721.41059";
const CODEX_PARENT = { filename: "/mock/app.asar/.vite/build/codex-micro-service-CY8ASf0t.js" };
const MAIN_PARENT = { filename: "/mock/app.asar/.vite/build/main-CY8ASf0t.js" };
const WORKLOUDER_PARENT = {
  filename: "/mock/node_modules/@worklouder/device-kit-oai/dist/index.js",
};
const UNRELATED_PARENT = { filename: "/mock/unrelated-service.js" };

const scenario = process.argv[2];
if (scenario) {
  runScenario(scenario).catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  });
} else {
  runAllScenarios();
}

function runAllScenarios() {
  const scenarios = [
    "scoped-catalog",
    "runtime-capabilities",
    "early-electron-unavailable",
    "unsupported-version",
    "forced-version",
    "task-slot-metadata",
    "virtual-hid-actions",
    "ptt-failsafe",
    "close-queue-guard",
    "automatic-reconnect",
    "authentication-failure",
    "renamed-service",
    "candidate-version",
    "version-build-mismatch",
  ];

  for (const name of scenarios) {
    const environment = { ...process.env };
    delete environment.NODE_OPTIONS;
    delete environment.NOSTROMO_CODEX_DISCOVERY;
    delete environment.NOSTROMO_CODEX_SOCKET;
    delete environment.NOSTROMO_CODEX_TOKEN;
    delete environment.NOSTROMO_CODEX_FORCE;
    delete environment.NOSTROMO_CODEX_CHATGPT_VERSION;
    delete environment.NOSTROMO_CODEX_VERBOSE;

    const result = childProcess.spawnSync(process.execPath, [__filename, name], {
      encoding: "utf8",
      env: environment,
      timeout: 15_000,
    });
    assert.notEqual(
      result.error && result.error.code,
      "ETIMEDOUT",
      `preload scenario timed out: ${name}`,
    );
    assert.equal(
      result.status,
      0,
      [
        `preload scenario failed: ${name}`,
        result.stdout,
        result.stderr,
      ].filter(Boolean).join("\n"),
    );
    process.stdout.write(`ok - ${name}\n`);
  }

  process.stdout.write(`preload deep tests: ${scenarios.length}/${scenarios.length} passed\n`);
}

async function runScenario(name) {
  switch (name) {
    case "scoped-catalog":
      await testScopedCatalog();
      return;
    case "runtime-capabilities":
      await testRuntimeCapabilities();
      return;
    case "early-electron-unavailable":
      await testEarlyElectronUnavailable();
      return;
    case "unsupported-version":
      await testVersionGate(false);
      return;
    case "forced-version":
      await testVersionGate(true);
      return;
    case "candidate-version":
      await testVersionGate(false, "99.999.99999", "9999", true);
      return;
    case "version-build-mismatch":
      await testVersionGate(false, SUPPORTED_VERSION, "8378");
      return;
    case "task-slot-metadata":
      await testTaskSlotMetadata();
      return;
    case "virtual-hid-actions":
      await testVirtualHIDAndActions();
      return;
    case "ptt-failsafe":
      await testPushToTalkFailSafeAndQueueRecovery();
      return;
    case "close-queue-guard":
      await testQueuedActionIsDiscardedAfterBridgeClose();
      return;
    case "automatic-reconnect":
      await testAutomaticReconnectAcrossBridgeSessions();
      return;
    case "authentication-failure":
      await testAuthenticationFailure();
      return;
    case "renamed-service": {
      const harness = await createHarness({ version: "26.903.61454", build: "8378", service: "service-BuBDjGBu.js" });
      try {
        const parent = { filename: "/mock/app.asar/.vite/build/service-BuBDjGBu.js" };
        const topology = Module._load("hid-topology-watcher.node", parent, false);
        assert.ok((await topology.findCodexMicroInterfaces()).some((item) => item.path === SYNTHETIC_PATH));
        const unrelated = Module._load("hid-topology-watcher.node", { filename: "/mock/other/service-BuBDjGBu.js" }, false);
        assert.equal(unrelated, harness.fakeTopology);
      } finally { await harness.close(); }
      return;
    }
    default:
      throw new Error(`Unknown preload test scenario: ${name}`);
  }
}

async function testScopedCatalog() {
  const harness = await createHarness();
  try {
    const unscopedHID = Module._load("node-hid", UNRELATED_PARENT, false);
    assert.strictEqual(
      unscopedHID,
      harness.fakeNodeHID,
      "unrelated node-hid consumers must not receive the proxy",
    );
    assert.deepEqual(unscopedHID.devices(), [harness.realHIDDescriptor]);

    const codexHID = Module._load("node-hid", CODEX_PARENT, false);
    assert.notStrictEqual(codexHID, harness.fakeNodeHID);
    const syncDevices = codexHID.devices();
    assert.equal(syncDevices instanceof Promise, false, "devices() must remain synchronous");
    assertSyntheticCatalog(syncDevices, harness.realHIDDescriptor);

    const asyncDevices = await codexHID.devicesAsync();
    assertSyntheticCatalog(asyncDevices, harness.realHIDDescriptor);

    const workLouderHID = Module._load("node-hid", WORKLOUDER_PARENT, false);
    assert.strictEqual(workLouderHID, codexHID, "scoped consumers should share one proxy");

    const physicalDevice = await codexHID.HIDAsync.open("real://keyboard", "exclusive");
    assert.deepEqual(physicalDevice, { kind: "physical", path: "real://keyboard" });
    assert.deepEqual(harness.realOpenCalls, [
      { path: "real://keyboard", args: ["exclusive"] },
    ]);

    const topologyRequest = "/mock/hid-topology-watcher.node";
    const unscopedTopology = Module._load(topologyRequest, UNRELATED_PARENT, false);
    assert.strictEqual(unscopedTopology, harness.fakeTopology);

    const topology = Module._load(topologyRequest, CODEX_PARENT, false);
    assert.notStrictEqual(topology, harness.fakeTopology);
    const syncInterfaces = topology.findCodexMicroInterfaces("sync");
    assert.equal(
      syncInterfaces instanceof Promise,
      false,
      "synchronous topology discovery must remain synchronous",
    );
    assertSyntheticCatalog(syncInterfaces, harness.realTopologyDescriptor);

    const asyncInterfaces = await topology.findCodexMicroInterfaces("async");
    assertSyntheticCatalog(asyncInterfaces, harness.realTopologyDescriptor);

    const deduplicated = topology.findCodexMicroInterfaces("deduplicated");
    assert.equal(deduplicated.length, 1);
    assert.equal(deduplicated[0].path, "existing://codex-micro");

    // Discovery is conditional on a live Unix socket. Removing the socket path
    // simulates a bridge that disappeared without changing the module proxy.
    fs.unlinkSync(harness.socketPath);
    assert.deepEqual(codexHID.devices(), [harness.realHIDDescriptor]);
    assert.deepEqual(
      topology.findCodexMicroInterfaces("sync"),
      [harness.realTopologyDescriptor],
    );
  } finally {
    await harness.close();
  }
}

async function testRuntimeCapabilities() {
  let bridgePeer;
  const registeredCommands = [
    "composer.submit",
    "newTask",
    "composer.toggleFastMode",
    ...Array.from({ length: 60 }, (_, index) => `test.command.${index}`),
  ];
  const harness = await createHarness({
    commandIDs: registeredCommands,
    onConnection(socket) {
      bridgePeer = new JsonLinePeer(socket);
    },
  });

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const openPromise = hid.HIDAsync.open(SYNTHETIC_PATH);
    await waitUntil(() => bridgePeer);
    await bridgePeer.next((message) => message.type === "hello");
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: harness.token,
    });
    const device = await openPromise;

    const capabilities = await bridgePeer.next(
      (message) => message.type === "capabilities",
    );
    assert.equal(capabilities.commandRegistrySource, "runtime-app-asar");
    assert.deepEqual(capabilities.commandIds, [
      "composer.submit",
      "composer.toggleFastMode",
      "newTask",
    ]);
    assert.equal(capabilities.requiredApis.browserWindow, true);
    assert.equal(capabilities.requiredApis.rendererMessaging, true);
    assert.equal(capabilities.requiredApis.rendererEvaluation, true);
    assert.equal(capabilities.requiredApis.scopedHidHook, true);
    assert.equal(capabilities.requiredApis.microServiceHook, true);
    assert.equal(capabilities.chatGPTBuild, "5848");
    assert.equal(capabilities.chatGPTVersion, SUPPORTED_VERSION);
    assert.equal(capabilities.adapterID, "micro-v1");
    assert.equal(
      capabilities.unavailableFeatures.some((message) =>
        message.includes("Окно разрешений")),
      true,
    );

    const runtimeState = await bridgePeer.next(
      (message) => message.type === "runtime-state",
    );
    assert.equal(runtimeState.reasoningEffort, "high");
    harness.windowState.destroyed = true;
    device.publishCapabilities();
    const unavailable = await bridgePeer.next((message) => message.type === "capabilities");
    assert.equal(unavailable.requiredApis.rendererMessaging, false);
    harness.windowState.destroyed = false;
    device.publishCapabilities();
    const recovered = await bridgePeer.next((message) => message.type === "capabilities");
    assert.equal(recovered.requiredApis.rendererMessaging, true);
    await device.close();
  } finally {
    await harness.close();
  }
}

async function testEarlyElectronUnavailable() {
  const harness = await createHarness({
    electronAvailableDuringPreload: false,
  });
  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const topology = Module._load(
      "/mock/hid-topology-watcher.node",
      CODEX_PARENT,
      false,
    );
    assert.notStrictEqual(
      hid,
      harness.fakeNodeHID,
      "the HID hook must survive Electron's early CommonJS bootstrap",
    );
    assert.notStrictEqual(topology, harness.fakeTopology);
    assertSyntheticCatalog(hid.devices(), harness.realHIDDescriptor);
  } finally {
    await harness.close();
  }
}

async function testVersionGate(force, version = "99.999.99999", build = "5848", candidate = false) {
  const harness = await createHarness({
    version,
    build,
    force,
    candidate,
  });
  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const topology = Module._load(
      "/mock/hid_topology_watcher.node",
      CODEX_PARENT,
      false,
    );

    if (force) {
      assert.notStrictEqual(hid, harness.fakeNodeHID);
      assert.notStrictEqual(topology, harness.fakeTopology);
      assertSyntheticCatalog(hid.devices(), harness.realHIDDescriptor);
      assertSyntheticCatalog(
        topology.findCodexMicroInterfaces("sync"),
        harness.realTopologyDescriptor,
      );
    } else {
      assert.strictEqual(hid, harness.fakeNodeHID);
      assert.strictEqual(topology, harness.fakeTopology);
      assert.deepEqual(hid.devices(), [harness.realHIDDescriptor]);
      assert.deepEqual(
        topology.findCodexMicroInterfaces("sync"),
        [harness.realTopologyDescriptor],
      );
    }
  } finally {
    await harness.close();
  }
}

async function testTaskSlotMetadata() {
  let bridgePeer;
  const harness = await createHarness({
    onConnection(socket) {
      bridgePeer = new JsonLinePeer(socket);
    },
  });

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const openPromise = hid.HIDAsync.open(SYNTHETIC_PATH);
    await waitUntil(() => bridgePeer);
    await bridgePeer.next((message) => message.type === "hello");
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: harness.token,
    });
    const device = await openPromise;

    const serviceModule = Module._load(
      "./codex-micro-service-CY8ASf0t.js",
      MAIN_PARENT,
      false,
    );
    const service = new serviceModule.CodexMicroService();
    const lightingModel = {
      slots: [
        { id: 3, title: "Исправить меню дока", status: "working", selected: false },
        { id: 0, title: "Добавить переключение", status: "unread", selected: true },
        { id: 1, title: null, status: "off", selected: false },
      ],
    };
    assert.equal(await service.updateLighting(lightingModel), "updated");
    assert.deepEqual(service.updates, [lightingModel]);

    const metadata = await bridgePeer.next(
      (message) => message.type === "task-slots",
    );
    assert.deepEqual(metadata, {
      v: PROTOCOL_VERSION,
      type: "task-slots",
      slots: [
        {
          id: 0,
          title: "Добавить переключение",
          status: "unread",
          selected: true,
        },
        {
          id: 1,
          title: null,
          status: "off",
          selected: false,
        },
        {
          id: 3,
          title: "Исправить меню дока",
          status: "working",
          selected: false,
        },
      ],
    });

    await device.close();
  } finally {
    await harness.close();
  }
}

async function testVirtualHIDAndActions() {
  let bridgePeer;
  const harness = await createHarness({
    onConnection(socket) {
      bridgePeer = new JsonLinePeer(socket);
    },
  });

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const openPromise = hid.HIDAsync.open(SYNTHETIC_PATH);
    await waitUntil(() => bridgePeer);

    const hello = await bridgePeer.next((message) => message.type === "hello");
    assert.deepEqual(hello, {
      v: PROTOCOL_VERSION,
      type: "hello",
      role: "node-hid-shim",
      path: SYNTHETIC_PATH,
      token: harness.token,
    });

    // Split the handshake in the middle to prove line buffering works.
    const acknowledgement = `${JSON.stringify({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: harness.token,
    })}\n`;
    const split = Math.floor(acknowledgement.length / 2);
    bridgePeer.socket.write(acknowledgement.slice(0, split));
    await immediate();
    bridgePeer.socket.write(acknowledgement.slice(split));

    const device = await openPromise;
    const receivedReports = [];
    const asyncErrors = [];
    device.on("data", (report) => receivedReports.push(report));
    device.on("error", (error) => asyncErrors.push(error));

    const hostReport = Buffer.from(
      Array.from({ length: REPORT_LENGTH }, (_, index) => (index * 17) & 0xff),
    );
    assert.equal(await device.write(hostReport), REPORT_LENGTH);
    const written = await bridgePeer.next((message) => message.type === "host-report");
    assert.equal(written.v, PROTOCOL_VERSION);
    assert.deepEqual(Buffer.from(written.data, "base64"), hostReport);
    await assert.rejects(
      device.write(Buffer.alloc(REPORT_LENGTH - 1)),
      /должна содержать 64 байт/,
    );

    const deviceReport = Buffer.from(
      Array.from({ length: REPORT_LENGTH }, (_, index) => 255 - index),
    );
    const reportLine = `${JSON.stringify({
      v: PROTOCOL_VERSION,
      type: "device-report",
      data: deviceReport.toString("base64"),
    })}\n`;
    bridgePeer.socket.write(reportLine.slice(0, 11));
    await immediate();
    bridgePeer.socket.write(reportLine.slice(11));
    await waitUntil(() => receivedReports.length === 1);
    assert.deepEqual(receivedReports[0], deviceReport);

    // Invalid base64/length is ignored, malformed JSON is reported asynchronously.
    bridgePeer.send({ v: PROTOCOL_VERSION, type: "device-report", data: "AQ==" });
    bridgePeer.socket.write("{malformed-json}\n");
    await waitUntil(() => asyncErrors.length === 1);
    assert.match(asyncErrors[0].message, /некорректный JSON/);
    assert.equal(receivedReports.length, 1);

    // Syntactically valid JSON can still be an invalid envelope. None of
    // these frames may throw out of the socket data callback or emit a report.
    for (const frame of ["null", "[]", "true", "42", '"text"']) {
      bridgePeer.socket.write(`${frame}\n`);
    }
    for (const data of [null, 42, {}, [], true]) {
      bridgePeer.send({ v: PROTOCOL_VERSION, type: "device-report", data });
    }
    await waitUntil(() => asyncErrors.length === 6);
    assert.equal(receivedReports.length, 1);

    harness.windowState.visible = false;
    harness.windowState.minimized = true;
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 101,
      action: "toggle-chatgpt",
      payload: { minimizeIfVisible: "false" },
    });
    const focusResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 101,
    );
    assert.equal(focusResult.ok, true);
    assert.equal(harness.windowState.showCount, 1);
    assert.equal(harness.windowState.restoreCount, 1);
    assert.equal(harness.windowState.moveTopCount, 1);
    assert.equal(harness.windowState.appShowCount, 1);
    assert.equal(harness.windowState.appFocusCount, 1);
    assert.deepEqual(harness.windowState.lastAppFocusOptions, { steal: true });

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 102,
      action: "toggle-chatgpt",
      payload: { minimizeIfVisible: "true" },
    });
    const minimizeResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 102,
    );
    assert.equal(minimizeResult.ok, true);
    assert.equal(harness.windowState.minimizeCount, 1);
    assert.equal(harness.windowState.minimized, true);
    harness.windowState.minimized = false;
    harness.windowState.visible = true;

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 1,
      action: "run-command",
      payload: { commandId: "composer.togglePlanMode" },
    });
    const allowedResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 1,
    );
    assert.deepEqual(allowedResult, {
      v: PROTOCOL_VERSION,
      type: "app-action-result",
      id: 1,
      ok: true,
    });
    assert.deepEqual(harness.viewMessages.at(-1), {
      channel: "codex_desktop:message-for-view",
      message: { type: "run-command", id: "composer.togglePlanMode" },
    });

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 100,
      action: "run-command",
      payload: { commandId: "composer.cycleReasoningEffort" },
    });
    const cycleReasoningResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 100,
    );
    assert.equal(cycleReasoningResult.ok, true);
    assert.deepEqual(harness.viewMessages.at(-1), {
      channel: "codex_desktop:message-for-view",
      message: { type: "run-command", id: "composer.cycleReasoningEffort" },
    });

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 103,
      action: "toggle-chat-work-mode",
      payload: {},
    });
    const toggleChatWorkResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 103,
    );
    assert.equal(toggleChatWorkResult.ok, true);
    assert.equal(
      harness.evaluatedScripts.some((script) =>
        script.includes("NOSTROMO_CHAT_WORK_MODE_TOGGLE") &&
        script.includes('button[aria-pressed]')),
      true,
    );

    harness.projectDOM.configure({ buttonCount: 1 });
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 117,
      action: "clear-composer-project",
      payload: {},
    });
    const clearProjectResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 117,
    );
    assert.equal(clearProjectResult.ok, true);
    assert.equal(harness.projectDOM.clickCount, 1);
    assert.equal(
      harness.evaluatedScripts.some((script) =>
        script.includes("NOSTROMO_CLEAR_COMPOSER_PROJECT") &&
        script.includes("button[data-clear-project-button]:not(:disabled)")),
      true,
    );

    for (const [id, buttonCount, errorPattern] of [
      [118, 0, /недоступна/],
      [119, 2, /несколько кнопок/],
    ]) {
      harness.projectDOM.configure({ buttonCount });
      bridgePeer.send({
        v: PROTOCOL_VERSION,
        type: "app-action",
        id,
        action: "clear-composer-project",
        payload: {},
      });
      const rejectedClearProject = await bridgePeer.next(
        (message) => message.type === "app-action-result" && message.id === id,
      );
      assert.equal(rejectedClearProject.ok, false);
      assert.match(rejectedClearProject.error, errorPattern);
      assert.equal(harness.projectDOM.clickCount, 0);
    }

    harness.submitDOM.configure({ mode: "chat" });
    const messagesBeforeChatSubmit = harness.viewMessages.length;
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 104,
      action: "submit-active-composer",
      payload: {},
    });
    const chatSubmitResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 104,
    );
    assert.equal(chatSubmitResult.ok, true);
    assert.equal(harness.submitDOM.clickCount, 1);
    assert.equal(harness.viewMessages.length, messagesBeforeChatSubmit);

    harness.submitDOM.configure({ mode: "work" });
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 105,
      action: "submit-active-composer",
      payload: {},
    });
    const workSubmitResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 105,
    );
    assert.equal(workSubmitResult.ok, true);
    assert.equal(harness.submitDOM.clickCount, 0);
    assert.deepEqual(harness.viewMessages.at(-1), {
      channel: "codex_desktop:message-for-view",
      message: { type: "run-command", id: "composer.submit" },
    });

    harness.submitDOM.configure({ mode: "none" });
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 106,
      action: "submit-active-composer",
      payload: {},
    });
    const noHomeToggleSubmitResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 106,
    );
    assert.equal(noHomeToggleSubmitResult.ok, true);
    assert.equal(harness.submitDOM.clickCount, 0);
    assert.deepEqual(harness.viewMessages.at(-1), {
      channel: "codex_desktop:message-for-view",
      message: { type: "run-command", id: "composer.submit" },
    });

    for (const [id, submitDOM, errorPattern] of [
      [107, { mode: "chat", disabled: true }, /сейчас недоступна/],
      [108, { mode: "chat", buttonCount: 2 }, /несколько кнопок/],
      [109, { mode: "chat", focused: false, formCount: 2 }, /несколько кнопок/],
      [110, { mode: "chat", rootBlocked: true }, /сейчас заблокировано/],
    ]) {
      harness.submitDOM.configure(submitDOM);
      const messagesBeforeRejectedSubmit = harness.viewMessages.length;
      bridgePeer.send({
        v: PROTOCOL_VERSION,
        type: "app-action",
        id,
        action: "submit-active-composer",
        payload: {},
      });
      const rejectedSubmitResult = await bridgePeer.next(
        (message) => message.type === "app-action-result" && message.id === id,
      );
      assert.equal(rejectedSubmitResult.ok, false);
      assert.match(rejectedSubmitResult.error, errorPattern);
      assert.equal(harness.submitDOM.clickCount, 0);
      assert.equal(harness.viewMessages.length, messagesBeforeRejectedSubmit);
    }

    for (const [id, mode] of [[111, "chat"], [112, "work"]]) {
      harness.submitDOM.configure({ mode, stopButtonCount: 1 });
      const inputEventsBeforeStop = harness.inputEvents.length;
      bridgePeer.send({
        v: PROTOCOL_VERSION,
        type: "app-action",
        id,
        action: "stop-active",
        payload: {},
      });
      const stopResult = await bridgePeer.next(
        (message) => message.type === "app-action-result" && message.id === id,
      );
      assert.equal(stopResult.ok, true);
      assert.equal(harness.submitDOM.clickCount, 1);
      assert.equal(harness.inputEvents.length, inputEventsBeforeStop);
    }

    harness.submitDOM.configure({ mode: "none" });
    const inputEventsBeforeStopFallback = harness.inputEvents.length;
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 113,
      action: "stop-active",
      payload: {},
    });
    const stopFallbackResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 113,
    );
    assert.equal(stopFallbackResult.ok, true);
    assert.deepEqual(
      harness.inputEvents.slice(inputEventsBeforeStopFallback),
      [
        { type: "keyDown", keyCode: "Escape" },
        { type: "keyUp", keyCode: "Escape" },
      ],
    );

    for (const [id, stopDOM, errorPattern] of [
      [114, { mode: "chat", stopButtonCount: 1, stopDisabled: true }, /сейчас недоступна/],
      [115, { mode: "chat", stopButtonCount: 2 }, /несколько кнопок/],
      [116, { mode: "chat", stopButtonCount: 1, rootBlocked: true }, /сейчас заблокирован/],
    ]) {
      harness.submitDOM.configure(stopDOM);
      const inputEventsBeforeRejectedStop = harness.inputEvents.length;
      bridgePeer.send({
        v: PROTOCOL_VERSION,
        type: "app-action",
        id,
        action: "stop-active",
        payload: {},
      });
      const rejectedStopResult = await bridgePeer.next(
        (message) => message.type === "app-action-result" && message.id === id,
      );
      assert.equal(rejectedStopResult.ok, false);
      assert.match(rejectedStopResult.error, errorPattern);
      assert.equal(harness.submitDOM.clickCount, 0);
      assert.equal(harness.inputEvents.length, inputEventsBeforeRejectedStop);
    }

    const messageCountAfterAllowedCommand = harness.viewMessages.length;
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 2,
      action: "run-command",
      payload: { commandId: "shell.execute-arbitrary-command" },
    });
    const deniedResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 2,
    );
    assert.equal(deniedResult.ok, false);
    assert.match(deniedResult.error, /отсутствует в списке разрешённых/);
    assert.equal(harness.viewMessages.length, messageCountAfterAllowedCommand);

    const submitCountBeforePlugin = harness.viewMessages.filter(({ message }) =>
      message.type === "run-command" && message.id === "composer.submit"
    ).length;
    const focusCountBeforePlugin = harness.windowState.focusCount;
    const pluginText = "[@Linear](plugin://linear/issue) подготовь черновик";
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 3,
      action: "prepare-plugin-prompt",
      payload: { text: pluginText },
    });
    const pluginResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 3,
    );
    assert.equal(pluginResult.ok, true);
    assert.deepEqual(harness.viewMessages.at(-1), {
      channel: "codex_desktop:message-for-view",
      message: {
        type: "codex-micro-insert-composer-text",
        text: pluginText,
      },
    });
    assert.equal(harness.windowState.focusCount, focusCountBeforePlugin + 1);
    assert.equal(
      harness.viewMessages.filter(({ message }) =>
        message.type === "run-command" && message.id === "composer.submit"
      ).length,
      submitCountBeforePlugin,
      "plugin preparation must not submit the composer",
    );
    assert.equal(
      harness.inputEvents.some((event) =>
        event.keyCode === "Enter" || event.keyCode === "Return"),
      false,
      "plugin preparation must not synthesize an Enter key",
    );

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 4,
      action: "not-a-real-action",
      payload: {},
    });
    const unsupportedResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 4,
    );
    assert.equal(unsupportedResult.ok, false);
    assert.match(unsupportedResult.error, /Неподдерживаемое действие Nostromo/);

    harness.windowState.destroyed = true;
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 5,
      action: "run-command",
      payload: { commandId: "newTask" },
    });
    const noWindowResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 5,
    );
    assert.equal(noWindowResult.ok, false);
    assert.match(noWindowResult.error, /Нет доступного окна ChatGPT/);

    const closeEvent = onceEvent(device, "close");
    await device.close();
    await closeEvent;
    assert.equal(device.closed, true);
    await assert.rejects(device.write(Buffer.alloc(REPORT_LENGTH)), /закрыт/);
    assert.equal(bridgePeer.ended, true);
  } finally {
    await harness.close();
  }
}

async function testAuthenticationFailure() {
  let connectionCount = 0;
  const harness = await createHarness({
    onConnection(socket) {
      // The oversized-handshake branch intentionally makes the client reset
      // the socket; consume that expected server-side transport error.
      socket.on("error", () => {});
      connectionCount += 1;
      const peer = new JsonLinePeer(socket);
      peer.next((message) => message.type === "hello").then(() => {
        if (connectionCount === 1) {
          peer.send({
            v: PROTOCOL_VERSION,
            type: "hello-ack",
            token: "wrong-token",
          });
        } else if (connectionCount === 2) {
          socket.write("not-json\n");
        } else if (connectionCount === 3) {
          socket.write("null\n");
        } else {
          socket.write("x".repeat(1024 * 1024 + 1));
        }
      });
    },
  });

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    await assert.rejects(
      hid.HIDAsync.open(SYNTHETIC_PATH),
      /аутентификац/,
    );
    await assert.rejects(
      hid.HIDAsync.open(SYNTHETIC_PATH),
      /некорректный JSON согласования/,
    );
    await assert.rejects(
      hid.HIDAsync.open(SYNTHETIC_PATH),
      /некорректный JSON согласования/,
    );
    await assert.rejects(
      hid.HIDAsync.open(SYNTHETIC_PATH),
      /превысили 1 МиБ/,
    );
    assert.equal(connectionCount, 4);
  } finally {
    await harness.close();
  }
}

async function testAutomaticReconnectAcrossBridgeSessions() {
  let firstPeer;
  const replacementPeers = [];
  const harness = await createHarness({
    reconnectable: true,
    onConnection(socket) {
      firstPeer = new JsonLinePeer(socket);
    },
  });

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const openPromise = hid.HIDAsync.open(SYNTHETIC_PATH);
    await waitUntil(() => firstPeer);
    await firstPeer.next((message) => message.type === "hello");
    firstPeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: harness.token,
    });
    const device = await openPromise;
    let closeCount = 0;
    const asynchronousErrors = [];
    device.on("close", () => { closeCount += 1; });
    device.on("error", (error) => asynchronousErrors.push(error));

    const replacement = await harness.replaceBridge({
      advertisedToken: "c".repeat(64),
      publishDescriptor: false,
      token: "b".repeat(64),
      onConnection(socket) {
        replacementPeers.push(new JsonLinePeer(socket));
      },
    });

    await waitUntil(() => device.socket === null);
    device.publishCapabilities();
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(asynchronousErrors, [], "capability polling must stay quiet while reconnecting");

    harness.publishDescriptor("c".repeat(64), 0o644);
    await new Promise((resolve) => setTimeout(resolve, 350));
    assert.equal(
      replacementPeers.length,
      0,
      "a reconnect descriptor with public permissions must be rejected",
    );
    harness.publishDescriptor("c".repeat(64));
    await waitUntil(() => replacementPeers.length >= 1, 4_000);
    const stalePeer = replacementPeers[0];
    const staleHello = await stalePeer.next((message) => message.type === "hello");
    assert.equal(staleHello.token, "c".repeat(64));
    stalePeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: replacement.token,
    });

    harness.publishDescriptor(replacement.token);
    await waitUntil(() => replacementPeers.length >= 2, 4_000);
    const recoveredPeer = replacementPeers.at(-1);
    const recoveredHello = await recoveredPeer.next(
      (message) => message.type === "hello",
    );
    assert.equal(recoveredHello.token, replacement.token);
    assert.equal(recoveredHello.path, SYNTHETIC_PATH);
    recoveredPeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: replacement.token,
    });
    const recoveredCapabilities = await recoveredPeer.next((message) => message.type === "capabilities");
    assert.equal(recoveredCapabilities.chatGPTVersion, SUPPORTED_VERSION);
    assert.equal(recoveredCapabilities.chatGPTBuild, "5848");
    assert.equal(recoveredCapabilities.requiredApis.microServiceHook, true);

    harness.windowState.destroyed = true;
    device.publishCapabilities();
    await recoveredPeer.next((message) => message.type === "capabilities" && !message.requiredApis.rendererMessaging);
    harness.windowState.destroyed = false;
    device.publishCapabilities();
    await recoveredPeer.next((message) => message.type === "capabilities" && message.requiredApis.rendererMessaging);

    assert.equal(closeCount, 0, "a transient bridge restart must not close the virtual HID");
    assert.equal(device.closed, false);
    assert.deepEqual(asynchronousErrors, []);

    recoveredPeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 901,
      action: "run-command",
      payload: { commandId: "composer.togglePlanMode" },
    });
    const actionResult = await recoveredPeer.next(
      (message) => message.type === "app-action-result" && message.id === 901,
    );
    assert.equal(actionResult.ok, true);

    const report = Buffer.alloc(REPORT_LENGTH, 0x5a);
    assert.equal(await device.write(report), REPORT_LENGTH);
    const hostReport = await recoveredPeer.next(
      (message) => message.type === "host-report",
    );
    assert.deepEqual(Buffer.from(hostReport.data, "base64"), report);

    const closeEvent = onceEvent(device, "close");
    await device.close();
    await closeEvent;
    assert.equal(closeCount, 1, "an explicit close must remain terminal");
  } finally {
    await harness.close();
  }
}

async function testPushToTalkFailSafeAndQueueRecovery() {
  let bridgePeer;
  const harness = await createHarness({
    onConnection(socket) {
      bridgePeer = new JsonLinePeer(socket);
    },
  });
  const unhandledRejections = [];
  const onUnhandledRejection = (error) => unhandledRejections.push(error);
  process.on("unhandledRejection", onUnhandledRejection);

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const openPromise = hid.HIDAsync.open(SYNTHETIC_PATH);
    await waitUntil(() => bridgePeer);
    await bridgePeer.next((message) => message.type === "hello");
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: harness.token,
    });
    const device = await openPromise;
    const asynchronousErrors = [];
    device.on("error", (error) => asynchronousErrors.push(error));

    // Make both the success ACK and the fallback error ACK fail. The queue
    // must absorb that rejection and remain usable for the next action.
    const originalWrite = device.socket.write;
    let injectedWriteFailures = 2;
    device.socket.write = function injectedWrite(data, callback) {
      if (injectedWriteFailures > 0) {
        injectedWriteFailures -= 1;
        setImmediate(() => callback(new Error("injected ACK write failure")));
        return true;
      }
      return Reflect.apply(originalWrite, this, [data, callback]);
    };
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 1,
      action: "push-to-talk-start",
      payload: {},
    });
    await waitUntil(() =>
      harness.viewMessages.some(({ message }) =>
        message.type === "codex-micro-push-to-talk-start"));
    await waitUntil(() =>
      asynchronousErrors.some((error) => /injected ACK write failure/.test(error.message)));
    device.socket.write = originalWrite;

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 2,
      action: "run-command",
      payload: { commandId: "composer.togglePlanMode" },
    });
    const recoveredResult = await bridgePeer.next(
      (message) => message.type === "app-action-result" && message.id === 2,
    );
    assert.equal(recoveredResult.ok, true, "action queue must recover after an ACK write failure");

    const closeEvent = onceEvent(device, "close");
    bridgePeer.socket.destroy();
    await closeEvent;
    await waitUntil(() =>
      harness.viewMessages.at(-1)?.message.type === "codex-micro-push-to-talk-stop");
    assert.equal(device.closed, true);
    await new Promise((resolve) => setTimeout(resolve, 25));
    assert.deepEqual(unhandledRejections, []);
  } finally {
    process.removeListener("unhandledRejection", onUnhandledRejection);
    await harness.close();
  }
}

async function testQueuedActionIsDiscardedAfterBridgeClose() {
  let bridgePeer;
  const harness = await createHarness({
    onConnection(socket) {
      bridgePeer = new JsonLinePeer(socket);
    },
  });

  try {
    const hid = Module._load("node-hid", CODEX_PARENT, false);
    const openPromise = hid.HIDAsync.open(SYNTHETIC_PATH);
    await waitUntil(() => bridgePeer);
    await bridgePeer.next((message) => message.type === "hello");
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "hello-ack",
      token: harness.token,
    });
    const device = await openPromise;

    const originalWrite = device.socket.write;
    let releaseDelayedAcknowledgement;
    device.socket.write = function delayFirstAcknowledgement(data, callback) {
      if (!releaseDelayedAcknowledgement) {
        releaseDelayedAcknowledgement = () => callback();
        return true;
      }
      return Reflect.apply(originalWrite, this, [data, callback]);
    };

    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 1,
      action: "run-command",
      payload: { commandId: "composer.togglePlanMode" },
    });
    await waitUntil(() => typeof releaseDelayedAcknowledgement === "function");
    bridgePeer.send({
      v: PROTOCOL_VERSION,
      type: "app-action",
      id: 2,
      action: "push-to-talk-start",
      payload: {},
    });

    const closeEvent = onceEvent(device, "close");
    bridgePeer.socket.destroy();
    await closeEvent;
    releaseDelayedAcknowledgement();
    await immediate();
    await immediate();

    assert.equal(
      harness.viewMessages.some(({ message }) =>
        message.type === "codex-micro-push-to-talk-start"),
      false,
      "an action queued for a dead bridge generation must never execute",
    );
  } finally {
    await harness.close();
  }
}

async function createHarness(options = {}) {
  const {
    commandIDs,
    electronAvailableDuringPreload = true,
    force = false,
    onConnection: initialOnConnection = () => {},
    reconnectable = false,
    version = SUPPORTED_VERSION,
    build = "5848",
    service = "codex-micro-service-CY8ASf0t.js",
    candidate = false,
  } = options;
  const runtime = fs.mkdtempSync(path.join(
    reconnectable ? "/tmp" : os.tmpdir(),
    reconnectable ? "ncpt-" : "nostromo-preload-test-",
  ));
  let preloadPath = PRELOAD_PATH;
  if (candidate) {
    // Keep candidate rejection covered without adding fake builds to the
    // production allowlist or modifying a live app's resources.
    preloadPath = path.join(runtime, "chatgpt-preload.cjs");
    fs.copyFileSync(PRELOAD_PATH, preloadPath);
    preloadPath = fs.realpathSync(preloadPath);
    const manifest = JSON.parse(fs.readFileSync(
      path.join(path.dirname(PRELOAD_PATH), "codex-compatibility.json"), "utf8",
    ));
    manifest.builds.push({ version, build, adapter: "micro-v1", verified: false });
    fs.writeFileSync(path.join(runtime, "codex-compatibility.json"), JSON.stringify(manifest));
  }
  const discoveryDirectory = path.join(
    runtime,
    `nostromo-codex-discovery-${typeof process.geteuid === "function" ? process.geteuid() : 0}`,
  );
  const discoveryPath = path.join(discoveryDirectory, "session.json");
  if (reconnectable) fs.mkdirSync(discoveryDirectory, { mode: 0o700 });
  let sessionSequence = 1;
  let session = reconnectable
    ? createReconnectableSession(runtime, sessionSequence)
    : null;
  let socketPath = session?.socketPath ?? path.join(runtime, "bridge.sock");
  let token = reconnectable ? "a".repeat(64) : "deterministic-test-token";
  let activeOnConnection = initialOnConnection;
  const sockets = new Set();
  const makeServer = () => net.createServer((socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
      activeOnConnection(socket);
    });
  let server = makeServer();
  await listen(server, socketPath);
  if (reconnectable) {
    fs.chmodSync(socketPath, 0o600);
    publishReconnectDescriptor(discoveryPath, session, token);
  }

  const realHIDDescriptor = Object.freeze({
    path: "real://keyboard",
    vendorId: 0x1532,
    productId: 0x0111,
    usagePage: 1,
  });
  const realTopologyDescriptor = Object.freeze({
    path: "real://topology-device",
    vendorId: 0x1234,
    productId: 0xabcd,
    usagePage: 1,
  });
  const existingCodexDescriptor = Object.freeze({
    path: "existing://codex-micro",
    vendorId: 0x303a,
    productId: 0x8360,
    usagePage: 0xff00,
  });
  const realOpenCalls = [];
  const viewMessages = [];
  const inputEvents = [];
  const evaluatedScripts = [];
  const submitDOM = createSubmitDOMHarness(options.submitDOM);
  const projectDOM = createProjectDOMHarness(options.projectDOM);
  const windowState = {
    appFocusCount: 0,
    appShowCount: 0,
    destroyed: false,
    minimized: false,
    lastAppFocusOptions: null,
    minimizeCount: 0,
    moveTopCount: 0,
    visible: true,
    focusCount: 0,
    restoreCount: 0,
    showCount: 0,
  };

  const fakeWindow = {
    getContentBounds: () => ({ width: 1200, height: 800 }),
    isDestroyed: () => windowState.destroyed,
    isMinimized: () => windowState.minimized,
    isVisible: () => windowState.visible,
    moveTop() {
      windowState.moveTopCount += 1;
    },
    minimize() {
      windowState.minimized = true;
      windowState.visible = false;
      windowState.minimizeCount += 1;
    },
    restore() {
      windowState.minimized = false;
      windowState.restoreCount += 1;
    },
    show() {
      windowState.visible = true;
      windowState.showCount += 1;
    },
    focus() {
      windowState.focusCount += 1;
    },
    webContents: {
      executeJavaScript: async (script) => {
        evaluatedScripts.push(script);
        if (script.includes("NOSTROMO_ACTIVE_COMPOSER_SUBMIT")) {
          return submitDOM.evaluate(script);
        }
        if (script.includes("NOSTROMO_ACTIVE_COMPOSER_STOP")) {
          return submitDOM.evaluate(script);
        }
        if (script.includes("NOSTROMO_CHAT_WORK_MODE_TOGGLE")) {
          return { ok: true, from: "Chat", to: "Work" };
        }
        if (script.includes("NOSTROMO_CLEAR_COMPOSER_PROJECT")) {
          return projectDOM.evaluate(script);
        }
        return "high";
      },
      isDestroyed: () => windowState.destroyed,
      send(channel, message) {
        viewMessages.push({ channel, message });
      },
      sendInputEvent(event) {
        inputEvents.push(event);
      },
    },
  };
  const fakeElectron = {
    app: {
      focus(options) {
        windowState.appFocusCount += 1;
        windowState.lastAppFocusOptions = options;
      },
      getVersion: () => version,
      show() {
        windowState.appShowCount += 1;
      },
    },
    BrowserWindow: {
      getFocusedWindow: () =>
        windowState.destroyed || windowState.minimized || !windowState.visible
          ? null
          : fakeWindow,
      getAllWindows: () => windowState.destroyed ? [] : [fakeWindow],
    },
  };
  const fakeTopology = {
    findCodexMicroInterfaces(mode) {
      if (mode === "async") return Promise.resolve([realTopologyDescriptor]);
      if (mode === "deduplicated") return [existingCodexDescriptor];
      return [realTopologyDescriptor];
    },
    watch: () => "real-watcher",
  };
  class FakeHIDAsync {
    static async open(openPath, ...args) {
      realOpenCalls.push({ path: openPath, args });
      return { kind: "physical", path: openPath };
    }
  }
  const fakeNodeHID = {
    HIDAsync: FakeHIDAsync,
    devices: () => [realHIDDescriptor],
    devicesAsync: async () => [realHIDDescriptor],
  };
  class FakeCodexMicroService {
    constructor() {
      this.updates = [];
    }

    updateLighting(model) {
      this.updates.push(model);
      return Promise.resolve("updated");
    }
  }
  const fakeCodexMicroServiceModule = { CodexMicroService: FakeCodexMicroService };

  const originalLoad = Module._load;
  let loadingPreload = true;
  Module._load = function preloadTestLoad(request, parent, isMain) {
    if (request === "electron") {
      if (loadingPreload && !electronAvailableDuringPreload) {
        const error = new Error("Cannot find module 'electron'");
        error.code = "MODULE_NOT_FOUND";
        throw error;
      }
      return fakeElectron;
    }
    if (
      typeof request === "string" &&
      /hid[-_]topology[-_]watcher\.node$/.test(request)
    ) return fakeTopology;
    if (
      typeof request === "string" &&
      /(?:codex-micro-service|service)-[^\\/]+\.js$/.test(request)
    ) return fakeCodexMicroServiceModule;
    if (request === "node-hid") return fakeNodeHID;
    return Reflect.apply(originalLoad, this, [request, parent, isMain]);
  };

  const priorType = process.type;
  const priorElectron = process.versions.electron;
  const priorResourcesPath = Object.getOwnPropertyDescriptor(process, "resourcesPath");
  if (commandIDs) {
    const buildDirectory = path.join(runtime, "resources", "app.asar", ".vite", "build");
    fs.mkdirSync(buildDirectory, { recursive: true });
    const source = commandIDs
      .map((id) => `{id:\`${id}\`,titleIntlId:\`codex.command.${id}\`}`)
      .join("\n");
    fs.writeFileSync(path.join(buildDirectory, "commands.js"), source);
    Object.defineProperty(process, "resourcesPath", {
      configurable: true,
      value: path.join(runtime, "resources"),
    });
  }
  process.env.NOSTROMO_CODEX_SOCKET = socketPath;
  process.env.NOSTROMO_CODEX_TOKEN = token;
  if (reconnectable) process.env.NOSTROMO_CODEX_DISCOVERY = discoveryPath;
  process.env.NOSTROMO_CODEX_CHATGPT_VERSION = version;
  process.env.NOSTROMO_CODEX_CHATGPT_BUILD = build;
  process.env.NOSTROMO_CODEX_SERVICE_MODULE = `.vite/build/${service}`;
  process.env.NOSTROMO_CODEX_ADAPTER = "micro-v1";
  if (force) process.env.NOSTROMO_CODEX_FORCE = "1";
  process.type = "browser";
  Object.defineProperty(process.versions, "electron", {
    configurable: true,
    value: "39.0.0",
  });
  process.env.NODE_OPTIONS = `--trace-warnings --require=${preloadPath}`;

  try {
    require(preloadPath);
  } finally {
    loadingPreload = false;
  }
  Module._load(`./${service}`, MAIN_PARENT, false);

  assert.equal(process.env.NOSTROMO_CODEX_SOCKET, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_TOKEN, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_DISCOVERY, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_FORCE, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_CHATGPT_VERSION, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_CHATGPT_BUILD, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_SERVICE_MODULE, undefined);
  assert.equal(process.env.NOSTROMO_CODEX_ADAPTER, undefined);
  assert.equal(process.env.NODE_OPTIONS, "--trace-warnings");

  return {
    fakeNodeHID,
    fakeTopology,
    evaluatedScripts,
    inputEvents,
    realHIDDescriptor,
    realOpenCalls,
    realTopologyDescriptor,
    projectDOM,
    get socketPath() {
      return socketPath;
    },
    submitDOM,
    get token() {
      return token;
    },
    viewMessages,
    windowState,
    publishDescriptor(advertisedToken = token, mode = 0o600) {
      assert.ok(reconnectable);
      publishReconnectDescriptor(discoveryPath, session, advertisedToken, mode);
    },
    async replaceBridge({
      advertisedToken,
      publishDescriptor: shouldPublishDescriptor = true,
      token: nextToken,
      onConnection,
    }) {
      assert.ok(reconnectable);
      for (const socket of sockets) socket.destroy();
      if (server.listening) await closeServer(server);
      fs.rmSync(session.directory, { recursive: true, force: true });

      sessionSequence += 1;
      session = createReconnectableSession(runtime, sessionSequence);
      socketPath = session.socketPath;
      token = nextToken;
      activeOnConnection = onConnection;
      server = makeServer();
      await listen(server, socketPath);
      fs.chmodSync(socketPath, 0o600);
      if (shouldPublishDescriptor) {
        publishReconnectDescriptor(
          discoveryPath,
          session,
          advertisedToken ?? token,
        );
      }
      return { socketPath, token };
    },
    async close() {
      Module._load = originalLoad;
      process.type = priorType;
      if (priorElectron === undefined) {
        delete process.versions.electron;
      } else {
        Object.defineProperty(process.versions, "electron", {
          configurable: true,
          value: priorElectron,
        });
      }
      if (priorResourcesPath) {
        Object.defineProperty(process, "resourcesPath", priorResourcesPath);
      } else {
        delete process.resourcesPath;
      }
      delete process.env.NODE_OPTIONS;
      delete process.env.NOSTROMO_CODEX_DISCOVERY;
      for (const socket of sockets) socket.destroy();
      if (server.listening) await closeServer(server);
      fs.rmSync(runtime, { recursive: true, force: true });
    },
  };
}

function createReconnectableSession(runtimeRoot, sequence) {
  const suffix = String(sequence).padStart(12, "0");
  const runtimeID = `00000000-0000-4000-8000-${suffix}`.toUpperCase();
  const directory = path.join(
    runtimeRoot,
    `nostromo-codex-runtime-${runtimeID}`,
  );
  fs.mkdirSync(directory, { mode: 0o700 });
  const markerPath = path.join(directory, ".owner");
  fs.writeFileSync(markerPath, JSON.stringify({
    version: 1,
    pid: process.pid,
    runtimeID,
  }), { mode: 0o600 });
  return {
    directory,
    runtimeID,
    socketPath: path.join(directory, "project2077.sock"),
  };
}

function publishReconnectDescriptor(discoveryPath, session, token, mode = 0o600) {
  const temporaryPath = `${discoveryPath}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPath, JSON.stringify({
    version: 1,
    pid: process.pid,
    runtimeID: session.runtimeID,
    socketPath: session.socketPath,
    token,
  }), { mode });
  fs.renameSync(temporaryPath, discoveryPath);
  fs.chmodSync(discoveryPath, mode);
}

function createProjectDOMHarness(initial = {}) {
  let buttonCount = 1;
  let clickCount = 0;

  function configure(next = {}) {
    buttonCount = next.buttonCount ?? 1;
    clickCount = 0;
  }

  configure(initial);

  return {
    configure,
    get clickCount() {
      return clickCount;
    },
    evaluate(script) {
      assert.match(
        script,
        /button\[data-clear-project-button\]:not\(:disabled\)/,
      );
      if (buttonCount === 0) return { ok: false, reason: "missing" };
      if (buttonCount > 1) return { ok: false, reason: "ambiguous" };
      clickCount += 1;
      return { ok: true };
    },
  };
}

function createSubmitDOMHarness(initial = {}) {
  const stopIconPath =
    "M4.5 5.75C4.5 5.05964 5.05964 4.5 5.75 4.5H14.25C14.9404 4.5 15.5 5.05964 15.5 5.75V14.25C15.5 14.9404 14.9404 15.5 14.25 15.5H5.75C5.05964 15.5 4.5 14.9404 4.5 14.25V5.75Z";
  let document;
  let clickCount = 0;

  const element = ({
    attributes = {},
    disabled = false,
    hidden = false,
    inert = false,
    form = null,
    root = null,
    textContent = "",
  } = {}) => ({
    attributes: { ...attributes },
    disabled,
    hidden,
    inert,
    isConnected: true,
    form,
    root,
    textContent,
    click() {
      clickCount += 1;
    },
    closest(selector) {
      if (selector === "[inert]") {
        if (this.inert) return this;
        if (this.form && this.form !== this && this.form.inert) return this.form;
        if (this.root && this.root !== this && this.root.inert) return this.root;
        return null;
      }
      if (selector === "form") return this.form;
      if (selector === "[data-codex-composer-root]") return this.root;
      return null;
    },
    getAttribute(name) {
      return this.attributes[name] ?? null;
    },
    getBoundingClientRect() {
      return { width: 100, height: 40 };
    },
    querySelectorAll() {
      return [];
    },
  });

  const configure = ({
    buttonCount = 1,
    disabled = false,
    focused = true,
    formCount = 1,
    mode = "chat",
    rootBlocked = false,
    stopButtonCount = 0,
    stopDisabled = false,
  } = {}) => {
    clickCount = 0;
    if (mode === "none") {
      document = { activeElement: null, querySelectorAll: () => [] };
      return;
    }

    const forms = Array.from({ length: formCount }, () => {
      const form = element({
        attributes: rootBlocked ? { "aria-disabled": "true" } : {},
        inert: rootBlocked,
      });
      form.form = form;
      const submitButtons = Array.from({ length: buttonCount }, () =>
        element({
          disabled,
          attributes: {
            ...(disabled ? { "aria-disabled": "true" } : {}),
            type: mode === "chat" ? "submit" : "button",
          },
          form,
        })
      );
      const stopButtons = Array.from({ length: stopButtonCount }, () => {
        const button = element({
          disabled: stopDisabled,
          attributes: {
            ...(stopDisabled ? { "aria-disabled": "true" } : {}),
            type: "button",
          },
          form,
        });
        const path = element({ attributes: { d: stopIconPath } });
        button.querySelectorAll = (selector) => selector === "path" ? [path] : [];
        return button;
      });
      form.querySelectorAll = (selector) => {
        if (
          selector === 'button.size-token-button-composer[type="submit"]' &&
          mode === "chat"
        ) return submitButtons;
        if (selector === 'button.size-token-button-composer[type="button"]') {
          return [
            ...(mode === "chat" ? [] : submitButtons),
            ...stopButtons,
          ];
        }
        return [];
      };
      return { form, stopButtons, submitButtons };
    });
    const activeElement = focused && forms[0] != null
      ? element({ form: forms[0].form })
      : null;
    document = {
      activeElement,
      querySelectorAll: (selector) => {
        if (
          selector === 'button.size-token-button-composer[type="submit"]' &&
          mode === "chat"
        ) return forms.flatMap(({ submitButtons }) => submitButtons);
        if (selector === 'button.size-token-button-composer[type="button"]') {
          return forms.flatMap(({ stopButtons, submitButtons }) => [
            ...(mode === "chat" ? [] : submitButtons),
            ...stopButtons,
          ]);
        }
        return [];
      },
    };
  };

  configure(initial);
  return {
    configure,
    evaluate(script) {
      return vm.runInNewContext(script, {
        document,
        getComputedStyle: () => ({ display: "block", visibility: "visible" }),
      });
    },
    get clickCount() {
      return clickCount;
    },
  };
}

class JsonLinePeer {
  constructor(socket) {
    this.socket = socket;
    this.buffer = "";
    this.messages = [];
    this.waiters = [];
    this.ended = false;
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => this.receive(chunk));
    socket.on("end", () => {
      this.ended = true;
    });
  }

  receive(chunk) {
    this.buffer += chunk;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      const waiterIndex = this.waiters.findIndex(({ predicate }) => predicate(message));
      if (waiterIndex >= 0) {
        const [{ resolve, timer }] = this.waiters.splice(waiterIndex, 1);
        clearTimeout(timer);
        resolve(message);
      } else {
        this.messages.push(message);
      }
    }
  }

  next(predicate, timeoutMilliseconds = 2_000) {
    const existingIndex = this.messages.findIndex(predicate);
    if (existingIndex >= 0) {
      return Promise.resolve(this.messages.splice(existingIndex, 1)[0]);
    }
    return new Promise((resolve, reject) => {
      const waiter = {
        predicate,
        resolve,
        timer: setTimeout(() => {
          const index = this.waiters.indexOf(waiter);
          if (index >= 0) this.waiters.splice(index, 1);
          reject(new Error("Timed out waiting for bridge JSON message"));
        }, timeoutMilliseconds),
      };
      this.waiters.push(waiter);
    });
  }

  send(message) {
    this.socket.write(`${JSON.stringify(message)}\n`);
  }
}

function assertSyntheticCatalog(devices, realDescriptor) {
  assert.equal(devices.length, 2);
  assert.strictEqual(devices[0], realDescriptor);
  assert.deepEqual(devices[1], {
    path: SYNTHETIC_PATH,
    vendorId: 0x303a,
    productId: 0x8360,
    manufacturer: "Work Louder",
    product: "Codex Micro",
    usagePage: 0xff00,
    usage: 1,
    release: 0x0100,
    transport: "usb",
  });
}

function listen(server, socketPath) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
}

function closeServer(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
}

function waitUntil(predicate, timeoutMilliseconds = 2_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  return new Promise((resolve, reject) => {
    function poll() {
      if (predicate()) {
        resolve();
        return;
      }
      if (Date.now() >= deadline) {
        reject(new Error("Timed out waiting for test condition"));
        return;
      }
      setImmediate(poll);
    }
    poll();
  });
}

function onceEvent(emitter, event) {
  return new Promise((resolve) => emitter.once(event, resolve));
}

function immediate() {
  return new Promise((resolve) => setImmediate(resolve));
}
