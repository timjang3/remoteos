import { and, eq, gt, lte } from "drizzle-orm";
import { nanoid } from "nanoid";

import type { ControlPlaneDb } from "./db/index.js";
import {
  mobileAuthExchanges,
  mobileAuthFlows
} from "./db/index.js";
import { MobileAuthCrypto } from "./mobileAuthCrypto.js";
import type {
  CreateMobileAuthExchangeInput,
  CreateMobileAuthFlowInput,
  MobileAuthExchange,
  MobileAuthFlow,
  MobileAuthStore
} from "./mobileAuthStore.js";

type MobileAuthFlowRow = typeof mobileAuthFlows.$inferSelect;
type MobileAuthExchangeRow = typeof mobileAuthExchanges.$inferSelect;

function serializeFlow(row: MobileAuthFlowRow, id: string): MobileAuthFlow {
  return {
    id,
    provider: row.provider,
    redirectUri: row.redirectUri,
    createdAt: row.createdAt.toISOString(),
    expiresAt: row.expiresAt.toISOString()
  };
}

function serializeExchange(
  row: MobileAuthExchangeRow,
  code: string,
  authToken: string
): MobileAuthExchange {
  return {
    code,
    authToken,
    user: {
      id: row.userId,
      name: row.userName,
      email: row.userEmail,
      image: row.userImage
    },
    createdAt: row.createdAt.toISOString(),
    expiresAt: row.expiresAt.toISOString()
  };
}

export class PostgresMobileAuthStore implements MobileAuthStore {
  private readonly crypto: MobileAuthCrypto;

  constructor(
    private readonly db: ControlPlaneDb,
    secret: string,
    private readonly flowTtlMs = 10 * 60_000,
    private readonly exchangeTtlMs = 5 * 60_000
  ) {
    this.crypto = new MobileAuthCrypto(secret);
  }

  private async pruneExpired(now: Date) {
    await Promise.all([
      this.db
        .delete(mobileAuthFlows)
        .where(lte(mobileAuthFlows.expiresAt, now)),
      this.db
        .delete(mobileAuthExchanges)
        .where(lte(mobileAuthExchanges.expiresAt, now))
    ]);
  }

  async createFlow(input: CreateMobileAuthFlowInput): Promise<MobileAuthFlow> {
    const now = new Date();
    await this.pruneExpired(now);

    const id = nanoid(24);
    const createdAt = now;
    const expiresAt = new Date(now.getTime() + this.flowTtlMs);

    await this.db.insert(mobileAuthFlows).values({
      flowIdHash: this.crypto.hashFlowId(id),
      provider: input.provider,
      redirectUri: input.redirectUri,
      createdAt,
      expiresAt
    });

    return {
      id,
      provider: input.provider,
      redirectUri: input.redirectUri,
      createdAt: createdAt.toISOString(),
      expiresAt: expiresAt.toISOString()
    };
  }

  async consumeFlow(id: string): Promise<MobileAuthFlow | undefined> {
    const now = new Date();
    await this.pruneExpired(now);

    const [row] = await this.db
      .delete(mobileAuthFlows)
      .where(
        and(
          eq(mobileAuthFlows.flowIdHash, this.crypto.hashFlowId(id)),
          gt(mobileAuthFlows.expiresAt, now)
        )
      )
      .returning();

    return row ? serializeFlow(row, id) : undefined;
  }

  async createExchange(input: CreateMobileAuthExchangeInput): Promise<MobileAuthExchange> {
    const now = new Date();
    await this.pruneExpired(now);

    const code = nanoid(32);
    const createdAt = now;
    const expiresAt = new Date(now.getTime() + this.exchangeTtlMs);

    await this.db.insert(mobileAuthExchanges).values({
      codeHash: this.crypto.hashExchangeCode(code),
      authTokenCiphertext: this.crypto.encryptAuthToken(input.authToken),
      userId: input.user.id,
      userName: input.user.name,
      userEmail: input.user.email,
      userImage: input.user.image,
      createdAt,
      expiresAt
    });

    return {
      code,
      authToken: input.authToken,
      user: input.user,
      createdAt: createdAt.toISOString(),
      expiresAt: expiresAt.toISOString()
    };
  }

  async consumeExchange(code: string): Promise<MobileAuthExchange | undefined> {
    const now = new Date();
    await this.pruneExpired(now);

    const [row] = await this.db
      .delete(mobileAuthExchanges)
      .where(
        and(
          eq(mobileAuthExchanges.codeHash, this.crypto.hashExchangeCode(code)),
          gt(mobileAuthExchanges.expiresAt, now)
        )
      )
      .returning();

    if (!row) {
      return undefined;
    }

    return serializeExchange(
      row,
      code,
      this.crypto.decryptAuthToken(row.authTokenCiphertext)
    );
  }
}
