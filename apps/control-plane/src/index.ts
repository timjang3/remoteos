import "dotenv/config";

import Fastify from "fastify";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import rateLimit from "@fastify/rate-limit";
import websocket from "@fastify/websocket";
import { fileURLToPath } from "node:url";
import { migrate } from "drizzle-orm/postgres-js/migrator";

import { createAuth } from "./auth.js";
import { requireAuth } from "./authMiddleware.js";
import { registerAuthRoutes } from "./authRoutes.js";
import { loadConfig } from "./config.js";
import { createDb } from "./db/index.js";
import { PostgresBrokerStore } from "./postgresStore.js";
import { registerRoutes } from "./routes.js";
import { createSpeechTranscriptionProvider } from "./speech.js";
import { MemoryBrokerStore } from "./store.js";
import { registerWsBroker } from "./wsBroker.js";
import { WsTicketStore } from "./wsTicketStore.js";

const config = loadConfig();
const app = Fastify({
  logger: true,
  trustProxy: config.trustProxy
});
const wsTickets = new WsTicketStore();
const db = config.databaseUrl ? createDb(config.databaseUrl) : null;
const store = db
  ? new PostgresBrokerStore(db, config.publicPairBaseUrl, config.tokenHashSecret!)
  : new MemoryBrokerStore();
const auth = config.authMode === "required" && db ? createAuth(db, config) : null;
const authMiddleware = auth ? requireAuth(auth) : undefined;
const speechProvider = createSpeechTranscriptionProvider(config);

await app.register(cors, {
  origin: config.authMode === "required" ? config.allowedOrigins : true,
  credentials: true
});
await app.register(multipart, {
  limits: {
    files: 1,
    fileSize: config.speech.maxUploadBytes
  }
});
await app.register(rateLimit);
await app.register(websocket);

app.setErrorHandler((error: Error & { statusCode?: number }, request, reply) => {
  const statusCode = error.statusCode ?? 500;
  request.log.error(
    { err: error, url: request.url, method: request.method },
    `Unhandled route error: ${error.message}`
  );
  reply.code(statusCode).send({
    error: statusCode >= 500 ? "Internal Server Error" : error.message,
    message: error.message,
    statusCode
  });
});

if (db) {
  await migrate(db, {
    migrationsFolder: fileURLToPath(new URL("../drizzle", import.meta.url))
  });
}

if (auth) {
  await registerAuthRoutes(app, auth, config);
}
await registerRoutes(app, {
  store,
  config,
  ...(authMiddleware ? { requireAuth: authMiddleware } : {}),
  wsTickets,
  speechProvider
});
await registerWsBroker(app, {
  store,
  authMode: config.authMode,
  wsTickets
});

try {
  await app.listen({
    host: config.host,
    port: config.port
  });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
