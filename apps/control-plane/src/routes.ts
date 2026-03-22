import type { FastifyInstance } from "fastify";

import { z } from "zod";

import type { ControlPlaneConfig } from "./config.js";
import type { BrokerStore } from "./storeInterface.js";
import type { WsTicketStore } from "./wsTicketStore.js";

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

const approveEnrollmentParamsSchema = z.object({
  token: z.string().min(1)
});

const wsTicketBodySchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("host"),
    deviceId: z.string().min(1),
    deviceSecret: z.string().min(1)
  }),
  z.object({
    type: z.literal("client"),
    clientToken: z.string().min(1)
  })
]);

function hostWsUrl(config: ControlPlaneConfig, registration: { deviceId: string; deviceSecret: string }) {
  if (config.authMode === "required") {
    return `${config.publicWsBaseUrl}/ws/host`;
  }

  return `${config.publicWsBaseUrl}/ws/host?deviceId=${registration.deviceId}&deviceSecret=${registration.deviceSecret}`;
}

function clientWsUrl(config: ControlPlaneConfig, clientToken: string) {
  if (config.authMode === "required") {
    return `${config.publicWsBaseUrl}/ws/client`;
  }

  return `${config.publicWsBaseUrl}/ws/client?clientToken=${clientToken}`;
}

function isPendingRegistration(
  registration: Awaited<ReturnType<BrokerStore["registerDevice"]>>
): registration is Extract<Awaited<ReturnType<BrokerStore["registerDevice"]>>, { approvalRequired: true }> {
  return "approvalRequired" in registration;
}

