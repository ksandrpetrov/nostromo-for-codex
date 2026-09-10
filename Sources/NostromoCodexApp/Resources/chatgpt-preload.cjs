"use strict";

/*
 * Nostromo Codex compatibility preload.
 *
 * Project2077 framing and the scoped node-hid proxy are adapted from codex-midi
 * (MIT, Copyright 2026 Scott Fowler). This file is intentionally dependency-free
 * because it runs inside ChatGPT's Electron main process. It never edits app.asar
 * or changes ChatGPT.app's signature.
 */

const { EventEmitter } = require("node:events");
const fs = require("node:fs");
const Module = require("node:module");
const net = require("node:net");
const path = require("node:path");
const { isMainThread } = require("node:worker_threads");

const PROTOCOL_VERSION = 2;
const REPORT_LENGTH = 64;
const MAX_BUFFER = 1024 * 1024;
const OPEN_TIMEOUT_MS = 2000;
const RECONNECT_DELAYS_MS = Object.freeze([100, 250, 500, 1000, 2000]);
const VIEW_MESSAGE_CHANNEL = "codex_desktop:message-for-view";
const SYNTHETIC_PATH = "nostromo-codex://project2077";
const COMPATIBILITY = (() => {
  try {
    const file = path.join(__dirname, "codex-compatibility.json");
    if (fs.statSync(file).size > 65536) return { schemaVersion: 0, builds: [] };
    const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!Array.isArray(manifest.builds)) return { schemaVersion: 0, builds: [] };
    return manifest;
  } catch { return { schemaVersion: 0, builds: [] }; }
})();
const DISCOVERY_PATH = process.env.NOSTROMO_CODEX_DISCOVERY;
const SOCKET_PATH = process.env.NOSTROMO_CODEX_SOCKET;
const TOKEN = process.env.NOSTROMO_CODEX_TOKEN;
const FORCE = process.env.NOSTROMO_CODEX_FORCE === "1";
const CHATGPT_VERSION = process.env.NOSTROMO_CODEX_CHATGPT_VERSION;
const CHATGPT_BUILD = process.env.NOSTROMO_CODEX_CHATGPT_BUILD;
const SERVICE_MODULE = process.env.NOSTROMO_CODEX_SERVICE_MODULE;
const ADAPTER_ID = process.env.NOSTROMO_CODEX_ADAPTER;
const hookState = { hid: false, topology: false, service: false };
const TASK_STATUSES = new Set([
  "off",
  "working",
  "unread",
  "idle",
  "awaiting-approval",
  "awaiting-response",
  "error",
]);
const APP_ACTIONS = Object.freeze({
  clearComposerProject: "clear-composer-project",
  focusChatGPT: "focus-chatgpt",
  insertComposerText: "insert-composer-text",
  insertSkillMention: "insert-skill-mention",
  navigateRoute: "navigate-route",
  preparePluginPrompt: "prepare-plugin-prompt",
  pushToTalkStart: "push-to-talk-start",
  pushToTalkStop: "push-to-talk-stop",
  queryRuntimeState: "query-runtime-state",
  runCommand: "run-command",
  scrollTask: "scroll-task",
  stopActive: "stop-active",
  submitActiveComposer: "submit-active-composer",
  toggleChatWorkMode: "toggle-chat-work-mode",
  toggleChatGPT: "toggle-chatgpt",
});
const APP_ACTION_CONTRACT = Object.freeze([
  { name: APP_ACTIONS.clearComposerProject, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.focusChatGPT, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.insertComposerText, requiredPayloadKeys: ["text"] },
  {
    name: APP_ACTIONS.insertSkillMention,
    requiredPayloadKeys: ["displayName", "name", "path"],
  },
  { name: APP_ACTIONS.navigateRoute, requiredPayloadKeys: ["path"] },
  { name: APP_ACTIONS.preparePluginPrompt, requiredPayloadKeys: ["text"] },
  { name: APP_ACTIONS.pushToTalkStart, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.pushToTalkStop, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.queryRuntimeState, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.runCommand, requiredPayloadKeys: ["commandId"] },
  { name: APP_ACTIONS.scrollTask, requiredPayloadKeys: ["deltaY"] },
  { name: APP_ACTIONS.stopActive, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.submitActiveComposer, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.toggleChatWorkMode, requiredPayloadKeys: [] },
  { name: APP_ACTIONS.toggleChatGPT, requiredPayloadKeys: ["minimizeIfVisible"] },
]);
const virtualDevices = new Set();
let latestTaskSlotsMessage = null;

