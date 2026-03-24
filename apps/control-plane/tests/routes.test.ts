import Fastify from "fastify";
import multipart from "@fastify/multipart";
import { afterEach, describe, expect, it, vi } from "vitest";

import { loadConfig } from "../src/config.js";
import { registerRoutes } from "../src/routes.js";
import type { SpeechTranscriptionProvider } from "../src/speech.js";
import { MemoryBrokerStore } from "../src/store.js";
import { WsTicketStore } from "../src/wsTicketStore.js";

type MultipartPart =
  | {
      name: string;
      value: string;
    }
  | {
      name: string;
      filename: string;
      contentType: string;
      value: Buffer;
    };

function buildMultipartBody(parts: MultipartPart[]) {
  const boundary = "----remoteos-test-boundary";
  const chunks: Buffer[] = [];

  for (const part of parts) {
    chunks.push(Buffer.from(`--${boundary}\r\n`));
    if ("filename" in part) {
      chunks.push(
        Buffer.from(
          `Content-Disposition: form-data; name="${part.name}"; filename="${part.filename}"\r\nContent-Type: ${part.contentType}\r\n\r\n`
        )
      );
      chunks.push(part.value);
      chunks.push(Buffer.from("\r\n"));
      continue;
    }

    chunks.push(Buffer.from(`Content-Disposition: form-data; name="${part.name}"\r\n\r\n${part.value}\r\n`));
  }

  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return {
    boundary,
    body: Buffer.concat(chunks)
  };
}

async function createClaimedClient(store: MemoryBrokerStore, userId?: string) {
  const registration = await store.registerDevice({
    name: "Test Mac",
    mode: "hosted",
    ...(userId ? { userId } : {})
  });
  if ("approvalRequired" in registration) {
    throw new Error("Expected approved registration");
  }

  const pairing = await store.createPairing({
    deviceId: registration.device.id,
    deviceSecret: registration.deviceSecret,
    publicPairBaseUrl: "http://localhost:5173",
    ...(userId ? { userId } : {})
  });

  return store.claimPairing(pairing.pairingCode, "Phone", userId);
}

async function createApp(options?: {
  authMode?: "none" | "required";
  requireAuth?: (request: any, reply: any) => Promise<unknown>;
  speechProvider?: SpeechTranscriptionProvider | null;
}) {
  const authMode = options?.authMode ?? "none";
  const config = loadConfig({
    AUTH_MODE: authMode,
    DATABASE_URL: authMode === "required" ? "postgres://postgres:postgres@localhost:5433/remoteos" : undefined,
    BETTER_AUTH_SECRET: authMode === "required" ? "change-me-local-only-32-bytes-or-more" : undefined,
    ALLOWED_ORIGINS: authMode === "required" ? "http://localhost:5173" : undefined,
    PUBLIC_PAIR_BASE_URL: "http://localhost:5173",
    OPENAI_API_KEY: "sk-test",
    SPEECH_PROVIDER: "openai"
  });
  const store = new MemoryBrokerStore();
  const app = Fastify();
  await app.register(multipart, {
    limits: {
      files: 1,
      fileSize: config.speech.maxUploadBytes
    }
  });
  await registerRoutes(app, {
    config,
    store,
    requireAuth: options?.requireAuth,
    speechProvider: options?.speechProvider ?? {
      provider: "openai",
      model: "gpt-4o-transcribe",
      transcribe: vi.fn(async () => ({
        text: "dictated request",
        provider: "openai",
        model: "gpt-4o-transcribe"
      }))
    },
    wsTickets: new WsTicketStore()
  });

  return {
    app,
    config,
    store
  };
}

describe("registerRoutes speech transcription", () => {
  const apps = new Set<Awaited<ReturnType<typeof createApp>>["app"]>();

  afterEach(async () => {
    for (const app of apps) {
      await app.close();
    }
    apps.clear();
  });

  it("includes speech capabilities in bootstrap responses", async () => {
    const harness = await createApp();
    apps.add(harness.app);
    const claimed = await createClaimedClient(harness.store);

    const response = await harness.app.inject({
      method: "GET",
      url: `/bootstrap?clientToken=${encodeURIComponent(claimed.clientToken)}`
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().speech).toEqual({
      transcriptionAvailable: true,
      provider: "openai",
      maxDurationMs: 120000,
      maxUploadBytes: 10485760
    });
  });

  it("transcribes supported uploads and passes the authenticated client token", async () => {
    const speechProvider = {
      provider: "openai",
      model: "gpt-4o-transcribe",
      transcribe: vi.fn(async () => ({
        text: "dictated request",
        provider: "openai" as const,
        model: "gpt-4o-transcribe"
      }))
    } satisfies SpeechTranscriptionProvider;
    const harness = await createApp({
      speechProvider
    });
    apps.add(harness.app);
    const claimed = await createClaimedClient(harness.store);
    const multipartBody = buildMultipartBody([
      {
        name: "clientToken",
        value: claimed.clientToken
      },
      {
        name: "durationMs",
        value: "2500"
      },
      {
        name: "audio",
        filename: "dictation.webm",
        contentType: "audio/webm",
        value: Buffer.from("audio")
      }
    ]);

    const response = await harness.app.inject({
      method: "POST",
      url: "/speech/transcriptions",
      headers: {
        "content-type": `multipart/form-data; boundary=${multipartBody.boundary}`
      },
      payload: multipartBody.body
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      text: "dictated request",
      provider: "openai",
      model: "gpt-4o-transcribe"
    });
    expect(speechProvider.transcribe).toHaveBeenCalledWith(
      expect.objectContaining({
        filename: "dictation.webm",
        mimeType: "audio/webm"
      })
    );
  });

  it("rejects unsupported audio mime types", async () => {
    const harness = await createApp();
    apps.add(harness.app);
    const claimed = await createClaimedClient(harness.store);
    const multipartBody = buildMultipartBody([
      {
        name: "clientToken",
        value: claimed.clientToken
      },
      {
        name: "audio",
        filename: "dictation.png",
        contentType: "image/png",
        value: Buffer.from("not audio")
      }
    ]);

    const response = await harness.app.inject({
      method: "POST",
      url: "/speech/transcriptions",
      headers: {
        "content-type": `multipart/form-data; boundary=${multipartBody.boundary}`
      },
      payload: multipartBody.body
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error).toContain("Unsupported audio type");
  });

  it("rejects hosted transcription requests for a different signed-in user", async () => {
    const harness = await createApp({
      authMode: "required",
      requireAuth: async (request) => {
        request.userId = "user_999";
      }
    });
    apps.add(harness.app);
    const claimed = await createClaimedClient(harness.store, "user_123");
    const multipartBody = buildMultipartBody([
      {
        name: "clientToken",
        value: claimed.clientToken
      },
      {
        name: "audio",
        filename: "dictation.webm",
        contentType: "audio/webm",
        value: Buffer.from("audio")
      }
    ]);

    const response = await harness.app.inject({
      method: "POST",
      url: "/speech/transcriptions",
      headers: {
        "content-type": `multipart/form-data; boundary=${multipartBody.boundary}`
      },
      payload: multipartBody.body
    });

    expect(response.statusCode).toBe(401);
    expect(response.json().error).toBe("Unauthorized client");
  });
});
