// @vitest-environment jsdom

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../src/authClient", () => ({
  createControlPlaneAuthClient() {
    return {
      useSession() {
        return { data: null };
      },
      signOut: vi.fn()
    };
  }
}));

import { App } from "../src/app";

const NOW = "2026-03-22T22:00:00.000Z";
const CLIENT_TOKEN_STORAGE_KEY = "remoteos.clientToken";
const actEnvironment = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean;
};
const baseSpeechCapabilities = {
  transcriptionAvailable: true,
  provider: "openai",
  maxDurationMs: 120_000,
  maxUploadBytes: 10 * 1024 * 1024
} as const;

type Listener = (event?: unknown) => void;
type SelectedWindowId = number | null;

const sockets: FakeWebSocket[] = [];

function createWindow() {
  return {
    id: 1,
    ownerPid: 42,
    ownerName: "Safari",
    appBundleId: "com.apple.Safari",
    title: "Remote Window",
    bounds: {
      x: 0,
      y: 0,
      width: 1440,
      height: 900
    },
    isOnScreen: true,
    capabilities: ["pixel_fallback"],
    semanticSummary: null
  };
}

function createHostStatus(selectedWindowId: SelectedWindowId) {
  return {
    deviceId: "device_1",
    online: true,
    selectedWindowId,
    screenRecording: "granted",
    accessibility: "granted",
    directUrl: null,
    codex: {
      state: "ready",
      installed: true,
      authenticated: true,
      authMode: "chatgpt",
      model: "gpt-5.4",
      threadId: null,
      activeTurnId: null,
      lastError: null
    }
  };
}

function createBootstrapPayload(options?: {
  speech?: {
    transcriptionAvailable: boolean;
    provider: "openai" | null;
    maxDurationMs: number;
    maxUploadBytes: number;
  };
}) {
  return {
    client: {
      id: "client_1",
      deviceId: "device_1",
      name: "Phone",
      token: "token_1"
    },
    device: {
      id: "device_1",
      name: "My Mac",
      online: true,
      mode: "hosted"
    },
    windows: [createWindow()],
    status: createHostStatus(1),
    wsUrl: "ws://localhost:8787/ws/client?clientToken=token_1",
    speech: options?.speech ?? baseSpeechCapabilities
  };
}

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;

  readonly CONNECTING = FakeWebSocket.CONNECTING;
  readonly OPEN = FakeWebSocket.OPEN;
  readyState = FakeWebSocket.CONNECTING;
  readonly sent: string[] = [];
  private readonly listeners = new Map<string, Set<Listener>>();

  constructor(readonly url: string) {
    sockets.push(this);
    queueMicrotask(() => {
      this.readyState = FakeWebSocket.OPEN;
      this.emit("open");
    });
  }

  addEventListener(type: string, handler: Listener) {
    const handlers = this.listeners.get(type) ?? new Set<Listener>();
    handlers.add(handler);
    this.listeners.set(type, handlers);
  }

  send(data: string) {
    this.sent.push(data);
    const message = JSON.parse(data);

    switch (message.method) {
      case "windows.list":
        this.respond(message.id, {
          windows: [createWindow()]
        });
        return;
      case "stream.start":
        this.respond(message.id, { ok: true });
        return;
      case "stream.stop":
        this.respond(message.id, { ok: true });
        return;
      case "semantic.snapshot":
        this.respond(message.id, {
          windowId: 1,
          focused: null,
          elements: [],
          summary: "Remote Window",
          generatedAt: NOW
        });
        return;
      default:
        return;
    }
  }

  notify(method: string, params: unknown) {
    queueMicrotask(() => {
      this.emit("message", {
        data: JSON.stringify({
          jsonrpc: "2.0",
          method,
          params
        })
      });
    });
  }

  close() {
    this.readyState = 3;
    this.emit("close");
  }

  private respond(id: string | number, result: unknown) {
    queueMicrotask(() => {
      this.emit("message", {
        data: JSON.stringify({
          jsonrpc: "2.0",
          id,
          result
        })
      });
    });
  }

  private emit(type: string, event?: any) {
    for (const handler of this.listeners.get(type) ?? []) {
      handler(event);
    }
  }
}

