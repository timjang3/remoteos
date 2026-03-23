import Fastify from "fastify";
import websocket from "@fastify/websocket";
import WebSocket from "ws";
import { afterEach, describe, expect, it } from "vitest";

import { MemoryBrokerStore } from "../src/store.js";
import { registerWsBroker } from "../src/wsBroker.js";
import { WsTicketStore } from "../src/wsTicketStore.js";

type JsonMessage = {
  jsonrpc?: string;
  method?: string;
  params?: Record<string, unknown>;
};

async function waitFor(predicate: () => boolean, timeoutMs = 2_000) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt >= timeoutMs) {
      throw new Error("Timed out waiting for condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("registerWsBroker", () => {
  const sockets = new Set<WebSocket>();
  const apps = new Set<ReturnType<typeof Fastify>>();

  afterEach(async () => {
    for (const socket of sockets) {
      socket.close();
    }
    sockets.clear();

    for (const app of apps) {
      await app.close();
    }
    apps.clear();
  });

  it("requests an authoritative host state sync when a client websocket attaches", async () => {
    const app = Fastify();
    apps.add(app);
    await app.register(websocket);

    const store = new MemoryBrokerStore();
    await registerWsBroker(app, {
      store,
      authMode: "none",
      wsTickets: new WsTicketStore()
    });

    await app.listen({ host: "127.0.0.1", port: 0 });
    const address = app.server.address();
    if (!address || typeof address === "string") {
      throw new Error("Expected TCP server address");
    }

    const registration = await store.registerDevice({
      name: "Test Mac",
      mode: "hosted"
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }

    const pairing = await store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173"
    });
    const claimed = await store.claimPairing(pairing.pairingCode, "iPhone");

    const baseWsUrl = `ws://127.0.0.1:${address.port}`;
    const hostMessages: JsonMessage[] = [];
    const clientMessages: JsonMessage[] = [];

    const hostSocket = new WebSocket(
      `${baseWsUrl}/ws/host?deviceId=${encodeURIComponent(registration.device.id)}&deviceSecret=${encodeURIComponent(registration.deviceSecret)}`
    );
    sockets.add(hostSocket);
    hostSocket.on("message", (raw) => {
      const message = JSON.parse(raw.toString()) as JsonMessage;
      hostMessages.push(message);
      if (message.method === "host.state.sync") {
        hostSocket.send(JSON.stringify({
          jsonrpc: "2.0",
          method: "host.status",
          params: {
            deviceId: registration.device.id,
            online: true,
            selectedWindowId: null,
            screenRecording: "granted",
            accessibility: "granted",
            directUrl: null,
            codex: {
              state: "ready",
              installed: true,
              authenticated: true,
              authMode: "chatgpt",
              model: "gpt-5.4-mini",
              threadId: "thread_ready",
              activeTurnId: null,
              lastError: null
            }
          }
        }));
      }
    });
    await new Promise<void>((resolve, reject) => {
      hostSocket.once("open", () => resolve());
      hostSocket.once("error", reject);
    });
    await waitFor(() => hostMessages.filter((message) => message.method === "host.state.sync").length === 1);
    const initialSyncCount = hostMessages.filter((message) => message.method === "host.state.sync").length;

    const clientSocket = new WebSocket(
      `${baseWsUrl}/ws/client?clientToken=${encodeURIComponent(claimed.clientToken)}`
    );
    sockets.add(clientSocket);
    clientSocket.on("message", (raw) => {
      clientMessages.push(JSON.parse(raw.toString()) as JsonMessage);
    });
    await new Promise<void>((resolve, reject) => {
      clientSocket.once("open", () => resolve());
      clientSocket.once("error", reject);
    });

    await waitFor(() => hostMessages.filter((message) => message.method === "host.state.sync").length > initialSyncCount);
    await waitFor(() =>
      clientMessages.some((message) =>
        message.method === "codex.status"
        && message.params?.state === "ready"
      )
    );

    const latestHostStatus = [...clientMessages]
      .reverse()
      .find((message) => message.method === "host.status");
    expect(latestHostStatus?.params?.online).toBe(true);
    expect((latestHostStatus?.params?.codex as { state?: string } | undefined)?.state).toBe("ready");
  });
});
