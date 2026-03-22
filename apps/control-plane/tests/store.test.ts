import { describe, expect, it } from "vitest";

import { MemoryBrokerStore } from "../src/store.js";

describe("MemoryBrokerStore", () => {
  it("registers a device and creates a pairing flow", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });

    const pairing = store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });

    const claimed = store.claimPairing(pairing.pairingCode, "iPhone");
    const bootstrap = store.getBootstrap(
      claimed.clientToken,
      "ws://localhost:8787",
    );

    expect(bootstrap.device.id).toBe(registration.device.id);
    expect(bootstrap.client.name).toBe("iPhone");
  });

  it("accepts host status payloads with omitted nullable fields", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    const pairing = store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });
    const claimed = store.claimPairing(pairing.pairingCode, "iPhone");

    store.updateHostStatus(registration.device.id, {
      deviceId: registration.device.id,
      online: true,
      selectedWindowId: undefined,
      screenRecording: "granted",
      accessibility: "granted",
      codex: {
        state: "ready",
        installed: true,
        authenticated: true,
        authMode: "chatgpt",
        model: "gpt-5.4-mini",
        threadId: "thread_1",
        activeTurnId: undefined,
        lastError: undefined,
      },
    });

    const bootstrap = store.getBootstrap(
      claimed.clientToken,
      "ws://localhost:8787",
    );
    expect(bootstrap.status.selectedWindowId).toBeNull();
    expect(bootstrap.status.directUrl).toBeNull();
    expect(bootstrap.status.codex.threadId).toBe("thread_1");
  });

  it("accepts window updates when nullable fields are omitted on the wire", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });

    store.updateWindows(registration.device.id, [
      {
        id: 1,
        ownerPid: 100,
        ownerName: "Finder",
        title: "Downloads",
        bounds: {
          x: 0,
          y: 0,
          width: 500,
          height: 400,
        },
        isOnScreen: true,
        capabilities: ["ax_read", "pixel_fallback"],
      },
    ]);

    const device = store.getDevice(registration.device.id);
    expect(device?.windows[0]?.semanticSummary).toBeNull();
    expect(device?.windows[0]?.appBundleId).toBeNull();
  });

  it("generates a pairing URL with only the pairing code", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });

    const pairing = store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://192.168.0.115:5173",
    });

    const url = new URL(pairing.pairingUrl);
    expect(url.searchParams.get("code")).toBe(pairing.pairingCode);
    expect(url.searchParams.has("api")).toBe(false);
  });

  it("keeps the latest client socket attached when an older socket closes", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    const pairing = store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });
    const claimed = store.claimPairing(pairing.pairingCode, "iPhone");

    const firstSocket = { name: "first" } as any;
    const secondSocket = { name: "second" } as any;

    store.attachClient(claimed.clientToken, firstSocket);
    store.attachClient(claimed.clientToken, secondSocket);
    store.detachClientSocket(claimed.clientToken, firstSocket);

    expect(store.getConnectedClientSockets(registration.device.id)).toEqual([
      secondSocket,
    ]);

    store.detachClientSocket(claimed.clientToken, secondSocket);
    expect(store.getConnectedClientSockets(registration.device.id)).toEqual([]);
  });

  it("keeps the latest host socket attached when an older socket closes", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });

    const firstSocket = {
      closeCalled: false,
      close() {
        this.closeCalled = true;
      },
    } as any;
    const secondSocket = {
      closeCalled: false,
      close() {
        this.closeCalled = true;
      },
    } as any;

    store.attachHost(registration.device.id, firstSocket);
    store.attachHost(registration.device.id, secondSocket);
    store.detachHostSocket(registration.device.id, firstSocket);

    expect(firstSocket.closeCalled).toBe(true);
    expect(store.getDevice(registration.device.id)?.hostSocket).toBe(
      secondSocket,
    );
    expect(store.getDevice(registration.device.id)?.device.online).toBe(true);

    store.detachHostSocket(registration.device.id, secondSocket);
    expect(store.getDevice(registration.device.id)?.hostSocket).toBeUndefined();
    expect(store.getDevice(registration.device.id)?.device.online).toBe(false);
  });

  it("bootstraps offline host status after the host socket disconnects", () => {
    const store = new MemoryBrokerStore();
    const registration = store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    const pairing = store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });
    const claimed = store.claimPairing(pairing.pairingCode, "iPhone");

    const socket = { close() {} } as any;
    store.attachHost(registration.device.id, socket);
    store.updateHostStatus(registration.device.id, {
      deviceId: registration.device.id,
      online: true,
      selectedWindowId: 7,
      screenRecording: "granted",
      accessibility: "granted",
      directUrl: null,
      codex: {
        state: "ready",
        installed: true,
        authenticated: true,
        authMode: "chatgpt",
        model: "gpt-5.4-mini",
        threadId: "thread_1",
        activeTurnId: null,
        lastError: null,
      },
    });

    store.detachHostSocket(registration.device.id, socket);

    const bootstrap = store.getBootstrap(
      claimed.clientToken,
      "ws://localhost:8787",
    );
    expect(bootstrap.status.online).toBe(false);
    expect(bootstrap.status.selectedWindowId).toBeNull();
    expect(bootstrap.status.codex.threadId).toBe("thread_1");
  });
});