class FakeMediaRecorder {
  static isTypeSupported(mimeType: string) {
    return mimeType === "audio/webm;codecs=opus" || mimeType === "audio/webm" || mimeType === "audio/mp4";
  }

  readonly mimeType: string;
  state: "inactive" | "recording" = "inactive";
  private readonly listeners = new Map<string, Set<Listener>>();

  constructor(
    readonly stream: { getTracks: () => Array<{ stop: () => void }> },
    options?: { mimeType?: string }
  ) {
    this.mimeType = options?.mimeType ?? "audio/webm";
  }

  addEventListener(type: string, handler: Listener) {
    const handlers = this.listeners.get(type) ?? new Set<Listener>();
    handlers.add(handler);
    this.listeners.set(type, handlers);
  }

  removeEventListener(type: string, handler: Listener) {
    this.listeners.get(type)?.delete(handler);
  }

  start() {
    this.state = "recording";
  }

  stop() {
    this.state = "inactive";
    queueMicrotask(() => {
      this.emit("dataavailable", {
        data: new Blob(["audio"], { type: this.mimeType })
      });
      this.emit("stop");
    });
  }

  private emit(type: string, event?: unknown) {
    for (const handler of this.listeners.get(type) ?? []) {
      handler(event);
    }
  }
}

async function flushAsync(times = 6) {
  for (let index = 0; index < times; index += 1) {
    await act(async () => {
      await Promise.resolve();
    });
  }
}

