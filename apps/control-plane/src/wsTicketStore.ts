import { nanoid } from "nanoid";

export type WsTicketPayload =
  | {
      type: "host";
      deviceId: string;
    }
  | {
      type: "client";
      clientToken: string;
    };

type StoredTicket = {
  payload: WsTicketPayload;
  expiresAt: number;
};

export class WsTicketStore {
  private readonly tickets = new Map<string, StoredTicket>();

  constructor(private readonly ttlMs = 1000 * 60 * 5) {}

  private pruneExpired(now = Date.now()) {
    for (const [ticket, entry] of this.tickets) {
      if (entry.expiresAt <= now) {
        this.tickets.delete(ticket);
      }
    }
  }

  mint(payload: WsTicketPayload) {
    const now = Date.now();
    this.pruneExpired(now);

    const ticket = nanoid(24);
    this.tickets.set(ticket, {
      payload,
      expiresAt: now + this.ttlMs
    });

    return {
      ticket,
      expiresAt: new Date(now + this.ttlMs).toISOString()
    };
  }

  consume(ticket: string) {
    const now = Date.now();
    const entry = this.tickets.get(ticket);
    if (!entry) {
      return undefined;
    }

    this.tickets.delete(ticket);
    if (entry.expiresAt <= now) {
      return undefined;
    }

    return entry.payload;
  }
}
