import type {
  Device,
  PairingSession,
  WindowDescriptor
} from "@remoteos/contracts";
import { customAlphabet, nanoid } from "nanoid";
import type WebSocket from "ws";

import { hostStatusSchema, windowDescriptorSchema } from "@remoteos/contracts";
import { z } from "zod";

type HostStatus = typeof hostStatusSchema._type;

export type DeviceRegistration = {
  device: Device;
  deviceSecret: string;
};

export type ClientSession = {
  id: string;
  token: string;
  deviceId: string;
  name: string;
};

type DeviceRecord = DeviceRegistration & {
  hostSocket: WebSocket | undefined;
  status: HostStatus | undefined;
  windows: WindowDescriptor[];
  clients: Map<string, ClientSession & { socket: WebSocket | undefined }>;
};

type PairingRecord = PairingSession & {
  clientToken?: string;
  clientName?: string;
};

export class MemoryBrokerStore {
  private readonly devices = new Map<string, DeviceRecord>();

  private readonly pairingsByCode = new Map<string, PairingRecord>();

  private readonly pairingsById = new Map<string, PairingRecord>();

  private readonly clientSessions = new Map<string, ClientSession>();

  private readonly pairingCode = customAlphabet("ABCDEFGHJKLMNPQRSTUVWXYZ23456789", 6);

  private defaultHostStatus(deviceId: string, online: boolean): HostStatus {
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

  private currentHostStatus(record: DeviceRecord): HostStatus {
    const status = record.status ?? this.defaultHostStatus(record.device.id, record.device.online);

    return {
      ...status,
      deviceId: record.device.id,
      online: record.device.online,
      selectedWindowId: record.device.online ? status.selectedWindowId : null
    };
  }

  registerDevice(input: {
    name: string;
    mode: Device["mode"];
    existingDeviceId?: string;
    existingDeviceSecret?: string;
  }): DeviceRegistration {
    if (input.existingDeviceId && input.existingDeviceSecret) {
      const existing = this.devices.get(input.existingDeviceId);

      if (existing && existing.deviceSecret === input.existingDeviceSecret) {
        existing.device = {
          ...existing.device,
          name: input.name,
          mode: input.mode
        };
        return {
          device: existing.device,
          deviceSecret: existing.deviceSecret
        };
      }
    }

    const id = nanoid();
    const deviceSecret = nanoid(24);
    const now = new Date().toISOString();
    const device: Device = {
      id,
      name: input.name,
      mode: input.mode,
      online: false,
      registeredAt: now,
      lastSeenAt: null
    };

    this.devices.set(id, {
      device,
      deviceSecret,
      hostSocket: undefined,
      status: undefined,
      windows: [],
      clients: new Map()
    });

    return {
      device,
      deviceSecret
    };
  }

  getDevice(deviceId: string) {
    return this.devices.get(deviceId);
  }

  createPairing(input: {
    deviceId: string;
    deviceSecret: string;
    publicPairBaseUrl: string;
  }): PairingSession {
    const record = this.devices.get(input.deviceId);
    if (!record || record.deviceSecret !== input.deviceSecret) {
      throw new Error("Unauthorized device");
    }

    const pairingURL = new URL(input.publicPairBaseUrl);
    pairingURL.searchParams.set("code", this.pairingCode());

    const session: PairingRecord = {
      id: nanoid(),
      deviceId: record.device.id,
      pairingCode: pairingURL.searchParams.get("code")!,
      claimed: false,
      createdAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 1000 * 60 * 15).toISOString(),
      pairingUrl: pairingURL.toString()
    };
    this.pairingsByCode.set(session.pairingCode, session);
    this.pairingsById.set(session.id, session);
    return session;
  }

  claimPairing(pairingCode: string, clientName: string): {
    pairing: PairingSession;
    clientToken: string;
  } {
    const pairing = this.pairingsByCode.get(pairingCode);
    if (!pairing) {
      throw new Error("Pairing code not found");
    }
    if (pairing.claimed) {
      throw new Error("Pairing code already used");
    }
    if (new Date(pairing.expiresAt).getTime() <= Date.now()) {
      throw new Error("Pairing code expired");
    }

    const clientToken = nanoid(28);
    pairing.claimed = true;
    pairing.clientToken = clientToken;
    pairing.clientName = clientName;

    const clientSession: ClientSession = {
      id: nanoid(),
      token: clientToken,
      deviceId: pairing.deviceId,
      name: clientName
    };
    this.clientSessions.set(clientToken, clientSession);
    this.devices.get(pairing.deviceId)?.clients.set(clientSession.id, {
      ...clientSession,
      socket: undefined
    });

    return {
      pairing,
      clientToken
    };
  }

  getClientSession(token: string) {
    return this.clientSessions.get(token);
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

  getBootstrap(token: string, publicWsBaseUrl: string) {
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
      status: this.currentHostStatus(device),
      wsUrl: `${publicWsBaseUrl}/ws/client?clientToken=${token}`
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
