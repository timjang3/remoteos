import { describe, expect, it } from "vitest";

import { loadConfig } from "../src/config";

describe("loadConfig", () => {
  it("derives public HTTP and WS URLs from the pairing host when not provided", () => {
    const config = loadConfig({
      PORT: "8787",
      PUBLIC_PAIR_BASE_URL: "http://192.168.1.25:5173"
    });

    expect(config.publicHttpBaseUrl).toBe("http://192.168.1.25:8787");
    expect(config.publicWsBaseUrl).toBe("ws://192.168.1.25:8787");
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
});
