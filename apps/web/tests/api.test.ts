import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { BrokerClient, claimPairing, createSpeechTranscription, getBootstrap, resolveControlPlaneBaseUrl } from "../src/api";

const originalWindow = globalThis.window;
const originalFetch = globalThis.fetch;
const originalWebSocket = globalThis.WebSocket;

function installWindow(href: string) {
  const storage = new Map<string, string>();

  vi.stubGlobal("window", {
    location: new URL(href),
    localStorage: {
      getItem(key: string) {
        return storage.get(key) ?? null;
      },
      setItem(key: string, value: string) {
        storage.set(key, value);
      },
      removeItem(key: string) {
        storage.delete(key);
      }
    }
  });
}

describe("api base URL handling", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    if (originalWindow === undefined) {
      // @ts-expect-error test cleanup
      delete globalThis.window;
    } else {
      vi.stubGlobal("window", originalWindow);
    }

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
  });

  it("rewrites loopback api query params to the current host", () => {
    installWindow("http://192.168.1.25:5173/?code=ABC123&api=http://localhost:8787");

    expect(resolveControlPlaneBaseUrl()).toBe("http://192.168.1.25:8787");
  });

  it("retries pairing against the current host when the provided broker URL is unreachable", async () => {
    installWindow("http://192.168.1.25:5173/?code=ABC123&api=http://192.168.1.25:8787");

    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            pairing: {
              id: "pair_1",
              deviceId: "device_1",
              pairingCode: "ABC123",
              claimed: true,
              createdAt: new Date().toISOString(),
              expiresAt: new Date().toISOString(),
              pairingUrl: "http://192.168.1.25:5173/?code=ABC123"
            },
            clientToken: "token_1",
            wsUrl: "ws://192.168.1.25:8787/ws/client?clientToken=token_1"
          }),
          {
            status: 200,
            headers: {
              "content-type": "application/json"
            }
          }
        )
      );

    vi.stubGlobal("fetch", fetchMock);

    const result = await claimPairing("http://10.0.0.12:8787", "ABC123", "Phone");

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "http://10.0.0.12:8787/pairings/ABC123/claim",
      expect.any(Object)
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://192.168.1.25:8787/pairings/ABC123/claim",
      expect.any(Object)
    );
    expect(result.baseUrl).toBe("http://192.168.1.25:8787");
    expect(result.data.clientToken).toBe("token_1");
  });

  it("retries bootstrap against the current host when the stored broker URL is unreachable", async () => {
    installWindow("http://192.168.1.25:5173/");

    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce(
        new Response(
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
            windows: [],
            status: {
              deviceId: "device_1",
              online: true,
              selectedWindowId: null,
              screenRecording: "granted",
              accessibility: "granted",
              directUrl: null
            },
            wsUrl: "ws://192.168.1.25:8787/ws/client?clientToken=token_1",
            speech: {
              transcriptionAvailable: true,
              provider: "openai",
              maxDurationMs: 120000,
              maxUploadBytes: 10485760
            }
          }),
          {
            status: 200,
            headers: {
              "content-type": "application/json"
            }
          }
        )
      );

    vi.stubGlobal("fetch", fetchMock);

    const result = await getBootstrap("http://10.0.0.12:8787", "token_1");

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "http://10.0.0.12:8787/bootstrap?clientToken=token_1",
      expect.objectContaining({ credentials: "include" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://192.168.1.25:8787/bootstrap?clientToken=token_1",
      expect.objectContaining({ credentials: "include" })
    );
    expect(result.baseUrl).toBe("http://192.168.1.25:8787");
    expect(result.data.device.id).toBe("device_1");
  });

  it("uploads dictation audio as multipart form data", async () => {
    installWindow("http://192.168.1.25:5173/");

    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(init?.method).toBe("POST");
      expect(init?.body).toBeInstanceOf(FormData);
      const form = init?.body as FormData;
      expect(form.get("clientToken")).toBe("token_1");
      expect(form.get("language")).toBe("en-US");
      expect(form.get("durationMs")).toBe("2500");

      return new Response(
        JSON.stringify({
          text: "hello world",
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
    });

    vi.stubGlobal("fetch", fetchMock as typeof fetch);

    const result = await createSpeechTranscription("http://192.168.1.25:8787", {
      clientToken: "token_1",
      audio: new Blob(["audio"], { type: "audio/webm" }),
      filename: "dictation.webm",
      language: "en-US",
      durationMs: 2500
    });

    expect(result.data.text).toBe("hello world");
    expect(fetchMock).toHaveBeenCalledWith(
      "http://192.168.1.25:8787/speech/transcriptions",
      expect.objectContaining({
        method: "POST",
        body: expect.any(FormData)
      })
    );
  });

  it("rejects pending broker requests when the socket closes", async () => {
    class FakeWebSocket {
      static readonly OPEN = 1;

      readonly OPEN = FakeWebSocket.OPEN;
      readyState = FakeWebSocket.OPEN;
      private listeners = new Map<string, Set<(event?: any) => void>>();

      addEventListener(type: string, handler: (event?: any) => void) {
        const handlers = this.listeners.get(type) ?? new Set();
        handlers.add(handler);
        this.listeners.set(type, handlers);
      }

      send() {}

      close() {
        this.readyState = 3;
        for (const handler of this.listeners.get("close") ?? []) {
          handler();
        }
      }
    }

    vi.stubGlobal("WebSocket", FakeWebSocket as any);

    const client = new BrokerClient("ws://localhost:8787/ws/client?clientToken=test", {});
    const socket = client.connect();
    const pending = client.startAgent("hi");
    socket.close();

    await expect(pending).rejects.toThrow("Socket closed");
  });

  it("resolves agent turn start with the initial turn state", async () => {
    class FakeWebSocket {
      static readonly OPEN = 1;

      readonly OPEN = FakeWebSocket.OPEN;
      readyState = FakeWebSocket.OPEN;
      private listeners = new Map<string, Set<(event?: any) => void>>();

      addEventListener(type: string, handler: (event?: any) => void) {
        const handlers = this.listeners.get(type) ?? new Set();
        handlers.add(handler);
        this.listeners.set(type, handlers);
      }

      send(data: string) {
        const message = JSON.parse(data);
        const startedAt = "2026-03-20T17:10:00.000Z";
        const success = {
          jsonrpc: "2.0",
          id: message.id,
          result: {
            turn: {
              id: "turn_1",
              prompt: "hi",
              targetWindowId: null,
              status: "running",
              error: null,
              startedAt,
              updatedAt: startedAt,
              completedAt: null
            },
            userItem: {
              id: "user-turn_1",
              turnId: "turn_1",
              kind: "user_message",
              status: "completed",
              title: "User",
              body: "hi",
              createdAt: startedAt,
              updatedAt: startedAt,
              metadata: {}
            }
          }
        };

        queueMicrotask(() => {
          for (const handler of this.listeners.get("message") ?? []) {
            handler({ data: JSON.stringify(success) });
          }
        });
      }

      close() {
        this.readyState = 3;
        for (const handler of this.listeners.get("close") ?? []) {
          handler();
        }
      }
    }

    vi.stubGlobal("WebSocket", FakeWebSocket as any);

    const client = new BrokerClient("ws://localhost:8787/ws/client?clientToken=test", {});
    client.connect();

    await expect(client.startAgent("hi")).resolves.toMatchObject({
      turn: {
        id: "turn_1",
        status: "running"
      },
      userItem: {
        id: "user-turn_1",
        kind: "user_message",
        body: "hi"
      }
    });
  });

  it("delivers prompt notifications and sends prompt responses", async () => {
    class FakeWebSocket {
      static readonly OPEN = 1;

      readonly OPEN = FakeWebSocket.OPEN;
      readyState = FakeWebSocket.OPEN;
      sent: string[] = [];
      private listeners = new Map<string, Set<(event?: any) => void>>();

      addEventListener(type: string, handler: (event?: any) => void) {
        const handlers = this.listeners.get(type) ?? new Set();
        handlers.add(handler);
        this.listeners.set(type, handlers);
      }

      send(data: string) {
        this.sent.push(data);
      }

      emit(type: string, event?: any) {
        for (const handler of this.listeners.get(type) ?? []) {
          handler(event);
        }
      }

      close() {
        this.readyState = 3;
        this.emit("close");
      }
    }

    vi.stubGlobal("WebSocket", FakeWebSocket as any);

    const requested = vi.fn();
    const resolved = vi.fn();
    const client = new BrokerClient("ws://localhost:8787/ws/client?clientToken=test", {
      agentPromptRequested: requested,
      agentPromptResolved: resolved
    });
    const socket = client.connect() as unknown as FakeWebSocket;

    socket.emit("message", {
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "agent.prompt.requested",
        params: {
          id: "prompt_1",
          turnId: "turn_1",
          source: "codex",
          kind: "request_user_input",
          title: "Codex needs input",
          body: "Answer the question.",
          questions: [
            {
              id: "token",
              header: "Token",
              question: "What token should I use?",
              isOther: false,
              isSecret: true,
              options: []
            }
          ],
          createdAt: "2026-03-20T17:10:00.000Z",
          updatedAt: "2026-03-20T17:10:00.000Z"
        }
      })
    });

    const pendingResponse = client.respondAgentPrompt({
      id: "prompt_1",
      action: "submit",
      answers: {
        token: {
          answers: ["secret"]
        }
      }
    });

    const responseMessage = JSON.parse(socket.sent.at(-1) ?? "{}");
    socket.emit("message", {
      data: JSON.stringify({
        jsonrpc: "2.0",
        id: responseMessage.id,
        result: {
          ok: true
        }
      })
    });

    await expect(pendingResponse).resolves.toEqual({ ok: true });

    socket.emit("message", {
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "agent.prompt.resolved",
        params: {
          id: "prompt_1",
          turnId: "turn_1",
          status: "submitted",
          resolvedAt: "2026-03-20T17:11:00.000Z"
        }
      })
    });

    expect(requested).toHaveBeenCalledWith(
      expect.objectContaining({
        id: "prompt_1",
        source: "codex"
      })
    );
    expect(responseMessage.method).toBe("agent.prompt.respond");
    expect(responseMessage.params.answers.token.answers).toEqual(["secret"]);
    expect(resolved).toHaveBeenCalledWith(
      expect.objectContaining({
        id: "prompt_1",
        status: "submitted"
      })
    );
  });
});
