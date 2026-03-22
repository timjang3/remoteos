import "dotenv/config";

import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { bearer } from "better-auth/plugins/bearer";

import type { ControlPlaneConfig } from "./config.js";
import { loadConfig } from "./config.js";
import type { ControlPlaneDb } from "./db/index.js";
import { createDb } from "./db/index.js";
import * as authSchema from "./db/authSchema.js";
import * as domainSchema from "./db/schema.js";

function createSocialProviders(config: ControlPlaneConfig) {
  const providers: Record<string, { clientId: string; clientSecret: string }> = {};

  if (config.googleClientId && config.googleClientSecret) {
    providers.google = {
      clientId: config.googleClientId,
      clientSecret: config.googleClientSecret
    };
  }

  return providers;
}

export function createAuth(db: ControlPlaneDb, config: ControlPlaneConfig) {
  if (!config.betterAuthSecret) {
    throw new Error("BETTER_AUTH_SECRET is required to initialize Better Auth");
  }

  return betterAuth({
    baseURL: config.publicHttpBaseUrl,
    secret: config.betterAuthSecret,
    trustedOrigins: config.allowedOrigins,
    database: drizzleAdapter(db, {
      provider: "pg",
      schema: {
        ...domainSchema,
        ...authSchema
      }
    }),
    socialProviders: createSocialProviders(config),
    session: {
      expiresIn: 60 * 60 * 24 * 30,
      updateAge: 60 * 60 * 24
    },
    plugins: [bearer()]
  });
}

export type ControlPlaneAuth = ReturnType<typeof createAuth>;

const envConfig = loadConfig(process.env);

export const auth =
  process.env.DATABASE_URL && process.env.BETTER_AUTH_SECRET
    ? createAuth(createDb(process.env.DATABASE_URL), envConfig)
    : undefined;