export async function registerRoutes(
  app: FastifyInstance,
  options: {
    store: BrokerStore;
    config: ControlPlaneConfig;
    requireAuth?: (request: any, reply: any) => Promise<unknown>;
    wsTickets: WsTicketStore;
  }
) {
  const {
    config,
    requireAuth,
    store,
    wsTickets
  } = options;

  app.get("/health", async () => ({
    ok: true,
    now: new Date().toISOString(),
    authMode: config.authMode,
    googleAuthEnabled: config.googleAuthEnabled
  }));

  app.post(
    "/devices/register",
    {
      config: {
        rateLimit: {
          max: 5,
          timeWindow: 60_000
        }
      }
    },
    async (request, reply) => {
      const body = registerDeviceBodySchema.parse(request.body);
      const registration = await store.registerDevice({
        name: body.name,
        mode: body.mode,
        ...(body.existingDeviceId ? { existingDeviceId: body.existingDeviceId } : {}),
        ...(body.existingDeviceSecret ? { existingDeviceSecret: body.existingDeviceSecret } : {}),
        userId: request.userId ?? null,
        ...(config.authMode === "required" ? { publicEnrollmentBaseUrl: config.publicPairBaseUrl } : {})
      });
      if (isPendingRegistration(registration)) {
        return reply.send(registration);
      }

      return reply.send({
        device: registration.device,
        deviceSecret: registration.deviceSecret,
        wsUrl: hostWsUrl(config, {
          deviceId: registration.device.id,
          deviceSecret: registration.deviceSecret
        })
      });
    }
  );

  app.post(
    "/pairings",
    {
      config: {
        rateLimit: {
          max: 10,
          timeWindow: 60_000
        }
      }
    },
    async (request, reply) => {
      const body = createPairingBodySchema.parse(request.body);
      try {
        const pairing = await store.createPairing({
          deviceId: body.deviceId,
          deviceSecret: body.deviceSecret,
          publicPairBaseUrl: config.publicPairBaseUrl,
          userId: request.userId ?? null,
          requireOwnership: config.authMode === "required"
        });
        return reply.send(pairing);
      } catch (error) {
        return reply.code(401).send({
          error: error instanceof Error ? error.message : "Failed to create pairing"
        });
      }
    }
  );

  app.post(
    "/pairings/:code/claim",
    {
      config: {
        rateLimit: {
          max: 20,
          timeWindow: 60_000
        }
      },
      ...(requireAuth ? { preHandler: requireAuth } : {})
    },
    async (request, reply) => {
      const code = z.string().min(6).max(12).parse((request.params as { code?: string }).code);
      const body = claimPairingBodySchema.parse(request.body);
      try {
        const result = await store.claimPairing(code, body.clientName, request.userId ?? null);
        return reply.send({
          pairing: result.pairing,
          clientToken: result.clientToken,
          wsUrl: clientWsUrl(config, result.clientToken)
        });
      } catch (error) {
        return reply.code(400).send({
          error: error instanceof Error ? error.message : "Failed to claim pairing"
        });
      }
    }
  );

  app.get(
    "/devices/enrollments/:token",
    async (request, reply) => {
      const { token } = approveEnrollmentParamsSchema.parse(request.params);
      const enrollment = await store.getEnrollment(token);
      if (!enrollment) {
        return reply.code(404).send({
          error: "Enrollment token not found"
        });
      }

      return reply.send(enrollment);
    }
  );

  if (config.authMode === "required" && requireAuth) {
    app.post(
      "/devices/enrollments/:token/approve",
      {
        preHandler: requireAuth
      },
      async (request, reply) => {
        const { token } = approveEnrollmentParamsSchema.parse(request.params);
        try {
          const enrollment = await store.approveEnrollment(token, request.userId!);
          return reply.send(enrollment);
        } catch (error) {
          const message = error instanceof Error ? error.message : "Failed to approve enrollment";
          const statusCode =
            /not found/i.test(message) ? 404 :
            /already approved|already belongs/i.test(message) ? 409 :
            /expired/i.test(message) ? 410 : 400;
          return reply.code(statusCode).send({
            error: message
          });
        }
      }
    );
  }

  app.get(
    "/bootstrap",
    {
      ...(requireAuth ? { preHandler: requireAuth } : {})
    },
    async (request, reply) => {
      const token = z.string().min(1).parse((request.query as { clientToken?: string }).clientToken);

      try {
        const bootstrap = await store.getBootstrap(token, request.userId ?? null);
        return reply.send({
          ...bootstrap,
          wsUrl: clientWsUrl(config, token)
        });
      } catch (error) {
        return reply.code(401).send({
          error: error instanceof Error ? error.message : "Unknown client token"
        });
      }
    }
  );

  if (config.authMode === "required" && requireAuth) {
    app.post(
      "/ws/ticket",
      {
        config: {
          rateLimit: {
            max: 30,
            timeWindow: 60_000
          }
        }
      },
      async (request, reply) => {
        const body = wsTicketBodySchema.parse(request.body);

        if (body.type === "host") {
          const device = await store.getPersistedDevice(body.deviceId);
          if (!device || device.deviceSecret !== body.deviceSecret || !device.userId) {
            return reply.code(401).send({
              error: "Unauthorized host"
            });
          }

          const ticket = wsTickets.mint({
            type: "host",
            deviceId: body.deviceId
          });
          return reply.send({
            ticket: ticket.ticket,
            expiresAt: ticket.expiresAt,
            wsUrl: `${config.publicWsBaseUrl}/ws/host?ticket=${ticket.ticket}`
          });
        }

        await requireAuth(request, reply);
        if (reply.sent) {
          return reply;
        }

        const session = await store.getClientSession(body.clientToken);
        if (!session || (request.userId && session.userId && session.userId !== request.userId)) {
          return reply.code(401).send({
            error: "Unauthorized client"
          });
        }

        const ticket = wsTickets.mint({
          type: "client",
          clientToken: body.clientToken
        });
        return reply.send({
          ticket: ticket.ticket,
          expiresAt: ticket.expiresAt,
          wsUrl: `${config.publicWsBaseUrl}/ws/client?ticket=${ticket.ticket}`
        });
      }
    );
  }
}
