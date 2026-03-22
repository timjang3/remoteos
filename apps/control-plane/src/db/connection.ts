import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";

import * as authSchema from "./authSchema.js";
import * as schema from "./schema.js";

export function createDb(databaseUrl: string) {
  const client = postgres(databaseUrl, {
    prepare: false
  });

  return drizzle(client, {
    schema: {
      ...schema,
      ...authSchema
    }
  });
}

export type ControlPlaneDb = ReturnType<typeof createDb>;
