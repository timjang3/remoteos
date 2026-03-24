import { describe, expect, it } from "vitest";

import { loadConfig } from "../src/config";

describe("loadConfig", () => {
  it("derives public HTTP and WS URLs from the pairing host when not provided", () => {
    const config = loadConfig({
      PORT: "8787",
      PUBLIC_PAIR_BASE_URL: "http://192.168.1.25:5173"
    });

    expect(config.host).toBe("127.0.0.1");
    expect(config.publicHttpBaseUrl).toBe("http://192.168.1.25:8787");
    expect(config.publicWsBaseUrl).toBe("ws://192.168.1.25:8787");
    expect(config.trustProxy).toBe(false);
  });

  it("keeps explicit public HTTP and WS URLs when provided", () => {
    const config = loadConfig({
      PORT: "8787",
      PUBLIC_PAIR_BASE_URL: "http://192.168.1.25:5173",
      PUBLIC_HTTP_BASE_URL: "https://broker.remoteos.dev",
      PUBLIC_WS_BASE_URL: "wss://broker.remoteos.dev"
    });

    expect(config.publicHttpBaseUrl).toBe("https://broker.remoteos.dev");
    expect(config.publicWsBaseUrl).toBe("wss://broker.remoteos.dev");
  });

  it("defaults hosted mode to loopback bind and explicit private proxy trust", () => {
    const config = loadConfig({
      AUTH_MODE: "required",
      DATABASE_URL: "postgres://postgres:postgres@localhost:5433/remoteos",
      BETTER_AUTH_SECRET: "change-me-local-only-32-bytes-or-more",
      ALLOWED_ORIGINS: "http://localhost:5173",
      PUBLIC_PAIR_BASE_URL: "http://localhost:5173"
    });

    expect(config.host).toBe("127.0.0.1");
    expect(config.trustProxy).toEqual(["loopback", "linklocal", "uniquelocal"]);
    expect(config.publicHttpBaseUrl).toBe("http://localhost:8787");
    expect(config.publicWsBaseUrl).toBe("ws://localhost:8787");
  });

  it("rejects insecure hosted public URLs and blanket proxy trust", () => {
    expect(() =>
      loadConfig({
        AUTH_MODE: "required",
        DATABASE_URL: "postgres://postgres:postgres@localhost:5433/remoteos",
        BETTER_AUTH_SECRET: "change-me-local-only-32-bytes-or-more",
        ALLOWED_ORIGINS: "https://remoteos.dev",
        PUBLIC_PAIR_BASE_URL: "http://remoteos.dev"
      })
    ).toThrow("PUBLIC_PAIR_BASE_URL must use https in hosted mode");

    expect(() =>
      loadConfig({
        AUTH_MODE: "required",
        DATABASE_URL: "postgres://postgres:postgres@localhost:5433/remoteos",
        BETTER_AUTH_SECRET: "change-me-local-only-32-bytes-or-more",
        ALLOWED_ORIGINS: "http://remoteos.dev",
        PUBLIC_PAIR_BASE_URL: "https://remoteos.dev"
      })
    ).toThrow("ALLOWED_ORIGINS entries must use https in hosted mode");

    expect(() =>
      loadConfig({
        AUTH_MODE: "required",
        DATABASE_URL: "postgres://postgres:postgres@localhost:5433/remoteos",
        BETTER_AUTH_SECRET: "change-me-local-only-32-bytes-or-more",
        ALLOWED_ORIGINS: "https://remoteos.dev",
        PUBLIC_PAIR_BASE_URL: "https://remoteos.dev",
        PUBLIC_HTTP_BASE_URL: "https://control.remoteos.dev",
        PUBLIC_WS_BASE_URL: "wss://control.remoteos.dev",
        TRUST_PROXY: "true"
      })
    ).toThrow("TRUST_PROXY=true is not allowed");
  });

  it("requires a credential hashing secret for persistent authless mode", () => {
    expect(() =>
      loadConfig({
        DATABASE_URL: "postgres://postgres:postgres@localhost:5433/remoteos",
        PUBLIC_PAIR_BASE_URL: "http://localhost:5173"
      })
    ).toThrow("TOKEN_HASH_SECRET is required when DATABASE_URL is set and BETTER_AUTH_SECRET is absent");
  });

  it("enables OpenAI speech transcription when an API key is configured", () => {
    const config = loadConfig({
      PORT: "8787",
      PUBLIC_PAIR_BASE_URL: "http://localhost:5173",
      OPENAI_API_KEY: "sk-test"
    });

    expect(config.speech.provider).toBe("openai");
    expect(config.speech.transcriptionAvailable).toBe(true);
    expect(config.speech.model).toBe("gpt-4o-mini-transcribe");
    expect(config.speech.maxDurationMs).toBe(120000);
    expect(config.speech.maxUploadBytes).toBe(10485760);
  });
});