describe("App browser stream lifecycle", () => {
  const originalFetch = globalThis.fetch;
  const originalWebSocket = globalThis.WebSocket;
  const originalMediaRecorder = globalThis.MediaRecorder;
  const originalScrollIntoView = Element.prototype.scrollIntoView;
  const originalSecureContext = window.isSecureContext;
  const originalMediaDevices = navigator.mediaDevices;

  let speechEnabled = true;
  let getUserMediaMock: ReturnType<typeof vi.fn>;
  let transcriptionText = "transcribed request";
  let transcriptionRequests = 0;

  beforeEach(() => {
    sockets.length = 0;
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    window.localStorage.clear();
    window.localStorage.setItem(CLIENT_TOKEN_STORAGE_KEY, "token_1");
    Element.prototype.scrollIntoView = vi.fn();
    speechEnabled = true;
    transcriptionText = "transcribed request";
    transcriptionRequests = 0;
    getUserMediaMock = vi.fn(async () => ({
      getTracks: () => [{ stop: vi.fn() }]
    }));
    Object.defineProperty(window, "isSecureContext", {
      value: true,
      configurable: true
    });
    Object.defineProperty(navigator, "mediaDevices", {
      value: {
        getUserMedia: getUserMediaMock
      },
      configurable: true
    });

    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof URL ? input.toString() : String(input);
      if (url.includes("/bootstrap?clientToken=token_1")) {
        return new Response(
          JSON.stringify(
            createBootstrapPayload({
              speech: speechEnabled
                ? baseSpeechCapabilities
                : {
                    ...baseSpeechCapabilities,
                    transcriptionAvailable: false,
                    provider: null
                  }
            })
          ),
          {
            status: 200,
            headers: {
              "content-type": "application/json"
            }
          }
        );
      }

      if (url.includes("/speech/transcriptions")) {
        transcriptionRequests += 1;
        return new Response(
          JSON.stringify({
            text: transcriptionText,
            provider: "openai",
            model: "gpt-4o-transcribe"
          }),
          {
            status: 200,
            headers: {
              "content-type": "application/json"
            }
          }
        );
      }

      throw new Error(`Unexpected fetch: ${url}`);
    }) as typeof fetch);

    vi.stubGlobal("WebSocket", FakeWebSocket as unknown as typeof WebSocket);
    vi.stubGlobal("MediaRecorder", FakeMediaRecorder as unknown as typeof MediaRecorder);
  });

  afterEach(() => {
    if (originalFetch === undefined) {
      // @ts-expect-error test cleanup
      delete globalThis.fetch;
    } else {
      vi.stubGlobal("fetch", originalFetch);
    }

    if (originalWebSocket === undefined) {
      // @ts-expect-error test cleanup
      delete globalThis.WebSocket;
    } else {
      vi.stubGlobal("WebSocket", originalWebSocket);
    }

    if (originalMediaRecorder === undefined) {
      // @ts-expect-error test cleanup
      delete globalThis.MediaRecorder;
    } else {
      vi.stubGlobal("MediaRecorder", originalMediaRecorder);
    }

    Object.defineProperty(window, "isSecureContext", {
      value: originalSecureContext,
      configurable: true
    });
    Object.defineProperty(navigator, "mediaDevices", {
      value: originalMediaDevices,
      configurable: true
    });

    Element.prototype.scrollIntoView = originalScrollIntoView;
    document.body.innerHTML = "";
    vi.restoreAllMocks();
    delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  });

  it("resubscribes the selected window stream when bootstrap restores a window", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<App />);
    });
    await flushAsync();

    expect(sockets).toHaveLength(1);

    const methods = sockets[0]!.sent.map((payload) => JSON.parse(payload).method);
    expect(methods).toContain("windows.list");
    expect(methods).toContain("stream.start");
    expect(methods).toContain("semantic.snapshot");

    await act(async () => {
      root.unmount();
    });
  });

  it("hides dictation when bootstrap disables speech transcription", async () => {
    speechEnabled = false;
    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<App />);
    });
    await flushAsync();

    expect(container.querySelector('button[aria-label="Start dictation"]')).toBeNull();

    await act(async () => {
      root.unmount();
    });
  });

  it("keeps the mobile UI on the home state after manually closing a stream", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<App />);
    });
    await flushAsync();

    sockets[0]!.notify("agent.item", {
      id: "assistant_1",
      turnId: "turn_1",
      kind: "assistant_message",
      status: "completed",
      title: "Codex",
      body: "Existing reply",
      createdAt: NOW,
      updatedAt: NOW,
      metadata: { phase: "final_answer" }
    });
    await flushAsync();

    expect(container.textContent).toContain("Existing reply");
    expect(container.querySelector(".window-preview")).not.toBeNull();

    await act(async () => {
      container
        .querySelector<HTMLButtonElement>('button[aria-label="Stop streaming"]')
        ?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await flushAsync();

    expect(
      sockets[0]!.sent.map((payload) => JSON.parse(payload).method)
    ).toContain("stream.stop");
    expect(container.querySelector(".window-preview")).toBeNull();
    expect(container.textContent).toContain("Welcome to RemoteOS");
    expect(container.textContent).not.toContain("Existing reply");

    sockets[0]!.notify("host.status", createHostStatus(1));
    await flushAsync();

    expect(container.querySelector(".window-preview")).toBeNull();
    expect(container.textContent).toContain("Welcome to RemoteOS");
    expect(container.textContent).not.toContain("Existing reply");
    expect(
      sockets[0]!.sent
        .map((payload) => JSON.parse(payload).method)
        .filter((method) => method === "stream.start")
    ).toHaveLength(1);

    await act(async () => {
      root.unmount();
    });
  });

  it("records and inserts a final transcript into the composer", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<App />);
    });
    await flushAsync();

    const startButton = container.querySelector<HTMLButtonElement>('button[aria-label="Start dictation"]');
    expect(startButton).not.toBeNull();

    await act(async () => {
      startButton?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await flushAsync();

    expect(getUserMediaMock).toHaveBeenCalledTimes(1);
    const stopButton = container.querySelector<HTMLButtonElement>('button[aria-label="Stop dictation"]');
    expect(stopButton).not.toBeNull();

    await act(async () => {
      stopButton?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await flushAsync();

    const composer = container.querySelector<HTMLTextAreaElement>("textarea");
    expect(composer?.value).toBe("transcribed request");
    expect(transcriptionRequests).toBe(1);

    await act(async () => {
      root.unmount();
    });
  });

  it("shows a permission error when microphone access is denied", async () => {
    getUserMediaMock.mockRejectedValueOnce(new DOMException("denied", "NotAllowedError"));

    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<App />);
    });
    await flushAsync();

    await act(async () => {
      container
        .querySelector<HTMLButtonElement>('button[aria-label="Start dictation"]')
        ?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await flushAsync();

    expect(container.textContent).toContain("Microphone permission was denied.");

    await act(async () => {
      root.unmount();
    });
  });
});
