import type {
  Device,
  PairingSession
} from "@remoteos/contracts";
import { and, eq, gt } from "drizzle-orm";
import { nanoid } from "nanoid";

import { BrokerCredentialHasher } from "./credentialHasher.js";
import type { ControlPlaneDb } from "./db/index.js";
import {
  clientSessions,
  deviceEnrollments,
  devices,
  pairings
} from "./db/index.js";
import type {
  BrokerStore,
  ClientSession,
  DeviceEnrollment,
  DeviceRegistrationResult,
  PendingDeviceRegistration,
  PersistedDevice,
  PersistedRuntimeDevice
} from "./storeInterface.js";
import { BrokerRuntimeState } from "./storeRuntime.js";

type DeviceRow = typeof devices.$inferSelect;
type PairingRow = typeof pairings.$inferSelect;
type ClientSessionRow = typeof clientSessions.$inferSelect;
type DeviceEnrollmentRow = typeof deviceEnrollments.$inferSelect;

function serializeDate(value: Date | null) {
  return value ? value.toISOString() : null;
}

export class PostgresBrokerStore extends BrokerRuntimeState implements BrokerStore {
  private readonly credentialHasher: BrokerCredentialHasher;

  constructor(
    private readonly db: ControlPlaneDb,
    private readonly publicEnrollmentBaseUrl: string,
    tokenHashSecret: string
  ) {
    super();
    this.credentialHasher = new BrokerCredentialHasher(tokenHashSecret);
  }

  private deviceFromRow(row: DeviceRow): PersistedRuntimeDevice {
    return {
      device: {
        id: row.id,
        name: row.name,
        mode: row.mode,
        online: false,
        registeredAt: row.registeredAt.toISOString(),
        lastSeenAt: serializeDate(row.lastSeenAt)
      },
      deviceSecretHash: row.deviceSecretHash,
      userId: row.userId
    };
  }

  private pairingFromRow(row: PairingRow, pairingCode: string): PairingSession {
    return {
      id: row.id,
      deviceId: row.deviceId,
      pairingCode,
      claimed: row.claimed,
      createdAt: row.createdAt.toISOString(),
      expiresAt: row.expiresAt.toISOString(),
      pairingUrl: this.buildPairingUrl(row.pairingBaseUrl, pairingCode)
    };
  }

  private clientSessionFromRow(row: ClientSessionRow, userId: string | null, token: string): ClientSession {
    return {
      id: row.id,
      token,
      deviceId: row.deviceId,
      name: row.name,
      userId
    };
  }

  private enrollmentFromRow(row: DeviceEnrollmentRow, token: string, deviceRow?: DeviceRow): DeviceEnrollment {
    const runtimeDevice = this.devices.get(row.deviceId)?.device;
    return {
      id: row.id,
      token,
      deviceId: row.deviceId,
      deviceName: deviceRow?.name ?? runtimeDevice?.name ?? "Unknown Mac",
      deviceMode: deviceRow?.mode ?? runtimeDevice?.mode ?? "hosted",
      status:
        row.status === "pending" && row.expiresAt.getTime() <= Date.now()
          ? "expired"
          : row.status,
      enrollmentUrl: super.buildEnrollmentUrl(this.publicEnrollmentBaseUrl, token),
      expiresAt: row.expiresAt.toISOString(),
      createdAt: row.createdAt.toISOString(),
      approvedAt: serializeDate(row.approvedAt),
      approvedByUserId: row.approvedByUserId
    };
  }

  private async loadDeviceRow(deviceId: string) {
    const [row] = await this.db
      .select()
      .from(devices)
      .where(eq(devices.id, deviceId))
      .limit(1);

    return row;
  }

  private async loadEnrollmentRow(token: string) {
    const tokenHash = this.credentialHasher.hash("enrollment_token", token);
    const [row] = await this.db
      .select()
      .from(deviceEnrollments)
      .where(eq(deviceEnrollments.tokenHash, tokenHash))
      .limit(1);

    return row;
  }

