import type {
  Device,
  WindowDescriptor
} from "@remoteos/contracts";
import {
  hostStatusSchema,
  windowDescriptorSchema
} from "@remoteos/contracts";
import { customAlphabet } from "nanoid";
import type WebSocket from "ws";
import { z } from "zod";

import type {
  BrokerBootstrap,
  ClientSession,
  DeviceRuntimeRecord,
  HostStatus,
  PersistedRuntimeDevice
} from "./storeInterface.js";

export abstract class BrokerRuntimeState {
  protected readonly devices = new Map<string, DeviceRuntimeRecord>();

  protected readonly clientSessions = new Map<string, ClientSession>();

  protected readonly pairingCode = customAlphabet("ABCDEFGHJKLMNPQRSTUVWXYZ23456789", 6);

  protected defaultHostStatus(deviceId: string, online: boolean): HostStatus {
    return {
      deviceId,
      online,
      selectedWindowId: null,
      screenRecording: "unknown",
      accessibility: "unknown",
      directUrl: null,
      codex: {
        state: "unknown",
        installed: false,
        authenticated: false,
        authMode: null,
        model: null,
        threadId: null,
        activeTurnId: null,
        lastError: null
      }
    };
  }

  protected currentHostStatus(record: DeviceRuntimeRecord): HostStatus {
    const status = record.status ?? this.defaultHostStatus(record.device.id, record.device.online);

    return {
      ...status,
      deviceId: record.device.id,
      online: record.device.online,
      selectedWindowId: record.device.online ? status.selectedWindowId : null
    };
  }

  protected ensureRuntimeDevice(persisted: PersistedRuntimeDevice) {
    const existing = this.devices.get(persisted.device.id);
    if (existing) {
      existing.device = {
        ...persisted.device,
        online: existing.device.online,
        lastSeenAt: existing.device.lastSeenAt
      };
      existing.deviceSecretHash = persisted.deviceSecretHash;
      existing.userId = persisted.userId;
      return existing;
    }

    const record: DeviceRuntimeRecord = {
      ...persisted,
      hostSocket: undefined,
      status: undefined,
      windows: [],
      clients: new Map()
    };
    this.devices.set(record.device.id, record);
    return record;
  }

  protected cacheClientSession(session: ClientSession) {
    this.clientSessions.set(session.token, session);

    const device = this.devices.get(session.deviceId);
    if (!device) {
      return session;
    }

    const current = device.clients.get(session.id);
    device.clients.set(session.id, {
      ...session,
      socket: current?.socket
    });
    return session;
  }

  protected buildPairingUrl(
    publicPairBaseUrl: string,
    publicHttpBaseUrl: string,
    pairingCode: string
  ) {
    const pairingUrl = new URL(publicPairBaseUrl);
    pairingUrl.searchParams.set("code", pairingCode);
    pairingUrl.searchParams.set("api", publicHttpBaseUrl);
    return pairingUrl.toString();
  }

  protected buildEnrollmentUrl(publicEnrollmentBaseUrl: string, enrollmentToken: string) {
    const enrollmentUrl = new URL(publicEnrollmentBaseUrl);
    enrollmentUrl.searchParams.set("enroll", enrollmentToken);
    return enrollmentUrl.toString();
  }

  protected buildBootstrap(token: string): BrokerBootstrap {
    const session = this.clientSessions.get(token);
    if (!session) {
      throw new Error("Unknown client");
    }

    const device = this.devices.get(session.deviceId);
    if (!device) {
      throw new Error("Unknown device");
    }

    return {
      client: session,
      device: device.device,
      windows: device.windows,
      status: this.currentHostStatus(device)
    };
  }

  getDevice(deviceId: string) {
    return this.devices.get(deviceId);
  }

  getCurrentHostStatus(deviceId: string) {
    const record = this.devices.get(deviceId);
    if (!record) {
      return undefined;
    }
    return this.currentHostStatus(record);
  }

  attachHost(deviceId: string, socket: WebSocket) {
    const record = this.devices.get(deviceId);
    if (!record) {
      throw new Error("Unknown device");
    }

    if (record.hostSocket && record.hostSocket !== socket) {
      record.hostSocket.close(4000, "Replaced by a newer host session");
    }
    record.hostSocket = socket;
    record.device.online = true;
    record.device.lastSeenAt = new Date().toISOString();
    if (record.status) {
      record.status = this.currentHostStatus(record);
    }
  }

  detachHost(deviceId: string) {
    this.detachHostSocket(deviceId);
  }

  detachHostSocket(deviceId: string, socket?: WebSocket) {
    const record = this.devices.get(deviceId);
    if (!record) {
      return;
    }
    if (socket && record.hostSocket !== socket) {
      return;
    }

    record.hostSocket = undefined;
    record.device.online = false;
    record.device.lastSeenAt = new Date().toISOString();
    if (record.status) {
      record.status = this.currentHostStatus(record);
    }
  }

  attachClient(token: string, socket: WebSocket) {
    const session = this.clientSessions.get(token);
    if (!session) {
      throw new Error("Unknown client");
    }
    const device = this.devices.get(session.deviceId);
    if (!device) {
      throw new Error("Unknown device");
    }
    const current = device.clients.get(session.id);
    if (!current) {
      throw new Error("Unknown client record");
    }

    device.clients.set(session.id, {
      ...current,
      socket
    });
    return {
      session,
      device
    };
  }

  detachClient(token: string) {
    this.detachClientSocket(token);
  }

  detachClientSocket(token: string, socket?: WebSocket) {
    const session = this.clientSessions.get(token);
    if (!session) {
      return;
    }
    const device = this.devices.get(session.deviceId);
    if (!device) {
      return;
    }

    const current = device.clients.get(session.id);
    if (!current) {
      return;
    }
    if (socket && current.socket !== socket) {
      return;
    }

    device.clients.set(session.id, {
      ...current,
      socket: undefined
    });
  }

  updateWindows(deviceId: string, windows: unknown) {
    const record = this.devices.get(deviceId);
    if (!record) {
      return;
    }
    record.windows = z.array(windowDescriptorSchema).parse(windows);
  }

  updateHostStatus(deviceId: string, status: unknown) {
    const parsed = hostStatusSchema.parse(status);
    const record = this.devices.get(deviceId);
    if (!record) {
      return;
    }
    record.status = {
      ...parsed,
      deviceId: record.device.id,
      online: record.device.online
    };
  }

  getConnectedClientSockets(deviceId: string) {
    const record = this.devices.get(deviceId);
    if (!record) {
      return [];
    }
    return [...record.clients.values()]
      .map((client) => client.socket)
      .filter((socket): socket is WebSocket => Boolean(socket));
  }
}
