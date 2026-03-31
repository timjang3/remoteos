import type {
  Device,
  PairingSession,
} from "@remoteos/contracts";
import { nanoid } from "nanoid";

import type {
  BrokerStore,
  ClientSession,
  DeviceEnrollment,
  DeviceRegistrationResult
} from "./storeInterface.js";
import { createMemoryCredentialHasher } from "./credentialHasher.js";
import { BrokerRuntimeState } from "./storeRuntime.js";

type PairingRecord = PairingSession & {
  clientToken?: string;
  clientName?: string;
};

export class MemoryBrokerStore extends BrokerRuntimeState implements BrokerStore {
  private readonly credentialHasher = createMemoryCredentialHasher();

  private readonly pairingsByCode = new Map<string, PairingRecord>();

  private readonly pairingsById = new Map<string, PairingRecord>();

  private readonly enrollmentsByToken = new Map<string, DeviceEnrollment>();

  private readonly enrollmentsById = new Map<string, DeviceEnrollment>();

  private serializeEnrollment(record: DeviceEnrollment) {
    const device = this.devices.get(record.deviceId);
    if (device) {
      record.deviceName = device.device.name;
      record.deviceMode = device.device.mode;
    }
    if (record.status === "pending" && new Date(record.expiresAt).getTime() <= Date.now()) {
      record.status = "expired";
    }
    return record;
  }

  private createEnrollment(
    deviceId: string,
    publicEnrollmentBaseUrl: string
  ): DeviceEnrollment {
    const device = this.devices.get(deviceId);
    if (!device) {
      throw new Error("Unknown device");
    }

    for (const enrollment of this.enrollmentsById.values()) {
      if (enrollment.deviceId === deviceId && enrollment.status === "pending") {
        enrollment.status = "expired";
      }
    }

    const token = nanoid(32);
    const expiresAt = new Date(Date.now() + 1000 * 60 * 15).toISOString();
    const enrollmentUrl = this.buildEnrollmentUrl(publicEnrollmentBaseUrl, token);
    const enrollment: DeviceEnrollment = {
      id: nanoid(),
      token,
      deviceId,
      deviceName: device.device.name,
      deviceMode: device.device.mode,
      status: "pending",
      enrollmentUrl,
      expiresAt,
      createdAt: new Date().toISOString(),
      approvedAt: null,
      approvedByUserId: null
    };

    this.enrollmentsByToken.set(token, enrollment);
    this.enrollmentsById.set(enrollment.id, enrollment);
    return enrollment;
  }

