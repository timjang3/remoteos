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
};

function buildPublicUrl(protocol: string, hostname: string, port: number) {
  return `${protocol}//${hostname}:${port}`;
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
    googleClientSecret
  };
}
