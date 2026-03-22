import type {
  Device,
  PairingSession
} from "@remoteos/contracts";
import { and, eq, gt } from "drizzle-orm";
import { nanoid } from "nanoid";

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
  PersistedDevice
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
  constructor(
    private readonly db: ControlPlaneDb,
    private readonly publicEnrollmentBaseUrl: string
  ) {
    super();
  }

  private deviceFromRow(row: DeviceRow): PersistedDevice {
    return {
      device: {
        id: row.id,
        name: row.name,
        mode: row.mode,
        online: false,
        registeredAt: row.registeredAt.toISOString(),
        lastSeenAt: serializeDate(row.lastSeenAt)
      },
      deviceSecret: row.deviceSecret,
      userId: row.userId
    };
  }

  private pairingFromRow(row: PairingRow): PairingSession {
    return {
      id: row.id,
      deviceId: row.deviceId,
      pairingCode: row.pairingCode,
      claimed: row.claimed,
      createdAt: row.createdAt.toISOString(),
      expiresAt: row.expiresAt.toISOString(),
      pairingUrl: row.pairingUrl
    };
  }

  private clientSessionFromRow(row: ClientSessionRow, userId: string | null): ClientSession {
    return {
      id: row.id,
      token: row.token,
      deviceId: row.deviceId,
      name: row.name,
      userId
    };
  }

  private enrollmentFromRow(row: DeviceEnrollmentRow, deviceRow?: DeviceRow): DeviceEnrollment {
    const runtimeDevice = this.devices.get(row.deviceId)?.device;
    return {
      id: row.id,
      token: row.token,
      deviceId: row.deviceId,
      deviceName: deviceRow?.name ?? runtimeDevice?.name ?? "Unknown Mac",
      deviceMode: deviceRow?.mode ?? runtimeDevice?.mode ?? "hosted",
      status:
        row.status === "pending" && row.expiresAt.getTime() <= Date.now()
          ? "expired"
          : row.status,
      enrollmentUrl: super.buildEnrollmentUrl(this.publicEnrollmentBaseUrl, row.token),
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
    const [row] = await this.db
      .select()
      .from(deviceEnrollments)
      .where(eq(deviceEnrollments.token, token))
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

  private async createEnrollment(deviceRow: DeviceRow, publicEnrollmentBaseUrl: string) {
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

    const [enrollment] = await this.db
      .insert(deviceEnrollments)
      .values({
        id: nanoid(),
        deviceId: deviceRow.id,
        token: nanoid(32),
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
      row: enrollment,
      payload: {
        approvalRequired: true as const,
        deviceId: deviceRow.id,
        deviceSecret: deviceRow.deviceSecret,
        enrollmentUrl: this.buildEnrollmentUrl(publicEnrollmentBaseUrl, enrollment.token),
        enrollmentToken: enrollment.token,
        expiresAt: enrollment.expiresAt.toISOString()
      }
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
      if (!input.existingDeviceSecret || !existing || existing.deviceSecret !== input.existingDeviceSecret) {
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
        const enrollment = await this.createEnrollment(finalRow, input.publicEnrollmentBaseUrl);
        return enrollment.payload;
      }
      return {
        device: persisted.device,
        deviceSecret: persisted.deviceSecret
      };
    }

    if (input.existingDeviceSecret) {
      throw new Error("Unauthorized device");
    }

    const now = new Date();
    const [inserted] = await this.db
      .insert(devices)
      .values({
        id: nanoid(),
        userId: input.userId ?? null,
        name: input.name,
        mode: input.mode,
        deviceSecret: nanoid(24),
        registeredAt: now,
        lastSeenAt: null
      })
      .returning();

    if (!inserted) {
      throw new Error("Failed to persist device");
    }

    const persisted = this.hydrateDevice(inserted);
    if (input.publicEnrollmentBaseUrl) {
      const enrollment = await this.createEnrollment(inserted, input.publicEnrollmentBaseUrl);
      return enrollment.payload;
    }
    return {
      device: persisted.device,
      deviceSecret: persisted.deviceSecret
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

      return this.enrollmentFromRow(expired ?? row, deviceRow);
    }

    this.hydrateDevice(deviceRow);
    return this.enrollmentFromRow(row, deviceRow);
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
        .where(eq(deviceEnrollments.token, token))
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
        return this.enrollmentFromRow(record.enrollment, record.device);
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
      return this.enrollmentFromRow(enrollmentRow, deviceRow);
    });
  }

  async getPersistedDevice(deviceId: string) {
    const row = await this.loadDeviceRow(deviceId);
    if (!row) {
      return undefined;
    }
    return this.hydrateDevice(row);
  }

  async createPairing(input: {
    deviceId: string;
    deviceSecret: string;
    publicPairBaseUrl: string;
    userId?: string | null;
    requireOwnership?: boolean;
  }) {
    const row = await this.loadDeviceRow(input.deviceId);
    if (!row || row.deviceSecret !== input.deviceSecret) {
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
        pairingCode,
        claimed: false,
        clientToken: null,
        clientName: null,
        expiresAt: new Date(Date.now() + 1000 * 60 * 15),
        createdAt: new Date(),
        pairingUrl: this.buildPairingUrl(input.publicPairBaseUrl, pairingCode)
      })
      .returning();

    if (!created) {
      throw new Error("Failed to create pairing");
    }

    return this.pairingFromRow(created);
  }

  async claimPairing(pairingCode: string, clientName: string, userId?: string | null) {
    const result = await this.db.transaction(async (tx) => {
      const [pairingRecord] = await tx
        .select({
          pairing: pairings,
          device: devices
        })
        .from(pairings)
        .innerJoin(devices, eq(pairings.deviceId, devices.id))
        .where(eq(pairings.pairingCode, pairingCode))
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
      const [updatedPairing] = await tx
        .update(pairings)
        .set({
          claimed: true,
          clientToken,
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
          token: clientToken,
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
        device: pairingRecord.device
      };
    });

    this.hydrateDevice(result.device);
    this.cacheClientSession(this.clientSessionFromRow(result.session, result.device.userId));

    return {
      pairing: this.pairingFromRow(result.pairing),
      clientToken: result.session.token
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
      .where(eq(clientSessions.token, token))
      .limit(1);

    if (!row) {
      return undefined;
    }

    this.hydrateDevice(row.device);
    return this.cacheClientSession(this.clientSessionFromRow(row.session, row.device.userId));
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
