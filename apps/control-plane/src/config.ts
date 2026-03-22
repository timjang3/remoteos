export type ControlPlaneConfig = {
  host: string;
  port: number;
  publicHttpBaseUrl: string;
  publicWsBaseUrl: string;
  publicPairBaseUrl: string;
};

function buildPublicUrl(protocol: string, hostname: string, port: number) {
  return `${protocol}//${hostname}:${port}`;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ControlPlaneConfig {
  const host = env.HOST ?? "0.0.0.0";
  const port = Number(env.PORT ?? 8787);
  const publicPairBaseUrl = env.PUBLIC_PAIR_BASE_URL ?? "http://localhost:5173";
  const pairUrl = new URL(publicPairBaseUrl);
  const publicHttpBaseUrl =
    env.PUBLIC_HTTP_BASE_URL ?? buildPublicUrl(pairUrl.protocol, pairUrl.hostname, port);
  const publicWsBaseUrl =
    env.PUBLIC_WS_BASE_URL ??
    buildPublicUrl(pairUrl.protocol === "https:" ? "wss:" : "ws:", pairUrl.hostname, port);

  return {
    host,
    port,
    publicHttpBaseUrl,
    publicWsBaseUrl,
    publicPairBaseUrl
  };
}
