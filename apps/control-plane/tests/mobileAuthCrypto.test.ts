import { describe, expect, it } from "vitest";

import { MobileAuthCrypto } from "../src/mobileAuthCrypto.js";

describe("MobileAuthCrypto", () => {
  it("round-trips encrypted auth tokens", () => {
    const crypto = new MobileAuthCrypto("test-secret-32-bytes-minimum-value");

    const ciphertext = crypto.encryptAuthToken("signed-session-token");

    expect(crypto.decryptAuthToken(ciphertext)).toBe("signed-session-token");
  });

  it("hashes identifiers deterministically by purpose", () => {
    const crypto = new MobileAuthCrypto("test-secret-32-bytes-minimum-value");

    expect(crypto.hashFlowId("flow_123")).toBe(crypto.hashFlowId("flow_123"));
    expect(crypto.hashFlowId("flow_123")).not.toBe(crypto.hashFlowId("flow_456"));
    expect(crypto.hashExchangeCode("code_123")).not.toBe(crypto.hashFlowId("code_123"));
  });
});