  async registerDevice(input: {
    name: string;
    mode: Device["mode"];
    existingDeviceId?: string;
    existingDeviceSecret?: string;
    userId?: string | null;
    publicEnrollmentBaseUrl?: string;
  }): Promise<DeviceRegistrationResult> {
    if (input.existingDeviceId) {
      const existing = this.devices.get(input.existingDeviceId);

      if (
        !input.existingDeviceSecret
        || !existing
        || !this.credentialHasher.verify("device_secret", input.existingDeviceSecret, existing.deviceSecretHash)
      ) {
        throw new Error("Unauthorized device");
      }

      if (input.userId && existing.userId && existing.userId !== input.userId) {
        throw new Error("Unauthorized device");
      }
      existing.device = {
        ...existing.device,
        name: input.name,
        mode: input.mode
      };
      existing.userId = input.userId ?? existing.userId;
      if (input.publicEnrollmentBaseUrl && !existing.userId) {
        const enrollment = this.createEnrollment(existing.device.id, input.publicEnrollmentBaseUrl);
        return {
          approvalRequired: true,
          deviceId: existing.device.id,
          deviceSecret: input.existingDeviceSecret,
          enrollmentUrl: enrollment.enrollmentUrl,
          enrollmentToken: enrollment.token,
          expiresAt: enrollment.expiresAt
        };
      }
      return {
        device: existing.device,
        deviceSecret: input.existingDeviceSecret
      };
    }

    if (input.existingDeviceSecret) {
      throw new Error("Unauthorized device");
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

    this.ensureRuntimeDevice({
      device,
      deviceSecretHash: this.credentialHasher.hash("device_secret", deviceSecret),
      userId: input.userId ?? null
    });

    if (input.publicEnrollmentBaseUrl) {
      const enrollment = this.createEnrollment(id, input.publicEnrollmentBaseUrl);
      return {
        approvalRequired: true,
        deviceId: id,
        deviceSecret,
        enrollmentUrl: enrollment.enrollmentUrl,
        enrollmentToken: enrollment.token,
        expiresAt: enrollment.expiresAt
      };
    }

    return {
      device,
      deviceSecret
    };
  }

  async getEnrollment(token: string) {
    const enrollment = this.enrollmentsByToken.get(token);
    if (!enrollment) {
      return undefined;
    }

    return this.serializeEnrollment(enrollment);
  }

  async approveEnrollment(token: string, userId: string) {
    const enrollment = this.enrollmentsByToken.get(token);
    if (!enrollment) {
      throw new Error("Enrollment token not found");
    }
    this.serializeEnrollment(enrollment);

    if (enrollment.status === "expired") {
      throw new Error("Enrollment token expired");
    }
    if (enrollment.status === "approved") {
      if (enrollment.approvedByUserId !== userId) {
        throw new Error("Enrollment token already approved");
      }
      return enrollment;
    }

    const device = this.devices.get(enrollment.deviceId);
    if (!device) {
      throw new Error("Unknown device");
    }
    if (device.userId && device.userId !== userId) {
      throw new Error("Device already belongs to another user");
    }

    device.userId = userId;
    enrollment.status = "approved";
    enrollment.approvedAt = new Date().toISOString();
    enrollment.approvedByUserId = userId;

    for (const other of this.enrollmentsById.values()) {
      if (other.deviceId === enrollment.deviceId && other.id !== enrollment.id && other.status === "pending") {
        other.status = "expired";
      }
    }

    return enrollment;
  }

  async getPersistedDevice(deviceId: string) {
    const device = this.devices.get(deviceId);
    if (!device) {
      return undefined;
    }

    return {
      device: device.device,
      userId: device.userId
    };
  }

  async authenticateHostDevice(deviceId: string, deviceSecret: string) {
    const device = this.devices.get(deviceId);
    if (
      !device
      || !this.credentialHasher.verify("device_secret", deviceSecret, device.deviceSecretHash)
    ) {
      return undefined;
    }

    return {
      device: device.device,
      userId: device.userId
    };
  }

  async createPairing(input: {
    deviceId: string;
    deviceSecret: string;
    publicPairBaseUrl: string;
    publicHttpBaseUrl: string;
    userId?: string | null;
    requireOwnership?: boolean;
  }) {
    const record = this.devices.get(input.deviceId);
    if (
      !record
      || !this.credentialHasher.verify("device_secret", input.deviceSecret, record.deviceSecretHash)
    ) {
      throw new Error("Unauthorized device");
    }
    if (input.requireOwnership && !record.userId) {
      throw new Error("Device approval required");
    }
    if (input.userId && record.userId && record.userId !== input.userId) {
      throw new Error("Unauthorized device");
    }

    const pairingCode = this.pairingCode();

    const session: PairingRecord = {
      id: nanoid(),
      deviceId: record.device.id,
      pairingCode,
      claimed: false,
      createdAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 1000 * 60 * 15).toISOString(),
      pairingUrl: this.buildPairingUrl(
        input.publicPairBaseUrl,
        input.publicHttpBaseUrl,
        pairingCode
      )
    };
    this.pairingsByCode.set(session.pairingCode, session);
    this.pairingsById.set(session.id, session);
    return session;
  }

  async claimPairing(pairingCode: string, clientName: string, userId?: string | null) {
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

    const device = this.devices.get(pairing.deviceId);
    if (!device) {
      throw new Error("Unknown device");
    }
    if (userId && device.userId && device.userId !== userId) {
      throw new Error("Unauthorized pairing");
    }

    const clientToken = nanoid(28);
    pairing.claimed = true;
    pairing.clientToken = clientToken;
    pairing.clientName = clientName;

    const clientSession: ClientSession = {
      id: nanoid(),
      token: clientToken,
      deviceId: pairing.deviceId,
      name: clientName,
      userId: userId ?? device.userId
    };
    this.cacheClientSession(clientSession);

    return {
      pairing,
      clientToken
    };
  }

  async getClientSession(token: string) {
    return this.clientSessions.get(token);
  }

  async getBootstrap(token: string, userId?: string | null) {
    const session = this.clientSessions.get(token);
    if (!session) {
      throw new Error("Unknown client");
    }
    if (userId && session.userId && session.userId !== userId) {
      throw new Error("Unauthorized client");
    }

    return this.buildBootstrap(token);
  }
}
