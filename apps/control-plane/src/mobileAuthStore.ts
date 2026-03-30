import { nanoid } from "nanoid";

export type MobileAuthProvider = "google";

export type MobileAuthUser = {
  id: string;
  name: string;
  email: string;
  image: string | null;
};

export type MobileAuthFlow = {
  id: string;
  provider: MobileAuthProvider;
  redirectUri: string;
  createdAt: string;
  expiresAt: string;
};

export type MobileAuthExchange = {
  code: string;
  authToken: string;
  user: MobileAuthUser;
  createdAt: string;
  expiresAt: string;
};

export class MobileAuthStore {
  private readonly flows = new Map<string, MobileAuthFlow>();
  private readonly exchanges = new Map<string, MobileAuthExchange>();

  constructor(
    private readonly flowTtlMs = 10 * 60_000,
    private readonly exchangeTtlMs = 5 * 60_000
  ) {}

  private cleanup(now = Date.now()) {
    for (const [id, flow] of this.flows) {
      if (new Date(flow.expiresAt).getTime() <= now) {
        this.flows.delete(id);
      }
    }

    for (const [code, exchange] of this.exchanges) {
      if (new Date(exchange.expiresAt).getTime() <= now) {
        this.exchanges.delete(code);
      }
    }
  }

  createFlow(input: {
    provider: MobileAuthProvider;
    redirectUri: string;
  }): MobileAuthFlow {
    this.cleanup();
    const createdAt = new Date().toISOString();
    const flow: MobileAuthFlow = {
      id: nanoid(24),
      provider: input.provider,
      redirectUri: input.redirectUri,
      createdAt,
      expiresAt: new Date(Date.now() + this.flowTtlMs).toISOString()
    };
    this.flows.set(flow.id, flow);
    return flow;
  }

  getFlow(id: string) {
    this.cleanup();
    return this.flows.get(id);
  }

  consumeFlow(id: string) {
    this.cleanup();
    const flow = this.flows.get(id);
    if (!flow) {
      return undefined;
    }

    this.flows.delete(id);
    return flow;
  }

  createExchange(input: {
    authToken: string;
    user: MobileAuthUser;
  }): MobileAuthExchange {
    this.cleanup();
    const createdAt = new Date().toISOString();
    const exchange: MobileAuthExchange = {
      code: nanoid(32),
      authToken: input.authToken,
      user: input.user,
      createdAt,
      expiresAt: new Date(Date.now() + this.exchangeTtlMs).toISOString()
    };
    this.exchanges.set(exchange.code, exchange);
    return exchange;
  }

  consumeExchange(code: string) {
    this.cleanup();
    const exchange = this.exchanges.get(code);
    if (!exchange) {
      return undefined;
    }

    this.exchanges.delete(code);
    return exchange;
  }
}
