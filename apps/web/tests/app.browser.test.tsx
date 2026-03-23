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

type Listener = (event?: unknown) => void;

const sockets: FakeWebSocket[] = [];

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
          windows: [
            {
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
            }
          ]
        });
        return;
      case "stream.start":
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
  const originalScrollIntoView = Element.prototype.scrollIntoView;

  beforeEach(() => {
    sockets.length = 0;
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    window.localStorage.clear();
    window.localStorage.setItem(CLIENT_TOKEN_STORAGE_KEY, "token_1");
    Element.prototype.scrollIntoView = vi.fn();

    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof URL ? input.toString() : String(input);
      if (!url.includes("/bootstrap?clientToken=token_1")) {
        throw new Error(`Unexpected fetch: ${url}`);
      }

      return new Response(
        JSON.stringify({
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
          windows: [
            {
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
            }
          ],
          status: {
            deviceId: "device_1",
            online: true,
            selectedWindowId: 1,
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
          },
          wsUrl: "ws://localhost:8787/ws/client?clientToken=token_1"
        }),
        {
          status: 200,
          headers: {
            "content-type": "application/json"
          }
        }
      );
    }) as typeof fetch);

    vi.stubGlobal("WebSocket", FakeWebSocket as unknown as typeof WebSocket);
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
});
