import type {
  FastifyReply,
  FastifyRequest
} from "fastify";
import { fromNodeHeaders } from "better-auth/node";

import type { ControlPlaneAuth } from "./auth.js";

declare module "fastify" {
  interface FastifyRequest {
    userId?: string;
  }
}

export function requireAuth(auth: ControlPlaneAuth) {
  return async (request: FastifyRequest, reply: FastifyReply) => {
    const session = await auth.api.getSession({
      headers: fromNodeHeaders(request.headers)
    });

    if (!session) {
      return reply.code(401).send({
        error: "Unauthorized"
      });
    }

    request.userId = session.user.id;
  };
}
