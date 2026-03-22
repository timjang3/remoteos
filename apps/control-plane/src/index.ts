import Fastify from "fastify";
import cors from "@fastify/cors";
import websocket from "@fastify/websocket";

import { loadConfig } from "./config.js";
import { registerRoutes } from "./routes.js";
import { MemoryBrokerStore } from "./store.js";
import { registerWsBroker } from "./wsBroker.js";

const config = loadConfig();
const app = Fastify({
  logger: true
});
const store = new MemoryBrokerStore();

await app.register(cors, {
  origin: true
});
await app.register(websocket);

await registerRoutes(app, store, config);
await registerWsBroker(app, store);

try {
  await app.listen({
    host: config.host,
    port: config.port
  });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
