import type {
  Device,
  PairingSession,
  WindowDescriptor
} from "@remoteos/contracts";
import { hostStatusSchema } from "@remoteos/contracts";
import type WebSocket from "ws";
import { z } from "zod";

export type HostStatus = z.infer<typeof hostStatusSchema>;

export type DeviceRegistration = {
  device: Device;
  deviceSecret: string;
};

export type DeviceEnrollmentStatus = "pending" | "approved" | "expired";

export type DeviceEnrollment = {
  id: string;
  token: string;
  deviceId: string;
  deviceName: string;
  deviceMode: Device["mode"];
  status: DeviceEnrollmentStatus;
  enrollmentUrl: string;
  expiresAt: string;
  createdAt: string;
  approvedAt: string | null;
  approvedByUserId: string | null;
};

export type PendingDeviceRegistration = {
  approvalRequired: true;
  deviceId: string;
  deviceSecret: string;
  enrollmentUrl: string;
  enrollmentToken: string;
  expiresAt: string;
};

export type DeviceRegistrationResult = DeviceRegistration | PendingDeviceRegistration;

export type PersistedDevice = {
  device: Device;
  userId: string | null;
};

export type PersistedRuntimeDevice = PersistedDevice & {
  deviceSecretHash: string;
};

export type ClientSession = {
  id: string;
  token: string;
  deviceId: string;
  name: string;
  userId: string | null;
};

export type ClientRuntimeRecord = ClientSession & {
  socket: WebSocket | undefined;
};

export type DeviceRuntimeRecord = PersistedRuntimeDevice & {
  hostSocket: WebSocket | undefined;
  status: HostStatus | undefined;
  windows: WindowDescriptor[];
  clients: Map<string, ClientRuntimeRecord>;
};

export type BrokerBootstrap = {
  client: ClientSession;
  device: Device;
  windows: WindowDescriptor[];
  status: HostStatus;
};

export interface BrokerStore {
  registerDevice(input: {
    name: string;
    mode: Device["mode"];
    existingDeviceId?: string;
    existingDeviceSecret?: string;
    userId?: string | null;
    publicEnrollmentBaseUrl?: string;
  }): Promise<DeviceRegistrationResult>;
  getEnrollment(token: string): Promise<DeviceEnrollment | undefined>;
  approveEnrollment(token: string, userId: string): Promise<DeviceEnrollment>;
  getPersistedDevice(deviceId: string): Promise<PersistedDevice | undefined>;
  authenticateHostDevice(deviceId: string, deviceSecret: string): Promise<PersistedDevice | undefined>;
  createPairing(input: {
    deviceId: string;
    deviceSecret: string;
    publicPairBaseUrl: string;
    userId?: string | null;
    requireOwnership?: boolean;
  }): Promise<PairingSession>;
  claimPairing(
    pairingCode: string,
    clientName: string,
    userId?: string | null
  ): Promise<{
    pairing: PairingSession;
    clientToken: string;
  }>;
  getClientSession(token: string): Promise<ClientSession | undefined>;
  getBootstrap(token: string, userId?: string | null): Promise<BrokerBootstrap>;
  getDevice(deviceId: string): DeviceRuntimeRecord | undefined;
  getCurrentHostStatus(deviceId: string): HostStatus | undefined;
  attachHost(deviceId: string, socket: WebSocket): void;
  detachHost(deviceId: string): void;
  detachHostSocket(deviceId: string, socket?: WebSocket): void;
  attachClient(
    token: string,
    socket: WebSocket
  ): {
    session: ClientSession;
    device: DeviceRuntimeRecord;
  };
  detachClient(token: string): void;
  detachClientSocket(token: string, socket?: WebSocket): void;
  updateWindows(deviceId: string, windows: unknown): void;
  updateHostStatus(deviceId: string, status: unknown): void;
  getConnectedClientSockets(deviceId: string): WebSocket[];
}
