import { describe, expect, it } from "vitest";

import {
  clearSocketQueue,
  queueSocketFrame,
  queueSocketMessage
} from "../src/socketSendQueue.js";

type QueueSocket = {
  OPEN: number;
  readyState: number;
  send(data: string, callback?: (error?: Error) => void): void;
};

class FakeSocket implements QueueSocket {
  readonly OPEN = 1;
  readyState = this.OPEN;
  readonly sent: string[] = [];
  private callbacks: Array<(error?: Error) => void> = [];

  send(data: string, callback?: (error?: Error) => void) {
    this.sent.push(data);
    if (callback) {
      this.callbacks.push(callback);
    }
  }

  completeNextSend() {
    const callback = this.callbacks.shift();
    callback?.();
  }
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("socketSendQueue", () => {
  it("coalesces live frames while a previous frame is still in flight", async () => {
    const socket = new FakeSocket();

    queueSocketFrame(socket, { frame: 1 });
    queueSocketFrame(socket, { frame: 2 });
    queueSocketFrame(socket, { frame: 3 });
    await flushMicrotasks();

    expect(socket.sent).toEqual([JSON.stringify({ frame: 1 })]);

    socket.completeNextSend();
    await flushMicrotasks();

    expect(socket.sent).toEqual([
      JSON.stringify({ frame: 1 }),
      JSON.stringify({ frame: 3 })
    ]);

    clearSocketQueue(socket);
  });

  it("prioritizes control messages ahead of queued replacement frames", async () => {
    const socket = new FakeSocket();

    queueSocketFrame(socket, { frame: 1 });
    queueSocketFrame(socket, { frame: 2 });
    queueSocketMessage(socket, { jsonrpc: "2.0", id: "req_1", result: { ok: true } });
    await flushMicrotasks();

    expect(socket.sent).toEqual([JSON.stringify({ frame: 1 })]);

    socket.completeNextSend();
    await flushMicrotasks();
    socket.completeNextSend();
    await flushMicrotasks();

    expect(socket.sent).toEqual([
      JSON.stringify({ frame: 1 }),
      JSON.stringify({ jsonrpc: "2.0", id: "req_1", result: { ok: true } }),
      JSON.stringify({ frame: 2 })
    ]);

    clearSocketQueue(socket);
  });
});
