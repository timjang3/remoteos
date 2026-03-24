import type { Device } from "@remoteos/contracts";
import {
  boolean,
  index,
  pgTable,
  text,
  timestamp,
  uniqueIndex
} from "drizzle-orm/pg-core";

import { user } from "./authSchema.js";

export const devices = pgTable(
  "devices",
  {
    id: text("id").primaryKey(),
    userId: text("user_id").references(() => user.id, { onDelete: "set null" }),
    name: text("name").notNull(),
    mode: text("mode").$type<Device["mode"]>().notNull(),
    deviceSecretHash: text("device_secret_hash").notNull(),
    registeredAt: timestamp("registered_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    lastSeenAt: timestamp("last_seen_at", {
      mode: "date",
      withTimezone: true
    })
  },
  (table) => [
    index("devices_user_id_idx").on(table.userId),
    uniqueIndex("devices_device_secret_hash_idx").on(table.deviceSecretHash)
  ]
);

export const clientSessions = pgTable(
  "client_sessions",
  {
    id: text("id").primaryKey(),
    tokenHash: text("token_hash").notNull(),
    deviceId: text("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    createdAt: timestamp("created_at", {
      mode: "date",
      withTimezone: true
    }).notNull()
  },
  (table) => [
    uniqueIndex("client_sessions_token_hash_idx").on(table.tokenHash),
    index("client_sessions_device_id_idx").on(table.deviceId)
  ]
);

export const pairings = pgTable(
  "pairings",
  {
    id: text("id").primaryKey(),
    deviceId: text("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    pairingCodeHash: text("pairing_code_hash").notNull(),
    claimed: boolean("claimed").notNull(),
    clientTokenHash: text("client_token_hash"),
    clientName: text("client_name"),
    expiresAt: timestamp("expires_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    createdAt: timestamp("created_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    pairingBaseUrl: text("pairing_base_url").notNull()
  },
  (table) => [
    uniqueIndex("pairings_pairing_code_hash_idx").on(table.pairingCodeHash),
    index("pairings_device_id_idx").on(table.deviceId),
    index("pairings_client_token_hash_idx").on(table.clientTokenHash)
  ]
);

export const deviceEnrollments = pgTable(
  "device_enrollments",
  {
    id: text("id").primaryKey(),
    deviceId: text("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    tokenHash: text("token_hash").notNull(),
    status: text("status").$type<"pending" | "approved" | "expired">().notNull(),
    expiresAt: timestamp("expires_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    createdAt: timestamp("created_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    approvedAt: timestamp("approved_at", {
      mode: "date",
      withTimezone: true
    }),
    approvedByUserId: text("approved_by_user_id").references(() => user.id, { onDelete: "set null" })
  },
  (table) => [
    uniqueIndex("device_enrollments_token_hash_idx").on(table.tokenHash),
    index("device_enrollments_device_id_idx").on(table.deviceId),
    index("device_enrollments_approved_by_user_id_idx").on(table.approvedByUserId)
  ]
);