const DESCRIPTOR = Object.freeze({
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

const SAFE_COMMAND_CANDIDATES = new Set([
  "approval.approve",
  "approval.decline",
  "archiveThread",
  "composer.addFiles",
  "composer.addPhotos",
  "composer.cycleReasoningEffort",
  "composer.decreaseReasoningEffort",
  "composer.increaseReasoningEffort",
  "composer.openModelPicker",
  "composer.submit",
  "composer.toggleFastMode",
  "composer.togglePlanMode",
  "composer.toggleWorktreeMode",
  "copyConversationMarkdown",
  "environmentAction1",
  "feedback",
  "forkThread",
  "git.commit",
  "git.createBranch",
  "git.createDraftPullRequest",
  "git.createPullRequest",
  "manageTasks",
  "mcpSettings",
  "newTask",
  "nextThread",
  "openBrowserTab",
  "openFolder",
  "openSideChat",
  "openSkills",
  "previousThread",
  "settings",
  "toggleReviewTab",
  "toggleSidebar",
  "toggleTerminal",
  "toggleThreadPin",
]);
const DISCOVERED_COMMANDS = discoverCommandIDs();
const ALLOWED_COMMANDS = new Set(
  [...SAFE_COMMAND_CANDIDATES].filter((id) => DISCOVERED_COMMANDS.commandIds.has(id))
);

stripManagedEnvironment();

function log(message) {
  if (process.env.NOSTROMO_CODEX_VERBOSE === "1") {
    process.stderr.write(`[nostromo-codex] ${message}\n`);
  }
}

function bridgeAvailable() {
  try {
    const endpoint = bridgeEndpoint();
    return fs.lstatSync(endpoint.socketPath).isSocket();
  } catch {
    return false;
  }
}

function bridgeEndpoint() {
  if (DISCOVERY_PATH) return discoveredBridgeEndpoint();
  if (!SOCKET_PATH || !TOKEN) {
    throw new Error("Мост Nostromo Codex не настроен");
  }
  return { socketPath: SOCKET_PATH, token: TOKEN };
}

function discoveredBridgeEndpoint() {
  if (!path.isAbsolute(DISCOVERY_PATH)) {
    throw new Error("Путь обнаружения Nostromo Codex должен быть абсолютным");
  }
  if (typeof process.geteuid !== "function") {
    throw new Error("Не удалось проверить владельца сеанса Nostromo Codex");
  }
  const owner = process.geteuid();
  const descriptorPath = path.normalize(DISCOVERY_PATH);
  const discoveryDirectory = path.dirname(descriptorPath);
  const runtimeRoot = path.dirname(discoveryDirectory);
  const expectedDiscoveryDirectory = path.join(
    runtimeRoot,
    `nostromo-codex-discovery-${owner}`,
  );
  if (
    discoveryDirectory !== expectedDiscoveryDirectory ||
    path.basename(descriptorPath) !== "session.json"
  ) {
    throw new Error("Путь обнаружения Nostromo Codex не соответствует защищённому формату");
  }
  assertPrivatePath(discoveryDirectory, "directory", 0o700, owner);
  const descriptor = readPrivateJSON(descriptorPath, owner);
  if (
    descriptor.version !== 1 ||
    !Number.isSafeInteger(descriptor.pid) ||
    descriptor.pid < 1 ||
    typeof descriptor.runtimeID !== "string" ||
    !/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(
      descriptor.runtimeID,
    ) ||
    typeof descriptor.socketPath !== "string" ||
    !/^[0-9a-f]{64}$/.test(descriptor.token)
  ) {
    throw new Error("Дескриптор сеанса Nostromo Codex некорректен");
  }

  const runtimeDirectory = path.join(
    runtimeRoot,
    `nostromo-codex-runtime-${descriptor.runtimeID}`,
  );
  const expectedSocketPath = path.join(runtimeDirectory, "project2077.sock");
  if (path.normalize(descriptor.socketPath) !== expectedSocketPath) {
    throw new Error("Сокет сеанса Nostromo Codex находится вне защищённого каталога");
  }
  assertPrivatePath(runtimeDirectory, "directory", 0o700, owner);
  const marker = readPrivateJSON(path.join(runtimeDirectory, ".owner"), owner);
  if (
    marker.version !== 1 ||
    marker.pid !== descriptor.pid ||
    marker.runtimeID !== descriptor.runtimeID
  ) {
    throw new Error("Владелец сеанса Nostromo Codex не подтверждён");
  }
  assertPrivatePath(expectedSocketPath, "socket", 0o600, owner);
  return {
    socketPath: expectedSocketPath,
    token: descriptor.token,
  };
}

function readPrivateJSON(filePath, owner) {
  const noFollow = fs.constants.O_NOFOLLOW || 0;
  const closeOnExec = fs.constants.O_CLOEXEC || 0;
  const descriptor = fs.openSync(
    filePath,
    fs.constants.O_RDONLY | noFollow | closeOnExec,
  );
  try {
    const status = fs.fstatSync(descriptor);
    if (
      !status.isFile() ||
      status.uid !== owner ||
      (status.mode & 0o777) !== 0o600 ||
      status.nlink !== 1 ||
      status.size < 1 ||
      status.size > 4096
    ) {
      throw new Error("Защищённый файл Nostromo Codex имеет неверные атрибуты");
    }
    return JSON.parse(fs.readFileSync(descriptor, "utf8"));
  } finally {
    fs.closeSync(descriptor);
  }
}

function assertPrivatePath(filePath, kind, mode, owner) {
  const status = fs.lstatSync(filePath);
  const kindMatches = kind === "directory"
    ? status.isDirectory()
    : status.isSocket();
  if (
    !kindMatches ||
    status.isSymbolicLink() ||
    status.uid !== owner ||
    (status.mode & 0o777) !== mode
  ) {
    throw new Error(`Защищённый ${kind} Nostromo Codex имеет неверные атрибуты`);
  }
}

function openBridgeConnection() {
  return new Promise((resolve, reject) => {
    let endpoint;
    try {
      endpoint = bridgeEndpoint();
    } catch (error) {
      reject(error);
      return;
    }

    const socket = net.createConnection(endpoint.socketPath);
    socket.setNoDelay(true);
    socket.setEncoding("utf8");
    let buffer = "";
    let settled = false;
    const timeout = setTimeout(
      () => fail(new Error("Истекло время ожидания моста Nostromo Codex")),
      OPEN_TIMEOUT_MS,
    );

    const cleanup = () => {
      clearTimeout(timeout);
      socket.removeListener("data", onData);
      socket.removeListener("error", fail);
      socket.removeListener("close", onClose);
    };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      socket.destroy();
      reject(error instanceof Error ? error : new Error(String(error)));
    };
    const onClose = () =>
      fail(new Error("Мост Nostromo Codex закрылся во время согласования"));
    const onData = (chunk) => {
      buffer += chunk;
      if (buffer.length > MAX_BUFFER) {
        fail(new Error("Данные согласования Nostromo Codex превысили 1 МиБ"));
        return;
      }
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          fail(new Error("Nostromo Codex вернул некорректный JSON согласования"));
          return;
        }
        if (
          message.v !== PROTOCOL_VERSION ||
          message.type !== "hello-ack" ||
          message.token !== endpoint.token
        ) {
          fail(new Error(message.message || "Ошибка аутентификации Nostromo Codex"));
          return;
        }
        settled = true;
        cleanup();
        resolve({ buffer, socket });
        return;
      }
    };

    socket.on("data", onData);
    socket.once("error", fail);
    socket.once("close", onClose);
    socket.once("connect", () => {
      socket.write(`${JSON.stringify({
        v: PROTOCOL_VERSION,
        type: "hello",
        role: "node-hid-shim",
        path: SYNTHETIC_PATH,
        token: endpoint.token,
      })}\n`);
    });
  });
}

