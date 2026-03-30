import Fastify from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { ControlPlaneAuth } from "../src/auth.js";
import { registerAuthRoutes } from "../src/authRoutes.js";
import { loadConfig } from "../src/config.js";
import { MobileAuthStore } from "../src/mobileAuthStore.js";

function createHostedConfig(overrides: NodeJS.ProcessEnv = {}) {
  return loadConfig({
    AUTH_MODE: "required",
    DATABASE_URL: "postgres://postgres:postgres@localhost:5433/remoteos",
    BETTER_AUTH_SECRET: "change-me-local-only-32-bytes-or-more",
    ALLOWED_ORIGINS: "https://remoteos.app",
    PUBLIC_PAIR_BASE_URL: "https://remoteos.app",
    PUBLIC_HTTP_BASE_URL: "https://control.remoteos.app",
    PUBLIC_WS_BASE_URL: "wss://control.remoteos.app",
    GOOGLE_CLIENT_ID: "google-client-id",
    GOOGLE_CLIENT_SECRET: "google-client-secret",
    MOBILE_AUTH_REDIRECT_SCHEMES: "remoteos",
    ...overrides
  });
}

function createAuthStub() {
  const handler = vi.fn(async (request: Request) => {
    const headers = new Headers();
    headers.append("content-type", "application/json");
    headers.append("set-cookie", "__Secure-better-auth.oauth_state=test-state; Path=/; HttpOnly; Secure; SameSite=Lax");

    return new Response(
      JSON.stringify({
        url: "https://accounts.google.com/o/oauth2/v2/auth?state=test-state",
        redirect: false
      }),
      {
        status: 200,
        headers
      }
    );
  });

  const getSession = vi.fn(async ({ headers }: { headers: Headers }) => {
    const cookie = headers.get("cookie");
    if (!cookie?.includes("__Secure-better-auth.session_token=signed-session-token")) {
      return null;
    }

    return {
      session: {
        id: "session_1"
      },
      user: {
        id: "user_1",
        name: "Tim",
        email: "tim@example.com",
        image: null
      }
    };
  });

  return {
    auth: {
      handler,
      api: {
        getSession
      }
    } as unknown as ControlPlaneAuth,
    handler,
    getSession
  };
}

describe("registerAuthRoutes mobile auth bridge", () => {
  const apps = new Set<ReturnType<typeof Fastify>>();

  afterEach(async () => {
    for (const app of apps) {
      await app.close();
    }
    apps.clear();
  });

  it("starts a hosted auth flow, redirects back to the app, and exchanges a bearer token", async () => {
    const config = createHostedConfig();
    const { auth, handler } = createAuthStub();
    const app = Fastify();
    apps.add(app);
    await registerAuthRoutes(app, auth, config, new MobileAuthStore());

    const startResponse = await app.inject({
      method: "GET",
      url: "/mobile/auth/start?provider=google&redirectUri=remoteos%3A%2F%2Fauth"
    });

    expect(startResponse.statusCode).toBe(302);
    expect(startResponse.headers.location).toBe("https://accounts.google.com/o/oauth2/v2/auth?state=test-state");
    expect(startResponse.headers["set-cookie"]).toBeDefined();
    expect(handler).toHaveBeenCalledTimes(1);

    const proxiedRequest = handler.mock.calls[0]?.[0] as Request | undefined;
    expect(proxiedRequest?.url).toBe("https://control.remoteos.app/api/auth/sign-in/social");
    const proxiedBody = await proxiedRequest?.clone().json() as {
      callbackURL: string;
      disableRedirect: boolean;
      errorCallbackURL: string;
      provider: string;
    };
    expect(proxiedBody.provider).toBe("google");
    expect(proxiedBody.disableRedirect).toBe(true);
    expect(proxiedBody.errorCallbackURL).toBe(proxiedBody.callbackURL);

    const callbackURL = new URL(proxiedBody.callbackURL);
    expect(callbackURL.origin).toBe("https://control.remoteos.app");
    expect(callbackURL.pathname).toBe("/mobile/auth/callback");

    const callbackResponse = await app.inject({
      method: "GET",
      url: `${callbackURL.pathname}${callbackURL.search}`,
      headers: {
        cookie: "__Secure-better-auth.session_token=signed-session-token"
      }
    });

    expect(callbackResponse.statusCode).toBe(302);
    const appRedirect = new URL(callbackResponse.headers.location!);
    expect(appRedirect.protocol).toBe("remoteos:");
    expect(appRedirect.host).toBe("auth");
    const exchangeCode = appRedirect.searchParams.get("code");
    expect(exchangeCode).toBeTruthy();

    const exchangeResponse = await app.inject({
      method: "POST",
      url: "/mobile/auth/exchange",
      payload: {
        code: exchangeCode
      }
    });

    expect(exchangeResponse.statusCode).toBe(200);
    expect(exchangeResponse.json()).toMatchObject({
      authToken: "signed-session-token",
      user: {
        id: "user_1",
        name: "Tim",
        email: "tim@example.com",
        image: null
      }
    });

    const replayResponse = await app.inject({
      method: "POST",
      url: "/mobile/auth/exchange",
      payload: {
        code: exchangeCode
      }
    });

    expect(replayResponse.statusCode).toBe(400);
  });

  it("rejects unsupported mobile redirect schemes", async () => {
    const config = createHostedConfig();
    const { auth } = createAuthStub();
    const app = Fastify();
    apps.add(app);
    await registerAuthRoutes(app, auth, config, new MobileAuthStore());

    const response = await app.inject({
      method: "GET",
      url: "/mobile/auth/start?provider=google&redirectUri=https%3A%2F%2Fevil.example%2Fcallback"
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error).toContain("Unsupported");
  });

  it("redirects auth failures back to the app callback URI", async () => {
    const config = createHostedConfig();
    const { auth, handler, getSession } = createAuthStub();
    const app = Fastify();
    apps.add(app);
    await registerAuthRoutes(app, auth, config, new MobileAuthStore());

    const startResponse = await app.inject({
      method: "GET",
      url: "/mobile/auth/start?provider=google&redirectUri=remoteos%3A%2F%2Fauth"
    });

    const proxiedRequest = handler.mock.calls[0]?.[0] as Request;
    const proxiedBody = await proxiedRequest.clone().json() as {
      callbackURL: string;
    };
    const callbackURL = new URL(proxiedBody.callbackURL);

    const callbackResponse = await app.inject({
      method: "GET",
      url: `${callbackURL.pathname}${callbackURL.search}&error=access_denied&error_description=User%20cancelled`
    });

    expect(startResponse.statusCode).toBe(302);
    expect(callbackResponse.statusCode).toBe(302);
    const appRedirect = new URL(callbackResponse.headers.location!);
    expect(appRedirect.searchParams.get("error")).toBe("access_denied");
    expect(appRedirect.searchParams.get("error_description")).toBe("User cancelled");
    expect(getSession).not.toHaveBeenCalled();
  });
});
