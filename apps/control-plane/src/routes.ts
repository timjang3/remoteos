import type { FastifyInstance } from "fastify";

import { z } from "zod";

import type { MemoryBrokerStore } from "./store.js";
import type { ControlPlaneConfig } from "./config.js";

const registerDeviceBodySchema = z.object({
  name: z.string().min(1),
  mode: z.enum(["hosted", "direct"]).default("hosted"),
  existingDeviceId: z.string().min(1).optional(),
  existingDeviceSecret: z.string().min(1).optional()
});

const createPairingBodySchema = z.object({
  deviceId: z.string().min(1),
  deviceSecret: z.string().min(1)
});

const claimPairingBodySchema = z.object({
  clientName: z.string().min(1).default("Phone")
});

export async function registerRoutes(
  app: FastifyInstance,
  store: MemoryBrokerStore,
  config: ControlPlaneConfig
) {
  app.get("/health", async () => ({
    ok: true,
    now: new Date().toISOString()
  }));

  app.post("/devices/register", async (request, reply) => {
    const body = registerDeviceBodySchema.parse(request.body);
    const registration = store.registerDevice({
      name: body.name,
      mode: body.mode,
      ...(body.existingDeviceId ? { existingDeviceId: body.existingDeviceId } : {}),
      ...(body.existingDeviceSecret ? { existingDeviceSecret: body.existingDeviceSecret } : {})
    });
    return reply.send({
      device: registration.device,
      deviceSecret: registration.deviceSecret,
      wsUrl: `${config.publicWsBaseUrl}/ws/host?deviceId=${registration.device.id}&deviceSecret=${registration.deviceSecret}`
    });
  });

  app.post("/pairings", async (request, reply) => {
    const body = createPairingBodySchema.parse(request.body);
    try {
      const pairing = store.createPairing({
        deviceId: body.deviceId,
        deviceSecret: body.deviceSecret,
        publicPairBaseUrl: config.publicPairBaseUrl
      });
      return reply.send(pairing);
    } catch (error) {
      return reply.code(401).send({
        error: error instanceof Error ? error.message : "Failed to create pairing"
      });
    }
  });

  app.post("/pairings/:code/claim", async (request, reply) => {
    const code = z.string().min(6).max(12).parse((request.params as { code?: string }).code);
    const body = claimPairingBodySchema.parse(request.body);
    try {
      const result = store.claimPairing(code, body.clientName);
      return reply.send({
        pairing: result.pairing,
        clientToken: result.clientToken,
        wsUrl: `${config.publicWsBaseUrl}/ws/client?clientToken=${result.clientToken}`
      });
    } catch (error) {
      return reply.code(400).send({
        error: error instanceof Error ? error.message : "Failed to claim pairing"
      });
    }
  });

  app.get("/bootstrap", async (request, reply) => {
    const token = z.string().min(1).parse((request.query as { clientToken?: string }).clientToken);

    try {
      return reply.send(store.getBootstrap(token, config.publicWsBaseUrl));
    } catch (error) {
      return reply.code(401).send({
        error: error instanceof Error ? error.message : "Unknown client token"
      });
    }
  });
}