function assertCompatible() {
  // NODE_OPTIONS preloads run before Electron's built-in modules are always
  // available through CommonJS. The native launcher already inspected the
  // signed app bundle, so pass that verified version into the child instead
  // of requiring "electron" during Node bootstrap.
  if (!CHATGPT_VERSION) {
    throw new Error("Версия ChatGPT не передана нативным лаунчером");
  }
  if (COMPATIBILITY.schemaVersion !== 1 || !CHATGPT_BUILD ||
      !/^\.vite\/build\/[A-Za-z0-9_-]+\.js$/.test(SERVICE_MODULE || "") || ADAPTER_ID !== "micro-v1") {
    throw new Error("Не передан проверенный контракт адаптера ChatGPT");
  }
  const entry = COMPATIBILITY.builds.find((item) => item.version === CHATGPT_VERSION && item.build === CHATGPT_BUILD);
  if (!(entry?.verified && entry.adapter === ADAPTER_ID) && !FORCE) {
    throw new Error(`Неподдерживаемая версия ChatGPT: ${CHATGPT_VERSION}`);
  }
}

class VirtualHIDAsyncDevice extends EventEmitter {
  constructor(socket, initialBuffer = "") {
    super();
    this.socket = null;
    this.buffer = "";
    this.closed = false;
    this.closeEmitted = false;
    this.connectionGeneration = 0;
    this.connectionWaiters = new Set();
    this.reconnectAttempt = 0;
    this.reconnectInFlight = false;
    this.reconnectTimer = null;
    this.pushToTalkActive = false;
    this.taskSlotsDigest = null;
    this.capabilityDigest = null;
    this.capabilityTimer = setInterval(() => this.publishCapabilities(), 2000);
    this.capabilityTimer.unref();
    this.actionQueue = Promise.resolve();
    virtualDevices.add(this);
    this.attachSocket(socket, initialBuffer);
  }

  static async open() {
    const connection = await openBridgeConnection();
    return new VirtualHIDAsyncDevice(connection.socket, connection.buffer);
  }

  publishCapabilities() {
    const socket = this.socket;
    const generation = this.connectionGeneration;
    if (!socket || !this.isConnectionActive(socket, generation)) return;
    try {
      const manifest = runtimeCapabilityManifest();
      const digest = JSON.stringify(manifest);
      if (digest === this.capabilityDigest) return;
      this.capabilityDigest = digest;
      this.writeLine(manifest, generation).catch((error) => {
        if (!this.isConnectionActive(socket, generation)) return;
        this.capabilityDigest = null;
        this.emitAsyncError(error);
      });
    } catch (error) { this.emitAsyncError(error); }
  }

