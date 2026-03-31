import {
  createCipheriv,
  createDecipheriv,
  hkdfSync,
  randomBytes
} from "node:crypto";

import { BrokerCredentialHasher } from "./credentialHasher.js";

const MOBILE_AUTH_CIPHERTEXT_VERSION = "v1";
const MOBILE_AUTH_KEY_LENGTH = 32;
const MOBILE_AUTH_IV_LENGTH = 12;
const MOBILE_AUTH_TAG_LENGTH = 16;

function decodeCiphertext(payload: string) {
  const [version, encoded] = payload.split(".", 2);
  if (version !== MOBILE_AUTH_CIPHERTEXT_VERSION || !encoded) {
    throw new Error("Invalid mobile auth ciphertext");
  }

  const buffer = Buffer.from(encoded, "base64url");
  if (buffer.length <= MOBILE_AUTH_IV_LENGTH + MOBILE_AUTH_TAG_LENGTH) {
    throw new Error("Invalid mobile auth ciphertext");
  }

  return {
    iv: buffer.subarray(0, MOBILE_AUTH_IV_LENGTH),
    tag: buffer.subarray(MOBILE_AUTH_IV_LENGTH, MOBILE_AUTH_IV_LENGTH + MOBILE_AUTH_TAG_LENGTH),
    ciphertext: buffer.subarray(MOBILE_AUTH_IV_LENGTH + MOBILE_AUTH_TAG_LENGTH)
  };
}

export class MobileAuthCrypto {
  private readonly hasher: BrokerCredentialHasher;
  private readonly exchangeKey: Buffer;

  constructor(secret: string) {
    this.hasher = new BrokerCredentialHasher(secret);
    this.exchangeKey = Buffer.from(
      hkdfSync(
        "sha256",
        Buffer.from(secret, "utf8"),
        Buffer.from("remoteos-mobile-auth", "utf8"),
        Buffer.from("exchange-token", "utf8"),
        MOBILE_AUTH_KEY_LENGTH
      )
    );
  }

  hashFlowId(flowId: string) {
    return this.hasher.hash("mobile_auth_flow", flowId);
  }

  hashExchangeCode(code: string) {
    return this.hasher.hash("mobile_auth_code", code);
  }

  encryptAuthToken(authToken: string) {
    const iv = randomBytes(MOBILE_AUTH_IV_LENGTH);
    const cipher = createCipheriv("aes-256-gcm", this.exchangeKey, iv);
    const ciphertext = Buffer.concat([
      cipher.update(authToken, "utf8"),
      cipher.final()
    ]);
    const tag = cipher.getAuthTag();

    return `${MOBILE_AUTH_CIPHERTEXT_VERSION}.${Buffer.concat([
      iv,
      tag,
      ciphertext
    ]).toString("base64url")}`;
  }

  decryptAuthToken(payload: string) {
    const { iv, tag, ciphertext } = decodeCiphertext(payload);
    const decipher = createDecipheriv("aes-256-gcm", this.exchangeKey, iv);
    decipher.setAuthTag(tag);

    return Buffer.concat([
      decipher.update(ciphertext),
      decipher.final()
    ]).toString("utf8");
  }
}