  private hydrateDevice(row: DeviceRow) {
    const persisted = this.deviceFromRow(row);
    this.ensureRuntimeDevice(persisted);
    return persisted;
  }

  private assertOwnedDevice(row: DeviceRow | undefined, userId?: string | null) {
    if (!row) {
      throw new Error("Unknown device");
    }
    if (userId && row.userId && row.userId !== userId) {
      throw new Error("Unauthorized device");
    }
  }

  private async createEnrollment(
    deviceRow: DeviceRow,
    publicEnrollmentBaseUrl: string,
    deviceSecret: string
  ): Promise<PendingDeviceRegistration> {
    await this.db
      .update(deviceEnrollments)
      .set({
        status: "expired"
      })
      .where(
        and(
          eq(deviceEnrollments.deviceId, deviceRow.id),
          eq(deviceEnrollments.status, "pending")
        )
      );

    const token = nanoid(32);
    const [enrollment] = await this.db
      .insert(deviceEnrollments)
      .values({
        id: nanoid(),
        deviceId: deviceRow.id,
        tokenHash: this.credentialHasher.hash("enrollment_token", token),
        status: "pending",
        expiresAt: new Date(Date.now() + 1000 * 60 * 15),
        createdAt: new Date(),
        approvedAt: null,
        approvedByUserId: null
      })
      .returning();

    if (!enrollment) {
      throw new Error("Failed to create enrollment");
    }

    return {
      approvalRequired: true,
      deviceId: deviceRow.id,
      deviceSecret,
      enrollmentUrl: this.buildEnrollmentUrl(publicEnrollmentBaseUrl, token),
      enrollmentToken: token,
      expiresAt: enrollment.expiresAt.toISOString()
    };
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
      const existing = await this.loadDeviceRow(input.existingDeviceId);
      if (
        !input.existingDeviceSecret
        || !existing
        || !this.credentialHasher.verify("device_secret", input.existingDeviceSecret, existing.deviceSecretHash)
      ) {
        throw new Error("Unauthorized device");
      }

      this.assertOwnedDevice(existing, input.userId);

      const [updated] = await this.db
        .update(devices)
        .set({
          name: input.name,
          mode: input.mode,
          userId: input.userId ?? existing.userId
        })
        .where(eq(devices.id, existing.id))
        .returning();

      const finalRow = updated ?? existing;
      const persisted = this.hydrateDevice(finalRow);
      if (input.publicEnrollmentBaseUrl && !finalRow.userId) {
        return this.createEnrollment(finalRow, input.publicEnrollmentBaseUrl, input.existingDeviceSecret);
      }
      return {
        device: persisted.device,
        deviceSecret: input.existingDeviceSecret
      };
    }

    if (input.existingDeviceSecret) {
      throw new Error("Unauthorized device");
    }

    const deviceSecret = nanoid(24);
    const now = new Date();
    const [inserted] = await this.db
      .insert(devices)
      .values({
        id: nanoid(),
        userId: input.userId ?? null,
        name: input.name,
        mode: input.mode,
        deviceSecretHash: this.credentialHasher.hash("device_secret", deviceSecret),
        registeredAt: now,
        lastSeenAt: null
      })
      .returning();

    if (!inserted) {
      throw new Error("Failed to persist device");
    }

