import type WebSocket from "ws";

type SocketLike = Pick<WebSocket, "OPEN" | "readyState" | "send">;

type SocketQueueState = {
  sending: boolean;
  controlQueue: string[];
  pendingFrame: string | null;
};

const queueStateBySocket = new WeakMap<SocketLike, SocketQueueState>();

function getQueueState(socket: SocketLike) {
  let state = queueStateBySocket.get(socket);
  if (!state) {
    state = {
      sending: false,
      controlQueue: [],
      pendingFrame: null
    };
    queueStateBySocket.set(socket, state);
  }
  return state;
}

function takeNextMessage(state: SocketQueueState) {
  const controlMessage = state.controlQueue.shift();
  if (controlMessage) {
    return controlMessage;
  }

  const frame = state.pendingFrame;
  state.pendingFrame = null;
  return frame;
}

function sendEncoded(socket: SocketLike, data: string) {
  return new Promise<void>((resolve, reject) => {
    if (socket.readyState !== socket.OPEN) {
      resolve();
      return;
    }

    socket.send(data, (error?: Error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

async function flushSocketQueue(socket: SocketLike, state: SocketQueueState) {
  try {
    while (socket.readyState === socket.OPEN) {
      const nextMessage = takeNextMessage(state);
      if (!nextMessage) {
        return;
      }

      await sendEncoded(socket, nextMessage);
    }
  } catch {
    state.controlQueue.length = 0;
    state.pendingFrame = null;
  } finally {
    state.sending = false;
    if (
      socket.readyState === socket.OPEN &&
      (state.controlQueue.length > 0 || state.pendingFrame !== null)
    ) {
      startFlush(socket, state);
    }
  }
}

function startFlush(socket: SocketLike, state: SocketQueueState) {
  if (state.sending) {
    return;
  }

  state.sending = true;
  void flushSocketQueue(socket, state);
}

export function queueSocketMessage(socket: SocketLike, payload: unknown) {
  const state = getQueueState(socket);
  state.controlQueue.push(JSON.stringify(payload));
  startFlush(socket, state);
}

export function queueSocketFrame(socket: SocketLike, payload: unknown) {
  const state = getQueueState(socket);
  state.pendingFrame = JSON.stringify(payload);
  startFlush(socket, state);
}

export function clearSocketQueue(socket: SocketLike) {
  queueStateBySocket.delete(socket);
}