  attachSocket(socket, initialBuffer = "") {
    if (this.closed) {
      socket.destroy();
      return;
    }
    this.connectionGeneration += 1;
    const generation = this.connectionGeneration;
    this.socket = socket;
    this.buffer = "";
    this.reconnectAttempt = 0;
    this.taskSlotsDigest = null;
    this.capabilityDigest = null;
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => this.receive(chunk, generation));
    socket.on("error", (error) => {
      if (DISCOVERY_PATH && !this.closed) {
        log(`Соединение Nostromo Codex прервано: ${error.message}`);
      } else {
        this.emitAsyncError(error);
      }
    });
    socket.on("close", () => this.handleSocketClose(socket, generation));
    for (const waiter of this.connectionWaiters) waiter.resolve(socket);
    this.connectionWaiters.clear();
    if (initialBuffer) this.receive(initialBuffer, generation);
    this.publishCapabilities();
    this.publishRuntimeState();
    this.publishTaskSlots(latestTaskSlotsMessage);
  }

  async write(dataLike) {
    const report = Buffer.from(dataLike);
    if (report.length !== REPORT_LENGTH) {
      throw new RangeError(`Запись Project2077 должна содержать ${REPORT_LENGTH} байт`);
    }
    const message = {
      v: PROTOCOL_VERSION,
      type: "host-report",
      data: report.toString("base64"),
    };
    for (;;) {
      const socket = await this.waitForSocket();
      try {
        await this.writeLineToSocket(message, socket);
        return report.length;
      } catch (error) {
        if (!DISCOVERY_PATH || this.closed) throw error;
        if (socket === this.socket) socket.destroy();
      }
    }
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.capabilityTimer);
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.rejectConnectionWaiters(new Error("Project2077 закрыт"));
    const socket = this.socket;
    if (!socket || socket.destroyed) {
      this.finishClose();
      return;
    }
    await new Promise((resolve) => {
      socket.once("close", resolve);
      socket.end();
    });
  }

  handleSocketClose(socket, generation) {
    if (
      this.socket !== socket ||
      this.connectionGeneration !== generation
    ) return;
    this.socket = null;
    this.buffer = "";
    this.connectionGeneration += 1;
    this.stopPushToTalkFailSafe();
    if (this.closed) {
      this.finishClose();
      return;
    }
    if (DISCOVERY_PATH) {
      this.scheduleReconnect();
      return;
    }
    this.closed = true;
    this.rejectConnectionWaiters(new Error("Project2077 закрыт"));
    this.finishClose();
  }

  scheduleReconnect() {
    if (this.closed || this.reconnectInFlight || this.reconnectTimer) return;
    const delay = RECONNECT_DELAYS_MS[
      Math.min(this.reconnectAttempt, RECONNECT_DELAYS_MS.length - 1)
    ];
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.reconnect().catch((error) => {
        log(`Не удалось переподключить Nostromo Codex: ${error.message}`);
      });
    }, delay);
    if (typeof this.reconnectTimer.unref === "function") this.reconnectTimer.unref();
  }

  async reconnect() {
    if (this.closed || this.reconnectInFlight) return;
    this.reconnectInFlight = true;
    try {
      const connection = await openBridgeConnection();
      if (this.closed) {
        connection.socket.destroy();
        return;
      }
      this.attachSocket(connection.socket, connection.buffer);
    } catch (error) {
      this.reconnectAttempt += 1;
      log(`Ожидание нового сеанса Nostromo Codex: ${error.message}`);
    } finally {
      this.reconnectInFlight = false;
    }
    if (!this.closed && !this.socket) this.scheduleReconnect();
  }

  waitForSocket() {
    if (this.closed) return Promise.reject(new Error("Project2077 закрыт"));
    if (this.socket && !this.socket.destroyed) return Promise.resolve(this.socket);
    if (!DISCOVERY_PATH) return Promise.reject(new Error("Project2077 закрыт"));
    return new Promise((resolve, reject) => {
      this.connectionWaiters.add({ resolve, reject });
    });
  }

  rejectConnectionWaiters(error) {
    for (const waiter of this.connectionWaiters) waiter.reject(error);
    this.connectionWaiters.clear();
  }

  finishClose() {
    if (this.closeEmitted) return;
    clearInterval(this.capabilityTimer);
    this.closeEmitted = true;
    virtualDevices.delete(this);
    this.stopPushToTalkFailSafe();
    this.emit("close");
  }

  isConnectionActive(socket, generation) {
    return !this.closed &&
      this.socket === socket &&
      !socket.destroyed &&
      this.connectionGeneration === generation;
  }

  receive(chunk, generation = this.connectionGeneration) {
    if (this.closed || generation !== this.connectionGeneration) return;
    this.buffer += chunk;
    if (this.buffer.length > MAX_BUFFER) {
      this.emitAsyncError(new Error("Буфер моста Nostromo Codex превысил 1 МиБ"));
      this.socket.destroy();
      return;
    }
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.emitAsyncError(new Error("Nostromo Codex отправил некорректный JSON"));
        continue;
      }
      if (message.v !== PROTOCOL_VERSION) {
        this.emitAsyncError(new Error(`Неподдерживаемая версия протокола Nostromo: ${message.v}`));
        continue;
      }
      if (message.type === "device-report") {
        const report = Buffer.from(message.data || "", "base64");
        if (report.length === REPORT_LENGTH && report.toString("base64") === message.data) {
          this.emit("data", report);
        }
        continue;
      }
      if (message.type === "app-action") {
        const actionGeneration = generation;
        this.actionQueue = this.actionQueue
          .then(() => this.handleAction(message, actionGeneration))
          .catch((error) => {
            this.emitAsyncError(error instanceof Error ? error : new Error(String(error)));
          });
        continue;
      }
      if (message.type === "error") {
        this.emitAsyncError(new Error(message.message || "Ошибка моста Nostromo Codex"));
      }
    }
  }

  async handleAction(message, generation) {
    if (!Number.isSafeInteger(message.id) || message.id < 1) return;
    if (
      this.closed ||
      generation !== this.connectionGeneration ||
      !this.socket ||
      this.socket.destroyed
    ) return;
    try {
      const result = await executeAppAction(message.action, message.payload || {});
      if (
        this.closed ||
        generation !== this.connectionGeneration ||
        !this.socket ||
        this.socket.destroyed
      ) return;
      if (result && Object.hasOwn(result, "reasoningEffort")) {
        await this.writeLine({
          v: PROTOCOL_VERSION,
          type: "runtime-state",
          reasoningEffort: result.reasoningEffort,
        }, generation);
      } else if (
        message.action === APP_ACTIONS.runCommand &&
        String(message.payload?.commandId || "").toLowerCase().includes("reasoning")
      ) {
        setTimeout(() => this.publishRuntimeState(), 150);
      }
      if (message.action === APP_ACTIONS.pushToTalkStart) this.pushToTalkActive = true;
      if (message.action === APP_ACTIONS.pushToTalkStop) this.pushToTalkActive = false;
      await this.writeLine({
        v: PROTOCOL_VERSION,
        type: "app-action-result",
        id: message.id,
        ok: true,
      }, generation);
    } catch (error) {
      if (
        this.closed ||
        generation !== this.connectionGeneration ||
        !this.socket ||
        this.socket.destroyed
      ) return;
      await this.writeLine({
        v: PROTOCOL_VERSION,
        type: "app-action-result",
        id: message.id,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      }, generation);
    }
  }

  async publishRuntimeState() {
    try {
      const state = await readRuntimeState();
      await this.writeLine({
        v: PROTOCOL_VERSION,
        type: "runtime-state",
        reasoningEffort: state.reasoningEffort,
      });
    } catch (error) {
      log(`Состояние среды выполнения недоступно: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  publishTaskSlots(message) {
    if (!message || this.closed || !this.socket || this.socket.destroyed) return;
    const digest = JSON.stringify(message.slots);
    if (digest === this.taskSlotsDigest) return;
    this.taskSlotsDigest = digest;
    this.writeLine(message).catch((error) => {
      this.taskSlotsDigest = null;
      this.emitAsyncError(error instanceof Error ? error : new Error(String(error)));
    });
  }

  writeLine(message, generation = this.connectionGeneration) {
    const socket = this.socket;
    if (
      this.closed ||
      !socket ||
      socket.destroyed ||
      generation !== this.connectionGeneration
    ) {
      return Promise.reject(new Error("Мост Nostromo Codex закрыт"));
    }
    return this.writeLineToSocket(message, socket);
  }

  writeLineToSocket(message, socket) {
    return new Promise((resolve, reject) => {
      if (this.closed || !socket || socket.destroyed) {
        reject(new Error("Мост Nostromo Codex закрыт"));
        return;
      }
      socket.write(
        `${JSON.stringify(message)}\n`,
        (error) => error ? reject(error) : resolve(),
      );
    });
  }

  stopPushToTalkFailSafe() {
    if (!this.pushToTalkActive) return;
    this.pushToTalkActive = false;
    try {
      sendViewMessage({ type: "codex-micro-push-to-talk-stop" });
    } catch (error) {
      this.emitAsyncError(error instanceof Error ? error : new Error(String(error)));
    }
  }

  emitAsyncError(error) {
    setImmediate(() => {
      if (this.listenerCount("error") > 0) this.emit("error", error);
      else log(error.message);
    });
  }
}

function createNodeHidProxy(realNodeHid) {
  if (!realNodeHid || !realNodeHid.HIDAsync || typeof realNodeHid.HIDAsync.open !== "function") {
    throw new TypeError("API node-hid в ChatGPT несовместим");
  }
  const RealHIDAsync = realNodeHid.HIDAsync;
  const HIDAsyncProxy = new Proxy(RealHIDAsync, {
    get(target, property, receiver) {
      if (property === "open") {
        return async (path, ...args) => {
          if (path === SYNTHETIC_PATH) return VirtualHIDAsyncDevice.open();
          return Reflect.apply(target.open, target, [path, ...args]);
        };
      }
      return Reflect.get(target, property, receiver);
    },
  });

  return new Proxy(realNodeHid, {
    get(target, property, receiver) {
      if (property === "devices" || property === "devicesAsync") {
        return asyncOrSyncDeviceList(target, property, receiver);
      }
      if (property === "HIDAsync") return HIDAsyncProxy;
      return Reflect.get(target, property, receiver);
    },
  });
}

function asyncOrSyncDeviceList(target, property, receiver) {
  return (...args) => {
    const result = Reflect.apply(Reflect.get(target, property, receiver), target, args);
    if (result && typeof result.then === "function") {
      return result.then(appendSyntheticDescriptor);
    }
    return appendSyntheticDescriptor(result);
  };
}

function appendSyntheticDescriptor(devices) {
  if (!Array.isArray(devices) || !hookState.service || !bridgeAvailable()) return devices;
  if (devices.some((device) =>
    device &&
    device.vendorId === DESCRIPTOR.vendorId &&
    device.productId === DESCRIPTOR.productId &&
    device.usagePage === DESCRIPTOR.usagePage
  )) return devices;
  return [...devices, { ...DESCRIPTOR }];
}

function createTopologyProxy(realTopology) {
  if (!realTopology || typeof realTopology.findCodexMicroInterfaces !== "function") {
    throw new TypeError("API HID-топологии ChatGPT несовместим");
  }
  return new Proxy(realTopology, {
    get(target, property, receiver) {
      if (property === "findCodexMicroInterfaces") {
        return (...args) => {
          const result = Reflect.apply(target.findCodexMicroInterfaces, target, args);
          return result && typeof result.then === "function"
            ? result.then(appendSyntheticDescriptor)
            : appendSyntheticDescriptor(result);
        };
      }
      return Reflect.get(target, property, receiver);
    },
  });
}

function createCodexMicroServiceModuleProxy(realModule) {
  const RealService = realModule && realModule.CodexMicroService;
  if (typeof RealService !== "function") {
    throw new TypeError("Сервис Codex Micro в ChatGPT несовместим");
  }

  class NostromoCodexMicroService extends RealService {
    updateLighting(model) {
      publishTaskSlots(model);
      return super.updateLighting(model);
    }
  }

  return new Proxy(realModule, {
    get(target, property, receiver) {
      if (property === "CodexMicroService") return NostromoCodexMicroService;
      return Reflect.get(target, property, receiver);
    },
  });
}

function publishTaskSlots(model) {
  const message = taskSlotsMessage(model);
  if (!message) return;
  latestTaskSlotsMessage = message;
  for (const device of virtualDevices) device.publishTaskSlots(message);
}

function taskSlotsMessage(model) {
  if (!model || !Array.isArray(model.slots)) return null;
  const seen = new Set();
  const slots = [];
  for (const slot of model.slots) {
    if (
      !slot ||
      !Number.isSafeInteger(slot.id) ||
      slot.id < 0 ||
      slot.id > 5 ||
      seen.has(slot.id)
    ) continue;
    seen.add(slot.id);
    slots.push({
      id: slot.id,
      title: typeof slot.title === "string" ? slot.title.slice(0, 256) : null,
      status: TASK_STATUSES.has(slot.status) ? slot.status : "off",
      selected: slot.selected === true,
    });
  }
  slots.sort((left, right) => left.id - right.id);
  return { v: PROTOCOL_VERSION, type: "task-slots", slots };
}

async function executeAppAction(action, payload) {
  switch (action) {
    case APP_ACTIONS.runCommand: {
      const id = payload.commandId;
      if (!ALLOWED_COMMANDS.has(id)) throw new Error(`Команда отсутствует в списке разрешённых: ${String(id)}`);
      sendViewMessage({ type: "run-command", id });
      return;
    }
    case APP_ACTIONS.focusChatGPT:
      focusChatGPT();
      return;
    case APP_ACTIONS.toggleChatGPT:
      toggleChatGPT(payload.minimizeIfVisible === "true");
      return;
    case APP_ACTIONS.toggleChatWorkMode:
      await toggleChatWorkMode();
      return;
    case APP_ACTIONS.clearComposerProject:
      await clearComposerProject();
      return;
    case APP_ACTIONS.submitActiveComposer:
      await submitActiveComposer();
      return;
    case APP_ACTIONS.navigateRoute:
      if (typeof payload.path !== "string" || !payload.path.startsWith("/")) {
        throw new Error("Некорректный маршрут ChatGPT");
      }
      sendViewMessage({ type: "navigate-to-route", path: payload.path });
      return;
    case APP_ACTIONS.scrollTask:
      sendScroll(Number(payload.deltaY) || 0);
      return;
    case APP_ACTIONS.insertComposerText:
      focusChatGPT();
      sendViewMessage({ type: "codex-micro-insert-composer-text", text: String(payload.text || "") });
      return;
    case APP_ACTIONS.insertSkillMention:
      if (!payload.name || !payload.path) throw new Error("Необходимо указать название и путь навыка");
      focusChatGPT();
      sendViewMessage({
        type: "codex-micro-insert-skill-mention",
        skill: {
          name: payload.name,
          displayName: payload.displayName || payload.name,
          path: payload.path,
        },
      });
      return;
    case APP_ACTIONS.preparePluginPrompt:
      focusChatGPT();
      sendViewMessage({ type: "codex-micro-insert-composer-text", text: String(payload.text || "") });
      return;
    case APP_ACTIONS.pushToTalkStart:
      sendViewMessage({ type: "codex-micro-push-to-talk-start" });
      return;
    case APP_ACTIONS.pushToTalkStop:
      sendViewMessage({ type: "codex-micro-push-to-talk-stop" });
      return;
    case APP_ACTIONS.stopActive:
      await stopActiveComposer();
      return;
    case APP_ACTIONS.queryRuntimeState:
      return readRuntimeState();
    default:
      throw new Error(`Неподдерживаемое действие Nostromo: ${String(action)}`);
  }
}

async function submitActiveComposer() {
  const window = usableWindow();
  if (!window || typeof window.webContents.executeJavaScript !== "function") {
    throw new Error("Нет доступного окна ChatGPT для отправки сообщения");
  }
  const result = await window.webContents.executeJavaScript(`
    (() => {
      // NOSTROMO_ACTIVE_COMPOSER_SUBMIT
      const isVisible = (node) => {
        if (!node || !node.isConnected || node.hidden || node.getAttribute("aria-hidden") === "true") {
          return false;
        }
        if (typeof getComputedStyle === "function") {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden") return false;
        }
        if (typeof node.getBoundingClientRect === "function") {
          const rect = node.getBoundingClientRect();
          if (!rect || rect.width <= 0 || rect.height <= 0) return false;
        }
        return true;
      };
      const activeElement = document.activeElement;
      const focusedForm = typeof activeElement?.closest === "function"
        ? activeElement.closest("form")
        : null;
      const candidateScope = focusedForm != null && isVisible(focusedForm)
        ? focusedForm
        : document;
      const submitTargets = Array.from(
        candidateScope.querySelectorAll(
          'button.size-token-button-composer[type="submit"]'
        )
      ).filter(isVisible);
      if (submitTargets.length === 0) return { handled: false };
      if (submitTargets.length !== 1) {
        return { handled: true, ok: false, reason: "ambiguous-button" };
      }

      const button = submitTargets[0];
      const composer = button.closest("[data-codex-composer-root]")
        ?? button.closest("form");
      if (
        !composer ||
        composer.getAttribute("aria-disabled") === "true" ||
        composer.closest("[inert]")
      ) {
        return { handled: true, ok: false, reason: "composer-blocked" };
      }
      if (
        button.disabled ||
        button.getAttribute("aria-disabled") === "true" ||
        button.closest("[inert]")
      ) {
        return { handled: true, ok: false, reason: "disabled-button" };
      }
      button.click();
      return { handled: true, ok: true };
    })()
  `, true);

  if (result?.handled !== true) {
    if (!ALLOWED_COMMANDS.has("composer.submit")) {
      throw new Error("Команда composer.submit отсутствует в списке разрешённых");
    }
    sendViewMessage({ type: "run-command", id: "composer.submit" });
    return;
  }
  if (result?.ok === true) return;
  switch (result?.reason) {
    case "disabled-button":
      throw new Error("Кнопка отправки Chat сейчас недоступна");
    case "composer-blocked":
      throw new Error("Поле ввода Chat сейчас заблокировано");
    case "ambiguous-button":
      throw new Error("Найдено несколько кнопок отправки Chat; отправка отменена");
    default:
      throw new Error("Не удалось безопасно определить кнопку отправки Chat");
  }
}

async function stopActiveComposer() {
  const window = usableWindow();
  if (!window || typeof window.webContents.executeJavaScript !== "function") {
    throw new Error("Нет доступного окна ChatGPT для остановки ответа");
  }
  const result = await window.webContents.executeJavaScript(`
    (() => {
      // NOSTROMO_ACTIVE_COMPOSER_STOP
      const stopIconPath =
        "M4.5 5.75C4.5 5.05964 5.05964 4.5 5.75 4.5H14.25C14.9404 4.5 15.5 5.05964 15.5 5.75V14.25C15.5 14.9404 14.9404 15.5 14.25 15.5H5.75C5.05964 15.5 4.5 14.9404 4.5 14.25V5.75Z";
      const isVisible = (node) => {
        if (!node || !node.isConnected || node.hidden || node.getAttribute("aria-hidden") === "true") {
          return false;
        }
        if (typeof getComputedStyle === "function") {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden") return false;
        }
        if (typeof node.getBoundingClientRect === "function") {
          const rect = node.getBoundingClientRect();
          if (!rect || rect.width <= 0 || rect.height <= 0) return false;
        }
        return true;
      };
      const stopButtonsIn = (scope) => Array.from(
        scope.querySelectorAll('button.size-token-button-composer[type="button"]')
      ).filter(isVisible).filter((button) =>
        Array.from(button.querySelectorAll("path")).some(
          (path) => path.getAttribute("d") === stopIconPath
        )
      );

      const activeElement = document.activeElement;
      const focusedForm = typeof activeElement?.closest === "function"
        ? activeElement.closest("form")
        : null;
      const focusedTargets = focusedForm != null && isVisible(focusedForm)
        ? stopButtonsIn(focusedForm)
        : [];
      const stopTargets = focusedTargets.length > 0
        ? focusedTargets
        : stopButtonsIn(document);
      if (stopTargets.length === 0) return { handled: false };
      if (stopTargets.length !== 1) {
        return { handled: true, ok: false, reason: "ambiguous-button" };
      }

      const button = stopTargets[0];
      const composer = button.closest("[data-codex-composer-root]")
        ?? button.closest("form");
      if (
        composer &&
        (composer.getAttribute("aria-disabled") === "true" || composer.closest("[inert]"))
      ) {
        return { handled: true, ok: false, reason: "composer-blocked" };
      }
      if (
        button.disabled ||
        button.getAttribute("aria-disabled") === "true" ||
        button.closest("[inert]")
      ) {
        return { handled: true, ok: false, reason: "disabled-button" };
      }
      button.click();
      return { handled: true, ok: true };
    })()
  `, true);

  if (result?.handled !== true) {
    sendKey("Escape");
    return;
  }
  if (result?.ok === true) return;
  switch (result?.reason) {
    case "disabled-button":
      throw new Error("Кнопка остановки сейчас недоступна");
    case "composer-blocked":
      throw new Error("Активный композитор сейчас заблокирован");
    case "ambiguous-button":
      throw new Error("Найдено несколько кнопок остановки; действие отменено");
    default:
      throw new Error("Не удалось безопасно определить кнопку остановки");
  }
}

async function toggleChatWorkMode() {
  const window = usableWindow();
  if (!window || typeof window.webContents.executeJavaScript !== "function") {
    throw new Error("Нет доступного окна ChatGPT для переключения Chat / Work");
  }
  const result = await window.webContents.executeJavaScript(`
    (() => {
      // NOSTROMO_CHAT_WORK_MODE_TOGGLE
      const normalize = (value) => String(value || "").trim().replace(/\\s+/g, " ").toLowerCase();
      const groups = Array.from(document.querySelectorAll('[role="group"]'));
      const group = groups.find((candidate) => {
        const buttons = Array.from(candidate.querySelectorAll('button[aria-pressed]'));
        if (buttons.length !== 2) return false;
        const states = buttons.map((button) => button.getAttribute("aria-pressed"));
        if (states.filter((state) => state === "true").length !== 1) return false;
        if (states.filter((state) => state === "false").length !== 1) return false;
        const label = normalize(candidate.getAttribute("aria-label"));
        const labels = new Set(buttons.map((button) => normalize(button.textContent)));
        return label === "composer mode" || (labels.has("chat") && labels.has("work"));
      });
      if (!group) return { ok: false, reason: "missing" };
      const buttons = Array.from(group.querySelectorAll('button[aria-pressed]'));
      const current = buttons.find((button) => button.getAttribute("aria-pressed") === "true");
      const target = buttons.find((button) => button.getAttribute("aria-pressed") === "false");
      if (!target || target.disabled || target.getAttribute("aria-disabled") === "true") {
        return { ok: false, reason: "disabled" };
      }
      const from = String(current?.textContent || "").trim();
      const to = String(target.textContent || "").trim();
      target.click();
      return { ok: true, from, to };
    })()
  `, true);
  if (result?.ok === true) return result;
  if (result?.reason === "disabled") {
    throw new Error("Переключатель Chat / Work сейчас недоступен");
  }
  throw new Error("Переключатель Chat / Work не найден в текущем окне ChatGPT");
}

async function clearComposerProject() {
  focusChatGPT();
  const window = usableWindow();
  if (!window || typeof window.webContents.executeJavaScript !== "function") {
    throw new Error("Нет доступного окна ChatGPT для снятия проекта");
  }
  const result = await window.webContents.executeJavaScript(`
    (() => {
      // NOSTROMO_CLEAR_COMPOSER_PROJECT
      const buttons = Array.from(
        document.querySelectorAll(
          "button[data-clear-project-button]:not(:disabled)"
        )
      ).filter((button) => {
        if (!button.isConnected || button.getAttribute("aria-disabled") === "true") {
          return false;
        }
        const style = window.getComputedStyle(button);
        return style.display !== "none"
          && style.visibility !== "hidden"
          && button.getClientRects().length > 0;
      });
      if (buttons.length === 0) return { ok: false, reason: "missing" };
      if (buttons.length !== 1) return { ok: false, reason: "ambiguous" };
      buttons[0].click();
      return { ok: true };
    })()
  `, true);
  if (result?.ok === true) return;
  if (result?.reason === "ambiguous") {
    throw new Error("В текущем окне ChatGPT найдено несколько кнопок «Работать без проекта»");
  }
  throw new Error("Кнопка «Работать без проекта» сейчас недоступна");
}

function discoverCommandIDs() {
  const fallback = {
    commandIds: new Set(COMPATIBILITY.builds.some((entry) => entry.verified && entry.version === CHATGPT_VERSION && entry.build === CHATGPT_BUILD) ? SAFE_COMMAND_CANDIDATES : []),
    source: "verified-fallback",
  };
  if (!process.resourcesPath) return fallback;
  try {
    const buildDirectory = path.join(process.resourcesPath, "app.asar", ".vite", "build");
    const files = fs.readdirSync(buildDirectory)
      .filter((name) => name.endsWith(".js"))
      .sort();
    const found = new Set();
    let inspectedBytes = 0;
    for (const name of files) {
      const file = path.join(buildDirectory, name);
      const stat = fs.statSync(file);
      if (stat.size > 16 * 1024 * 1024 || inspectedBytes + stat.size > 32 * 1024 * 1024) continue;
      inspectedBytes += stat.size;
      const source = fs.readFileSync(file, "utf8");
      const pattern = /\{id:`([^`]+)`,titleIntlId:`codex\.command\.[^`]+`/g;
      for (const match of source.matchAll(pattern)) found.add(match[1]);
    }
    if (
      found.size < 50 ||
      !found.has("composer.submit") ||
      !found.has("newTask")
    ) return fallback;
    return { commandIds: found, source: "runtime-app-asar" };
  } catch (error) {
    log(`Не удалось обнаружить реестр команд: ${error instanceof Error ? error.message : String(error)}`);
    return fallback;
  }
}

function runtimeCapabilityManifest() {
  const { BrowserWindow } = require("electron");
  const commandIds = [...ALLOWED_COMMANDS].sort();
  const unavailableFeatures = [];
  for (const [id, label] of [
    ["composer.openPermissions", "Окно разрешений не зарегистрировано в проверенной сборке ChatGPT."],
    ["compact", "Команда Compact не зарегистрирована как команда приложения в проверенной сборке ChatGPT."],
    ["status", "Команда Status не зарегистрирована как команда приложения в проверенной сборке ChatGPT."],
  ]) {
    if (!DISCOVERED_COMMANDS.commandIds.has(id)) unavailableFeatures.push(label);
  }
  return {
    v: PROTOCOL_VERSION,
    type: "capabilities",
    commandIds,
    commandRegistrySource: DISCOVERED_COMMANDS.source,
    requiredApis: {
      browserWindow: typeof BrowserWindow?.getAllWindows === "function",
      rendererMessaging: Boolean(usableWindow()?.webContents?.send),
      rendererEvaluation: Boolean(usableWindow()?.webContents?.executeJavaScript),
      scopedHidHook: hookState.hid,
      microServiceHook: hookState.service,
    },
    unavailableFeatures,
    chatGPTVersion: CHATGPT_VERSION,
    chatGPTBuild: CHATGPT_BUILD,
    adapterID: ADAPTER_ID,
  };
}

async function readRuntimeState() {
  const window = usableWindow();
  if (!window || typeof window.webContents.executeJavaScript !== "function") {
    return { reasoningEffort: null };
  }
  const reasoningEffort = await window.webContents.executeJavaScript(`
    (() => {
      const efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
      const nodes = Array.from(document.querySelectorAll(
        '[aria-label*="reason" i], [data-testid*="reason" i], button'
      )).slice(0, 500);
      for (const node of nodes) {
        const text = [
          node.getAttribute("aria-label"),
          node.getAttribute("data-testid"),
          node.textContent
        ].filter(Boolean).join(" ").toLowerCase();
        if (!text.includes("reason")) continue;
        const match = efforts.find((effort) =>
          new RegExp("\\\\b" + effort + "\\\\b", "i").test(text)
        );
        if (match) return match;
      }
      return null;
    })()
  `, true);
  return {
    reasoningEffort: typeof reasoningEffort === "string" ? reasoningEffort : null,
  };
}

function sendViewMessage(message) {
  const window = usableWindow();
  if (!window) throw new Error("Нет доступного окна ChatGPT");
  window.webContents.send(VIEW_MESSAGE_CHANNEL, message);
}

function focusChatGPT(targetWindow = usableWindow()) {
  const { app } = require("electron");
  const window = targetWindow;
  if (!isUsable(window)) throw new Error("Нет доступного окна ChatGPT");
  if (typeof app.show === "function") app.show();
  if (typeof window.isMinimized === "function" && window.isMinimized()) window.restore();
  if (!window.isVisible()) window.show();
  if (typeof window.moveTop === "function") window.moveTop();
  window.focus();
  if (typeof app.focus === "function") app.focus({ steal: true });
}

function toggleChatGPT(minimizeIfVisible) {
  const window = usableWindow();
  if (!window) throw new Error("Нет доступного окна ChatGPT");
  if (minimizeIfVisible && isVisible(window) && !isMinimized(window)) {
    if (typeof window.minimize !== "function") {
      throw new Error("Окно ChatGPT не поддерживает сворачивание");
    }
    window.minimize();
    return;
  }
  focusChatGPT(window);
}

function sendScroll(deltaY) {
  const window = usableWindow(true);
  if (!window) throw new Error("Для прокрутки окно ChatGPT должно быть активным");
  const bounds = window.getContentBounds();
  window.webContents.sendInputEvent({
    type: "mouseWheel",
    x: Math.floor(bounds.width / 2),
    y: Math.floor(bounds.height / 2),
    deltaX: 0,
    deltaY,
    hasPreciseScrollingDeltas: true,
    canScroll: true,
  });
}

function sendKey(key) {
  const window = usableWindow();
  if (!window) throw new Error("Нет доступного окна ChatGPT");
  window.webContents.sendInputEvent({ type: "keyDown", keyCode: key });
  window.webContents.sendInputEvent({ type: "keyUp", keyCode: key });
}

function usableWindow(requireFocus = false) {
  const { BrowserWindow } = require("electron");
  const focused = BrowserWindow.getFocusedWindow();
  if (isUsable(focused)) return focused;
  if (requireFocus) return null;
  // A minimized Electron window is not visible and is normally not the
  // focused BrowserWindow. It still must be selected so focusChatGPT() can
  // restore and show it. ChatGPT can also own hidden utility windows, so do
  // not depend on BrowserWindow's creation order when choosing the target.
  const candidates = BrowserWindow.getAllWindows().filter(isUsable);
  return candidates.find((candidate) =>
    isVisible(candidate) && !isMinimized(candidate)
  ) ?? candidates.find(isMinimized) ?? candidates.find(isVisible) ?? candidates[0];
}

function isUsable(window) {
  return window && !window.isDestroyed() && window.webContents && !window.webContents.isDestroyed();
}

function isMinimized(window) {
  return typeof window.isMinimized === "function" && window.isMinimized();
}

function isVisible(window) {
  return typeof window.isVisible === "function" && window.isVisible();
}

function installScopedHooks() {
  if (!isMainThread || !process.versions.electron || process.type !== "browser") return;
  try {
    assertCompatible();
  } catch (error) {
    log(error.message);
    return;
  }

  const originalLoad = Module._load;
  let hidProxy;
  let topologyProxy;
  let codexMicroServiceModuleProxy;
  Module._load = function nostromoCodexLoad(request, parent, isMain) {
    const filename = parent && typeof parent.filename === "string" ? parent.filename : "";
    if (
      typeof request === "string" &&
      path.resolve(path.dirname(filename), request).endsWith(`/${SERVICE_MODULE}`) &&
      /[\\/]main-[^\\/]+\.js$/.test(filename)
    ) {
      const real = Reflect.apply(originalLoad, this, [request, parent, isMain]);
      try { codexMicroServiceModuleProxy ||= createCodexMicroServiceModuleProxy(real); }
      catch (error) { log(String(error)); return real; }
      hookState.service = true;
      return codexMicroServiceModuleProxy;
    }
    if (
      request === "node-hid" &&
      (
        filename.endsWith(`/${SERVICE_MODULE}`) ||
        /[\\/]@worklouder[\\/](?:device-kit-oai|wl-device-kit)[\\/]/.test(filename)
      )
    ) {
      const real = Reflect.apply(originalLoad, this, [request, parent, isMain]);
      try { hidProxy ||= createNodeHidProxy(real); }
      catch (error) { log(String(error)); return real; }
      hookState.hid = true;
      return hidProxy;
    }
    if (
      typeof request === "string" &&
      /hid[-_]topology[-_]watcher\.node$/.test(request) &&
      filename.endsWith(`/${SERVICE_MODULE}`)
    ) {
      const real = Reflect.apply(originalLoad, this, [request, parent, isMain]);
      try { topologyProxy ||= createTopologyProxy(real); }
      catch (error) { log(String(error)); return real; }
      hookState.topology = true;
      return topologyProxy;
    }
    return Reflect.apply(originalLoad, this, [request, parent, isMain]);
  };
  log("Изолированные HID-перехватчики установлены");
}

function stripManagedEnvironment() {
  const options = process.env.NODE_OPTIONS;
  if (options) {
    const escaped = __filename.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const next = options
      .replace(new RegExp(`--require=(?:"${escaped}"|'${escaped}'|${escaped})`), "")
      .trim();
    if (next) process.env.NODE_OPTIONS = next;
    else delete process.env.NODE_OPTIONS;
  }
  delete process.env.NOSTROMO_CODEX_DISCOVERY;
  delete process.env.NOSTROMO_CODEX_SOCKET;
  delete process.env.NOSTROMO_CODEX_TOKEN;
  delete process.env.NOSTROMO_CODEX_FORCE;
  delete process.env.NOSTROMO_CODEX_CHATGPT_VERSION;
  delete process.env.NOSTROMO_CODEX_CHATGPT_BUILD;
  delete process.env.NOSTROMO_CODEX_SERVICE_MODULE;
  delete process.env.NOSTROMO_CODEX_ADAPTER;
}

installScopedHooks();

// Small socket-free surface for deterministic regression tests. The native
// launcher never sets this flag.
if (process.env.NOSTROMO_CODEX_TEST_EXPORTS === "1") {
  module.exports = Object.freeze({
    appActionContract: APP_ACTION_CONTRACT,
    assertCompatible,
    focusChatGPT,
    toggleChatGPT,
    usableWindow,
  });
}
