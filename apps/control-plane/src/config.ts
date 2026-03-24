import type { SpeechProvider } from "@remoteos/contracts";

export type ControlPlaneSpeechConfig = {
  provider: SpeechProvider | null;
  transcriptionAvailable: boolean;
  openAIAPIKey: string | null;
  model: string;
  maxDurationMs: number;
  maxUploadBytes: number;
};

export type ControlPlaneConfig = {
  authMode: "none" | "required";
  host: string;
  port: number;
  databaseUrl: string | null;
  betterAuthSecret: string | null;
  publicHttpBaseUrl: string;
  publicWsBaseUrl: string;
  publicPairBaseUrl: string;
  allowedOrigins: string[];
  googleAuthEnabled: boolean;
  googleClientId: string | null;
  googleClientSecret: string | null;
  speech: ControlPlaneSpeechConfig;
};

function buildPublicUrl(protocol: string, hostname: string, port: number) {
  return `${protocol}//${hostname}:${port}`;
}

function parsePositiveInteger(
  value: string | undefined,
  fallback: number,
  name: string
) {
  if (!value) {
    return fallback;
  }

  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }

  return parsed;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ControlPlaneConfig {
  const authMode = env.AUTH_MODE === "required" ? "required" : "none";
  const host = env.HOST ?? "0.0.0.0";
  const port = Number(env.PORT ?? 8787);
  const databaseUrl = env.DATABASE_URL ?? null;
  const betterAuthSecret = env.BETTER_AUTH_SECRET ?? null;
  const publicPairBaseUrl = env.PUBLIC_PAIR_BASE_URL ?? "http://localhost:5173";
  const pairUrl = new URL(publicPairBaseUrl);
  const publicHttpBaseUrl =
    env.PUBLIC_HTTP_BASE_URL ?? buildPublicUrl(pairUrl.protocol, pairUrl.hostname, port);
  const publicWsBaseUrl =
    env.PUBLIC_WS_BASE_URL ??
    buildPublicUrl(pairUrl.protocol === "https:" ? "wss:" : "ws:", pairUrl.hostname, port);
  const allowedOrigins = (env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
  const googleClientId = env.GOOGLE_CLIENT_ID ?? null;
  const googleClientSecret = env.GOOGLE_CLIENT_SECRET ?? null;
  const openAIAPIKey = env.OPENAI_API_KEY?.trim() || null;
  const rawSpeechProvider = env.SPEECH_PROVIDER?.trim().toLowerCase();
  const speechProvider: SpeechProvider | null =
    rawSpeechProvider === "openai"
      ? "openai"
      : rawSpeechProvider
        ? (() => {
            throw new Error(`Unsupported SPEECH_PROVIDER: ${env.SPEECH_PROVIDER}`);
          })()
        : openAIAPIKey
          ? "openai"
          : null;
  const speechModel = env.SPEECH_MODEL?.trim() || "gpt-4o-mini-transcribe";
  const speechMaxDurationMs = parsePositiveInteger(env.SPEECH_MAX_DURATION_MS, 120_000, "SPEECH_MAX_DURATION_MS");
  const speechMaxUploadBytes = parsePositiveInteger(env.SPEECH_MAX_UPLOAD_BYTES, 10 * 1024 * 1024, "SPEECH_MAX_UPLOAD_BYTES");

  if (authMode === "required") {
    if (!databaseUrl) {
      throw new Error("DATABASE_URL is required when AUTH_MODE=required");
    }
    if (!betterAuthSecret) {
      throw new Error("BETTER_AUTH_SECRET is required when AUTH_MODE=required");
    }
    if (allowedOrigins.length === 0) {
      throw new Error("ALLOWED_ORIGINS is required when AUTH_MODE=required");
    }
  }

  return {
    authMode,
    host,
    port,
    databaseUrl,
    betterAuthSecret,
    publicHttpBaseUrl,
    publicWsBaseUrl,
    publicPairBaseUrl,
    allowedOrigins,
    googleAuthEnabled: Boolean(googleClientId && googleClientSecret),
    googleClientId,
    googleClientSecret,
    speech: {
      provider: speechProvider,
      transcriptionAvailable: speechProvider === "openai" && Boolean(openAIAPIKey),
      openAIAPIKey,
      model: speechModel,
      maxDurationMs: speechMaxDurationMs,
      maxUploadBytes: speechMaxUploadBytes
    }
  };
}
