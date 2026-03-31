import type { SpeechProvider } from "@remoteos/contracts";

export type ControlPlaneSpeechConfig = {
  provider: SpeechProvider | null;
  transcriptionAvailable: boolean;
  openAIAPIKey: string | null;
  model: string;
  maxDurationMs: number;
  maxUploadBytes: number;
};

export type ControlPlaneTrustProxy = boolean | number | string | string[];

export type ControlPlaneConfig = {
  authMode: "none" | "required";
  host: string;
  port: number;
  databaseUrl: string | null;
  betterAuthSecret: string | null;
  tokenHashSecret: string | null;
  publicHttpBaseUrl: string;
  publicWsBaseUrl: string;
  publicPairBaseUrl: string;
  allowedOrigins: string[];
  mobileAuthRedirectSchemes: string[];
  trustProxy: ControlPlaneTrustProxy;
  googleAuthEnabled: boolean;
  googleClientId: string | null;
  googleClientSecret: string | null;
  speech: ControlPlaneSpeechConfig;
};

function buildPublicUrl(protocol: string, hostname: string, port: number) {
  return `${protocol}//${hostname}:${port}`;
}

function isLoopbackHostname(hostname: string) {
  return (
    hostname === "localhost"
    || hostname === "127.0.0.1"
    || hostname === "::1"
    || hostname === "[::1]"
    || hostname.startsWith("127.")
  );
}

function parseTrustProxy(
  value: string | undefined,
  authMode: "none" | "required"
): ControlPlaneTrustProxy {
  const trimmed = value?.trim();
  if (!trimmed) {
    return authMode === "required" ? ["loopback", "linklocal", "uniquelocal"] : false;
  }

  if (trimmed === "true") {
    throw new Error("TRUST_PROXY=true is not allowed; configure explicit trusted hops or proxy networks");
  }
  if (trimmed === "false") {
    return false;
  }

  const parsedNumber = Number.parseInt(trimmed, 10);
  if (String(parsedNumber) === trimmed && Number.isFinite(parsedNumber) && parsedNumber >= 0) {
    return parsedNumber;
  }

  const entries = trimmed
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (entries.length <= 1) {
    return entries[0] ?? false;
  }

  return entries;
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

function parseMobileAuthRedirectSchemes(value: string | undefined) {
  const entries = (value ?? "remoteos")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);

  if (entries.length === 0) {
    throw new Error("MOBILE_AUTH_REDIRECT_SCHEMES must include at least one URI scheme");
  }

  for (const scheme of entries) {
    if (!/^[a-z][a-z0-9+.-]*$/i.test(scheme)) {
      throw new Error(`Invalid mobile auth redirect scheme: ${scheme}`);
    }
  }

  return [...new Set(entries)];
}

function assertSecurePublicUrl(name: string, url: URL, allowedProtocol: "https:" | "wss:") {
  if (!isLoopbackHostname(url.hostname) && url.protocol !== allowedProtocol) {
    throw new Error(`${name} must use ${allowedProtocol.slice(0, -1)} in hosted mode`);
  }
}

function resolveDefaultHost(urls: URL[]) {
  return urls.every((url) => isLoopbackHostname(url.hostname))
    ? "127.0.0.1"
    : "0.0.0.0";
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ControlPlaneConfig {
  const authMode = env.AUTH_MODE === "required" ? "required" : "none";
  const port = Number(env.PORT ?? 8787);
  const databaseUrl = env.DATABASE_URL ?? null;
  const betterAuthSecret = env.BETTER_AUTH_SECRET ?? null;
  const tokenHashSecret = env.TOKEN_HASH_SECRET?.trim() || betterAuthSecret || null;
  const publicPairBaseUrl = env.PUBLIC_PAIR_BASE_URL ?? "http://localhost:5173";
  const publicPairUrl = new URL(publicPairBaseUrl);
  const publicHttpBaseUrl =
    env.PUBLIC_HTTP_BASE_URL ?? buildPublicUrl(publicPairUrl.protocol, publicPairUrl.hostname, port);
  const publicWsBaseUrl =
    env.PUBLIC_WS_BASE_URL ??
    buildPublicUrl(publicPairUrl.protocol === "https:" ? "wss:" : "ws:", publicPairUrl.hostname, port);
  const allowedOrigins = (env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
  const mobileAuthRedirectSchemes = parseMobileAuthRedirectSchemes(env.MOBILE_AUTH_REDIRECT_SCHEMES);
  const trustProxy = parseTrustProxy(env.TRUST_PROXY, authMode);
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
  const publicHttpUrl = new URL(publicHttpBaseUrl);
  const publicWsUrl = new URL(publicWsBaseUrl);
  const host = env.HOST ?? resolveDefaultHost([publicPairUrl, publicHttpUrl, publicWsUrl]);

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
    for (const origin of allowedOrigins) {
      const allowedOriginUrl = new URL(origin);
      assertSecurePublicUrl("ALLOWED_ORIGINS entries", allowedOriginUrl, "https:");
    }
    assertSecurePublicUrl("PUBLIC_PAIR_BASE_URL", publicPairUrl, "https:");
    assertSecurePublicUrl("PUBLIC_HTTP_BASE_URL", publicHttpUrl, "https:");
    assertSecurePublicUrl("PUBLIC_WS_BASE_URL", publicWsUrl, "wss:");
  }

  if (databaseUrl && !tokenHashSecret) {
    throw new Error("TOKEN_HASH_SECRET is required when DATABASE_URL is set and BETTER_AUTH_SECRET is absent");
  }

  return {
    authMode,
    host,
    port,
    databaseUrl,
    betterAuthSecret,
    tokenHashSecret,
    publicHttpBaseUrl,
    publicWsBaseUrl,
    publicPairBaseUrl,
    allowedOrigins,
    mobileAuthRedirectSchemes,
    trustProxy,
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
