import type {
  FastifyInstance,
  FastifyReply
} from "fastify";
import { fromNodeHeaders } from "better-auth/node";
import { z } from "zod";

import type { ControlPlaneAuth } from "./auth.js";
import type { ControlPlaneConfig } from "./config.js";
import { MobileAuthStore } from "./mobileAuthStore.js";

const mobileAuthStartQuerySchema = z.object({
  provider: z.enum(["google"]),
  redirectUri: z.string().min(1)
});

const mobileAuthCallbackQuerySchema = z.object({
  flow: z.string().min(1),
  error: z.string().min(1).optional(),
  error_description: z.string().min(1).optional()
});

const mobileAuthExchangeBodySchema = z.object({
  code: z.string().min(1)
});

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

function setResponseHeaders(reply: FastifyReply, response: Response) {
  const responseHeaders = response.headers as Headers & {
    getSetCookie?: () => string[];
  };
  const setCookie = responseHeaders.getSetCookie?.() ?? [];
  if (setCookie.length > 0) {
    reply.header("set-cookie", setCookie);
  }

  response.headers.forEach((value, key) => {
    if (key.toLowerCase() === "set-cookie") {
      return;
    }
    reply.header(key, value);
  });
}

async function sendWebResponse(reply: FastifyReply, response: Response) {
  reply.code(response.status);
  setResponseHeaders(reply, response);

  const text = await response.text();
  return reply.send(text.length > 0 ? text : null);
}

function parseCookies(cookieHeader: string) {
  const cookies = new Map<string, string>();
  for (const cookie of cookieHeader.split(/;\s*/)) {
    const [name, ...rest] = cookie.split("=");
    if (!name) {
      continue;
    }
    cookies.set(name, rest.join("="));
  }
  return cookies;
}

function authSessionCookieNames(config: ControlPlaneConfig) {
  const securePrefix = new URL(config.publicHttpBaseUrl).protocol === "https:" ? "__Secure-" : "";
  return [
    `${securePrefix}better-auth.session_token`,
    `${securePrefix}better-auth-session_token`
  ];
}

function readSessionAuthToken(cookieHeader: string | undefined, config: ControlPlaneConfig) {
  if (!cookieHeader) {
    return null;
  }

  const cookies = parseCookies(cookieHeader);
  for (const name of authSessionCookieNames(config)) {
    const token = cookies.get(name);
    if (token) {
      return token;
    }
  }

  return null;
}

function validateMobileRedirectUri(rawRedirectUri: string, config: ControlPlaneConfig) {
  try {
    const redirectUri = new URL(rawRedirectUri);
    const scheme = redirectUri.protocol.slice(0, -1).toLowerCase();
    if (!scheme || scheme === "http" || scheme === "https") {
      return null;
    }
    if (!config.mobileAuthRedirectSchemes.includes(scheme)) {
      return null;
    }
    return redirectUri.toString();
  } catch {
    return null;
  }
}

function buildRedirectUri(
  redirectUri: string,
  params: Record<string, string | undefined>
) {
  const url = new URL(redirectUri);
  for (const [key, value] of Object.entries(params)) {
    if (value) {
      url.searchParams.set(key, value);
    }
  }
  return url.toString();
}

export async function registerAuthRoutes(
  app: FastifyInstance,
  auth: ControlPlaneAuth,
  config: ControlPlaneConfig,
  mobileAuthStore = new MobileAuthStore()
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
      return sendWebResponse(reply, response);
    } catch (error) {
      request.log.error(error, "Better Auth route failed");
      return reply.code(500).send({
        error: "Internal authentication error"
      });
    }
  });

  app.get("/mobile/auth/start", async (request, reply) => {
    try {
      const query = mobileAuthStartQuerySchema.parse(request.query);
      const redirectUri = validateMobileRedirectUri(query.redirectUri, config);
      if (!redirectUri) {
        return reply.code(400).send({
          error: "Unsupported mobile redirect URI"
        });
      }
      if (query.provider === "google" && !config.googleAuthEnabled) {
        return reply.code(400).send({
          error: "Google sign-in is not configured on this control plane"
        });
      }

      const flow = mobileAuthStore.createFlow({
        provider: query.provider,
        redirectUri
      });
      const callbackURL = new URL("/mobile/auth/callback", config.publicHttpBaseUrl);
      callbackURL.searchParams.set("flow", flow.id);

      const headers = new Headers({
        "content-type": "application/json",
        accept: "application/json",
        origin: config.publicHttpBaseUrl
      });
      const userAgent = request.headers["user-agent"];
      if (typeof userAgent === "string" && userAgent.length > 0) {
        headers.set("user-agent", userAgent);
      }

      const response = await auth.handler(
        new Request(createAuthRequestUrl("/api/auth/sign-in/social", config), {
          method: "POST",
          headers,
          body: JSON.stringify({
            provider: query.provider,
            callbackURL: callbackURL.toString(),
            errorCallbackURL: callbackURL.toString(),
            disableRedirect: true
          })
        })
      );

      if (!response.ok) {
        mobileAuthStore.consumeFlow(flow.id);
        return sendWebResponse(reply, response);
      }

      const payload = await response.json() as {
        url?: string;
      };
      if (!payload.url) {
        mobileAuthStore.consumeFlow(flow.id);
        request.log.error({ flowId: flow.id }, "Better Auth did not return a social authorization URL");
        return reply.code(500).send({
          error: "Authentication provider redirect failed"
        });
      }

      setResponseHeaders(reply, response);
      return reply.redirect(payload.url);
    } catch (error) {
      request.log.error(error, "Mobile auth start failed");
      return reply.code(500).send({
        error: "Internal authentication error"
      });
    }
  });

  app.get("/mobile/auth/callback", async (request, reply) => {
    const query = mobileAuthCallbackQuerySchema.parse(request.query);
    const flow = mobileAuthStore.getFlow(query.flow);
    if (!flow) {
      return reply.code(400).send({
        error: "Authentication flow not found or expired"
      });
    }

    const redirectWithParams = (params: Record<string, string | undefined>) => {
      mobileAuthStore.consumeFlow(query.flow);
      return reply.redirect(buildRedirectUri(flow.redirectUri, params));
    };

    if (query.error) {
      return redirectWithParams({
        error: query.error,
        error_description: query.error_description
      });
    }

    try {
      const session = await auth.api.getSession({
        headers: fromNodeHeaders(request.headers)
      });
      if (!session) {
        return redirectWithParams({
          error: "unauthorized"
        });
      }

      const authToken = readSessionAuthToken(request.headers.cookie, config);
      if (!authToken) {
        return redirectWithParams({
          error: "missing_session_token"
        });
      }

      const exchange = mobileAuthStore.createExchange({
        authToken,
        user: {
          id: session.user.id,
          name: session.user.name,
          email: session.user.email,
          image: session.user.image ?? null
        }
      });

      mobileAuthStore.consumeFlow(query.flow);
      return reply.redirect(buildRedirectUri(flow.redirectUri, {
        code: exchange.code
      }));
    } catch (error) {
      request.log.error(error, "Mobile auth callback failed");
      return redirectWithParams({
        error: "internal_error"
      });
    }
  });

  app.post("/mobile/auth/exchange", async (request, reply) => {
    const body = mobileAuthExchangeBodySchema.parse(request.body);
    const exchange = mobileAuthStore.consumeExchange(body.code);
    if (!exchange) {
      return reply.code(400).send({
        error: "Authentication code not found or expired"
      });
    }

    return reply.send(exchange);
  });
}
