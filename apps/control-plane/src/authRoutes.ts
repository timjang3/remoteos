import type { FastifyInstance } from "fastify";

import type { ControlPlaneAuth } from "./auth.js";
import type { ControlPlaneConfig } from "./config.js";

function createAuthRequestUrl(requestUrl: string, config: ControlPlaneConfig) {
  return new URL(requestUrl, config.publicHttpBaseUrl).toString();
}

function requestBodyToString(body: unknown) {
  if (body === undefined || body === null) {
    return undefined;
  }
  if (typeof body === "string") {
    return body;
  }
  if (body instanceof Uint8Array) {
    return Buffer.from(body).toString("utf8");
  }
  return JSON.stringify(body);
}

export async function registerAuthRoutes(
  app: FastifyInstance,
  auth: ControlPlaneAuth,
  config: ControlPlaneConfig
) {
  app.all("/api/auth/*", async (request, reply) => {
    try {
      const headers = new Headers();
      for (const [key, value] of Object.entries(request.headers)) {
        if (Array.isArray(value)) {
          for (const entry of value) {
            headers.append(key, entry);
          }
          continue;
        }

        if (value !== undefined) {
          headers.append(key, String(value));
        }
      }

      const body = requestBodyToString(request.body);
      const webRequest = new Request(
        createAuthRequestUrl(request.raw.url ?? request.url, config),
        {
          method: request.method,
          headers,
          ...(request.method === "GET" || request.method === "HEAD" || body === undefined
            ? {}
            : { body })
        }
      );

      const response = await auth.handler(webRequest);
      reply.code(response.status);
      response.headers.forEach((value, key) => {
        reply.header(key, value);
      });

      const text = await response.text();
      return reply.send(text.length > 0 ? text : null);
    } catch (error) {
      request.log.error(error, "Better Auth route failed");
      return reply.code(500).send({
        error: "Internal authentication error"
      });
    }
  });
}
