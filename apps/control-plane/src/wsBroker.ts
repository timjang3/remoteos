import type { FastifyInstance } from "fastify";
import type { RawData, WebSocket } from "ws";

import {
  createRpcError,
  rpcErrorSchema,
  rpcNotificationSchema,
  rpcRequestSchema,
  rpcSuccessSchema,
  windowDescriptorSchema
} from "@remoteos/contracts";
import { z } from "zod";

import type { MemoryBrokerStore } from "./store.js";

type RoutedSocket = WebSocket & { deviceId?: string };

function parseJson(data: RawData) {
  try {
    return JSON.parse(data.toString());
  } catch {
    return null;
  }
}

function send(socket: WebSocket, payload: unknown) {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

export async function registerWsBroker(
  app: FastifyInstance,
  store: MemoryBrokerStore
) {
  app.get(
    "/ws/host",
    { websocket: true },
    (socket, request) => {
      const routedSocket = socket as RoutedSocket;
      const query = z
        .object({
          deviceId: z.string().min(1),
          deviceSecret: z.string().min(1)
        })
        .parse(request.query);

      const device = store.getDevice(query.deviceId);
      if (!device || device.deviceSecret !== query.deviceSecret) {
        routedSocket.send(JSON.stringify(createRpcError(null, 401, "Unauthorized host")));
        routedSocket.close();
        return;
      }

      store.attachHost(query.deviceId, routedSocket);
      routedSocket.deviceId = query.deviceId;

      routedSocket.on("message", (raw: RawData) => {
        const message = parseJson(raw);
        if (!message) {
          send(routedSocket, createRpcError(null, -32700, "Invalid JSON"));
          return;
        }

        if ("method" in message) {
          const notification = rpcNotificationSchema.safeParse(message);
          if (notification.success) {
            if (notification.data.method === "windows.updated") {
              const parsed = z
                .object({
                  windows: z.array(windowDescriptorSchema)
                })
                .safeParse(notification.data.params);
              if (parsed.success) {
                store.updateWindows(query.deviceId, parsed.data.windows);
              }
            } else if (notification.data.method === "host.status") {
              store.updateHostStatus(query.deviceId, notification.data.params);
            }

            for (const clientSocket of store.getConnectedClientSockets(query.deviceId)) {
              send(clientSocket, notification.data);
            }
            return;
          }
        }

        const result = rpcSuccessSchema.safeParse(message);
        const error = rpcErrorSchema.safeParse(message);
        const requestMessage = rpcRequestSchema.safeParse(message);

        if (!result.success && !error.success && !requestMessage.success) {
          send(routedSocket, createRpcError(null, -32600, "Invalid JSON-RPC message"));
          return;
        }

        for (const clientSocket of store.getConnectedClientSockets(query.deviceId)) {
          send(clientSocket, message);
        }
      });

      routedSocket.on("close", () => {
        store.detachHostSocket(query.deviceId, routedSocket);
        for (const clientSocket of store.getConnectedClientSockets(query.deviceId)) {
          send(clientSocket, {
            jsonrpc: "2.0",
            method: "host.status",
            params: {
              deviceId: query.deviceId,
              online: false,
              selectedWindowId: null,
              screenRecording: "unknown",
              accessibility: "unknown",
              directUrl: null
            }
          });
        }
      });
    }
  );

  app.get(
    "/ws/client",
    { websocket: true },
    (socket, request) => {
      const routedSocket = socket as RoutedSocket;
      const query = z
        .object({
          clientToken: z.string().min(1)
        })
        .parse(request.query);

      try {
        const { session, device } = store.attachClient(query.clientToken, routedSocket);
        routedSocket.deviceId = session.deviceId;

        routedSocket.on("message", (raw: RawData) => {
          const message = parseJson(raw);
          if (!message) {
            send(routedSocket, createRpcError(null, -32700, "Invalid JSON"));
            return;
          }

          if (!device.hostSocket) {
            send(routedSocket, createRpcError(null, 503, "Host is offline"));
            return;
          }

          send(device.hostSocket, message);
        });

        routedSocket.on("close", () => {
          store.detachClientSocket(query.clientToken, routedSocket);
        });
      } catch (error) {
        send(routedSocket, createRpcError(null, 401, error instanceof Error ? error.message : "Unauthorized client"));
        routedSocket.close();
      }
    }
  );
}