    const persisted = this.hydrateDevice(inserted);
    if (input.publicEnrollmentBaseUrl) {
      return this.createEnrollment(inserted, input.publicEnrollmentBaseUrl, deviceSecret);
    }
    return {
      device: persisted.device,
      deviceSecret
    };
  }

  async getEnrollment(token: string) {
    const row = await this.loadEnrollmentRow(token);
    if (!row) {
      return undefined;
    }

    const deviceRow = await this.loadDeviceRow(row.deviceId);
    if (!deviceRow) {
      return undefined;
    }

    if (row.status === "pending" && row.expiresAt.getTime() <= Date.now()) {
      const [expired] = await this.db
        .update(deviceEnrollments)
        .set({
          status: "expired"
        })
        .where(eq(deviceEnrollments.id, row.id))
        .returning();

      return this.enrollmentFromRow(expired ?? row, token, deviceRow);
    }

    this.hydrateDevice(deviceRow);
    return this.enrollmentFromRow(row, token, deviceRow);
  }

  async approveEnrollment(token: string, userId: string) {
    return this.db.transaction(async (tx) => {
      const [record] = await tx
        .select({
          enrollment: deviceEnrollments,
          device: devices
        })
        .from(deviceEnrollments)
        .innerJoin(devices, eq(deviceEnrollments.deviceId, devices.id))
        .where(eq(deviceEnrollments.tokenHash, this.credentialHasher.hash("enrollment_token", token)))
        .limit(1);

      if (!record) {
        throw new Error("Enrollment token not found");
      }

      if (record.enrollment.status === "pending" && record.enrollment.expiresAt.getTime() <= Date.now()) {
        const [expired] = await tx
          .update(deviceEnrollments)
          .set({
            status: "expired"
          })
          .where(eq(deviceEnrollments.id, record.enrollment.id))
          .returning();

        throw new Error((expired ?? record.enrollment).status === "expired" ? "Enrollment token expired" : "Enrollment token invalid");
      }

      if (record.enrollment.status === "approved") {
        if (record.enrollment.approvedByUserId !== userId) {
          throw new Error("Enrollment token already approved");
        }
        this.hydrateDevice(record.device);
        return this.enrollmentFromRow(record.enrollment, token, record.device);
      }

      if (record.enrollment.status === "expired") {
        throw new Error("Enrollment token expired");
      }

      if (record.device.userId && record.device.userId !== userId) {
        throw new Error("Device already belongs to another user");
      }

      const [updatedDevice] = await tx
        .update(devices)
        .set({
          userId
        })
        .where(eq(devices.id, record.device.id))
        .returning();

      const [updatedEnrollment] = await tx
        .update(deviceEnrollments)
        .set({
          status: "approved",
          approvedAt: new Date(),
          approvedByUserId: userId
        })
        .where(eq(deviceEnrollments.id, record.enrollment.id))
        .returning();

      await tx
        .update(deviceEnrollments)
        .set({
          status: "expired"
        })
        .where(
          and(
            eq(deviceEnrollments.deviceId, record.device.id),
            eq(deviceEnrollments.status, "pending")
          )
        );

      const deviceRow = updatedDevice ?? record.device;
      const enrollmentRow = updatedEnrollment ?? record.enrollment;
      this.hydrateDevice(deviceRow);
      return this.enrollmentFromRow(enrollmentRow, token, deviceRow);
    });
  }

  async getPersistedDevice(deviceId: string) {
    const row = await this.loadDeviceRow(deviceId);
    if (!row) {
      return undefined;
    }
    return this.hydrateDevice(row);
  }

  async authenticateHostDevice(deviceId: string, deviceSecret: string) {
    const row = await this.loadDeviceRow(deviceId);
    if (
      !row
      || !this.credentialHasher.verify("device_secret", deviceSecret, row.deviceSecretHash)
    ) {
      return undefined;
    }

    const hydrated = this.hydrateDevice(row);
    return {
      device: hydrated.device,
      userId: hydrated.userId
    };
  }

  async createPairing(input: {
    deviceId: string;
    deviceSecret: string;
    publicPairBaseUrl: string;
    userId?: string | null;
    requireOwnership?: boolean;
  }) {
    const row = await this.loadDeviceRow(input.deviceId);
    if (
      !row
      || !this.credentialHasher.verify("device_secret", input.deviceSecret, row.deviceSecretHash)
    ) {
      throw new Error("Unauthorized device");
    }
    if (input.requireOwnership && !row.userId) {
      throw new Error("Device approval required");
    }
    this.assertOwnedDevice(row, input.userId);
    this.hydrateDevice(row);

    const pairingCode = this.pairingCode();
    const [created] = await this.db
      .insert(pairings)
      .values({
        id: nanoid(),
        deviceId: row.id,
        pairingCodeHash: this.credentialHasher.hash("pairing_code", pairingCode),
        claimed: false,
        clientTokenHash: null,
        clientName: null,
        expiresAt: new Date(Date.now() + 1000 * 60 * 15),
        createdAt: new Date(),
        pairingBaseUrl: input.publicPairBaseUrl
      })
      .returning();

    if (!created) {
      throw new Error("Failed to create pairing");
    }

    return this.pairingFromRow(created, pairingCode);
  }

  async claimPairing(pairingCode: string, clientName: string, userId?: string | null) {
    const pairingCodeHash = this.credentialHasher.hash("pairing_code", pairingCode);
    const result = await this.db.transaction(async (tx) => {
      const [pairingRecord] = await tx
        .select({
          pairing: pairings,
          device: devices
        })
        .from(pairings)
        .innerJoin(devices, eq(pairings.deviceId, devices.id))
        .where(eq(pairings.pairingCodeHash, pairingCodeHash))
        .limit(1);

      if (!pairingRecord) {
        throw new Error("Pairing code not found");
      }
      if (pairingRecord.pairing.claimed) {
        throw new Error("Pairing code already used");
      }
      if (pairingRecord.pairing.expiresAt.getTime() <= Date.now()) {
        throw new Error("Pairing code expired");
      }
      if (userId && pairingRecord.device.userId && pairingRecord.device.userId !== userId) {
        throw new Error("Unauthorized pairing");
      }

      const clientToken = nanoid(28);
      const clientTokenHash = this.credentialHasher.hash("client_token", clientToken);
      const [updatedPairing] = await tx
        .update(pairings)
        .set({
          claimed: true,
          clientTokenHash,
          clientName
        })
        .where(
          and(
            eq(pairings.id, pairingRecord.pairing.id),
            eq(pairings.claimed, false),
            gt(pairings.expiresAt, new Date())
          )
        )
        .returning();

      if (!updatedPairing) {
        throw new Error("Pairing code already used");
      }

      const [sessionRow] = await tx
        .insert(clientSessions)
        .values({
          id: nanoid(),
          tokenHash: clientTokenHash,
          deviceId: pairingRecord.pairing.deviceId,
          name: clientName,
          createdAt: new Date()
        })
        .returning();

      if (!sessionRow) {
        throw new Error("Failed to create client session");
      }

      return {
        pairing: updatedPairing,
        session: sessionRow,
        device: pairingRecord.device,
        clientToken
      };
    });

    this.hydrateDevice(result.device);
    this.cacheClientSession(this.clientSessionFromRow(result.session, result.device.userId, result.clientToken));

    return {
      pairing: this.pairingFromRow(result.pairing, pairingCode),
      clientToken: result.clientToken
    };
  }

  async getClientSession(token: string) {
    const cached = this.clientSessions.get(token);
    if (cached) {
      return cached;
    }

    const [row] = await this.db
      .select({
        session: clientSessions,
        device: devices
      })
      .from(clientSessions)
      .innerJoin(devices, eq(clientSessions.deviceId, devices.id))
      .where(eq(clientSessions.tokenHash, this.credentialHasher.hash("client_token", token)))
      .limit(1);

    if (!row) {
      return undefined;
    }

    this.hydrateDevice(row.device);
    return this.cacheClientSession(this.clientSessionFromRow(row.session, row.device.userId, token));
  }

  async getBootstrap(token: string, userId?: string | null) {
    const session = await this.getClientSession(token);
    if (!session) {
      throw new Error("Unknown client");
    }
    if (userId && session.userId && session.userId !== userId) {
      throw new Error("Unauthorized client");
    }
    if (!this.getDevice(session.deviceId)) {
      const row = await this.loadDeviceRow(session.deviceId);
      if (!row) {
        throw new Error("Unknown device");
      }
      this.hydrateDevice(row);
    }

    return this.buildBootstrap(token);
  }
}
