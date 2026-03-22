import { describe, expect, it } from "vitest";

import { MemoryBrokerStore } from "../src/store.js";

describe("MemoryBrokerStore", () => {
  it("returns an approval-required registration in hosted mode before device ownership is granted", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
      publicEnrollmentBaseUrl: "http://localhost:5173"
    });

    expect("approvalRequired" in registration).toBe(true);
    if (!("approvalRequired" in registration)) {
      throw new Error("Expected approval-required registration");
    }

    const enrollment = await store.getEnrollment(registration.enrollmentToken);
    expect(enrollment?.status).toBe("pending");
    expect(enrollment?.deviceId).toBe(registration.deviceId);
    expect(enrollment?.enrollmentUrl).toContain(`enroll=${registration.enrollmentToken}`);
  });

  it("blocks hosted pairings until the device enrollment is approved", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
      publicEnrollmentBaseUrl: "http://localhost:5173"
    });

    if (!("approvalRequired" in registration)) {
      throw new Error("Expected approval-required registration");
    }

    await expect(
      store.createPairing({
        deviceId: registration.deviceId,
        deviceSecret: registration.deviceSecret,
        publicPairBaseUrl: "http://localhost:5173",
        requireOwnership: true
      })
    ).rejects.toThrow("Device approval required");
  });

  it("binds device ownership on approval and allows hosted pairing afterward", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
      publicEnrollmentBaseUrl: "http://localhost:5173"
    });

    if (!("approvalRequired" in registration)) {
      throw new Error("Expected approval-required registration");
    }

    const enrollment = await store.approveEnrollment(registration.enrollmentToken, "user_123");
    expect(enrollment.status).toBe("approved");
    expect(enrollment.approvedByUserId).toBe("user_123");

    const persistedDevice = await store.getPersistedDevice(registration.deviceId);
    expect(persistedDevice?.userId).toBe("user_123");

    const pairing = await store.createPairing({
      deviceId: registration.deviceId,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
      requireOwnership: true
    });

    expect(pairing.deviceId).toBe(registration.deviceId);
  });

  it("registers a device and creates a pairing flow", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });

    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }

    const pairing = await store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });

    const claimed = await store.claimPairing(pairing.pairingCode, "iPhone");
    const bootstrap = await store.getBootstrap(claimed.clientToken);

    expect(bootstrap.device.id).toBe(registration.device.id);
    expect(bootstrap.client.name).toBe("iPhone");
  });

  it("rejects stale existing device credentials instead of silently creating a new device", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });

    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }

    await expect(
      store.registerDevice({
        name: "Tim's MacBook",
        mode: "hosted",
        existingDeviceId: registration.device.id,
        existingDeviceSecret: "wrong-secret",
      })
    ).rejects.toThrow("Unauthorized device");

    await expect(
      store.registerDevice({
        name: "Tim's MacBook",
        mode: "hosted",
        existingDeviceId: registration.device.id,
      })
    ).rejects.toThrow("Unauthorized device");
  });

  it("accepts host status payloads with omitted nullable fields", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }
    const pairing = await store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });
    const claimed = await store.claimPairing(pairing.pairingCode, "iPhone");

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

    const bootstrap = await store.getBootstrap(claimed.clientToken);
    expect(bootstrap.status.selectedWindowId).toBeNull();
    expect(bootstrap.status.directUrl).toBeNull();
    expect(bootstrap.status.codex.threadId).toBe("thread_1");
  });

  it("accepts window updates when nullable fields are omitted on the wire", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }

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

  it("generates a pairing URL with only the pairing code", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }

    const pairing = await store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://192.168.0.115:5173",
    });

    const url = new URL(pairing.pairingUrl);
    expect(url.searchParams.get("code")).toBe(pairing.pairingCode);
    expect(url.searchParams.has("api")).toBe(false);
  });

  it("keeps the latest client socket attached when an older socket closes", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }
    const pairing = await store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });
    const claimed = await store.claimPairing(pairing.pairingCode, "iPhone");

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

  it("keeps the latest host socket attached when an older socket closes", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }

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

  it("bootstraps offline host status after the host socket disconnects", async () => {
    const store = new MemoryBrokerStore();
    const registration = await store.registerDevice({
      name: "Tim's MacBook",
      mode: "hosted",
    });
    if ("approvalRequired" in registration) {
      throw new Error("Expected approved registration");
    }
    const pairing = await store.createPairing({
      deviceId: registration.device.id,
      deviceSecret: registration.deviceSecret,
      publicPairBaseUrl: "http://localhost:5173",
    });
    const claimed = await store.claimPairing(pairing.pairingCode, "iPhone");

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

    const bootstrap = await store.getBootstrap(claimed.clientToken);
    expect(bootstrap.status.online).toBe(false);
    expect(bootstrap.status.selectedWindowId).toBeNull();
    expect(bootstrap.status.codex.threadId).toBe("thread_1");
  });
});
