import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export type BrokerCredentialPurpose =
  | "device_secret"
  | "client_token"
  | "pairing_code"
  | "enrollment_token";

const HASH_VERSION = "v1";

function safeCompare(left: string, right: string) {
  const leftBuffer = Buffer.from(left, "utf8");
  const rightBuffer = Buffer.from(right, "utf8");
  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }

  return timingSafeEqual(leftBuffer, rightBuffer);
}

export class BrokerCredentialHasher {
  constructor(private readonly secret: string) {}

  hash(purpose: BrokerCredentialPurpose, value: string) {
    const digest = createHmac("sha256", this.secret)
      .update(`remoteos:${HASH_VERSION}:${purpose}:${value}`, "utf8")
      .digest("base64url");

    return `${HASH_VERSION}:${digest}`;
  }

  verify(purpose: BrokerCredentialPurpose, value: string, expectedHash: string) {
    return safeCompare(this.hash(purpose, value), expectedHash);
  }
}

export function createMemoryCredentialHasher() {
  return new BrokerCredentialHasher(randomBytes(32).toString("base64url"));
}
