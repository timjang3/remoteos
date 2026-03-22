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
    deviceSecret: text("device_secret").notNull(),
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
    uniqueIndex("devices_device_secret_idx").on(table.deviceSecret)
  ]
);

export const clientSessions = pgTable(
  "client_sessions",
  {
    id: text("id").primaryKey(),
    token: text("token").notNull(),
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
    uniqueIndex("client_sessions_token_idx").on(table.token),
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
    pairingCode: text("pairing_code").notNull(),
    claimed: boolean("claimed").notNull(),
    clientToken: text("client_token"),
    clientName: text("client_name"),
    expiresAt: timestamp("expires_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    createdAt: timestamp("created_at", {
      mode: "date",
      withTimezone: true
    }).notNull(),
    pairingUrl: text("pairing_url").notNull()
  },
  (table) => [
    uniqueIndex("pairings_pairing_code_idx").on(table.pairingCode),
    index("pairings_device_id_idx").on(table.deviceId),
    index("pairings_client_token_idx").on(table.clientToken)
  ]
);

export const deviceEnrollments = pgTable(
  "device_enrollments",
  {
    id: text("id").primaryKey(),
    deviceId: text("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    token: text("token").notNull(),
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
    uniqueIndex("device_enrollments_token_idx").on(table.token),
    index("device_enrollments_device_id_idx").on(table.deviceId),
    index("device_enrollments_approved_by_user_id_idx").on(table.approvedByUserId)
  ]
);
