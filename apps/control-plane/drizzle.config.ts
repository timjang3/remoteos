import "dotenv/config";

import { defineConfig } from "drizzle-kit";

if (!process.env.DATABASE_URL) {
  throw new Error("DATABASE_URL is required to run Drizzle");
}

export default defineConfig({
  out: "./drizzle",
  schema: ["./src/db/schema.ts", "./src/db/authSchema.ts"],
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL
  }
});
