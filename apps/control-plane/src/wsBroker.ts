import type { FastifyInstance } from "fastify";
import type { RawData, WebSocket } from "ws";

import {
  createRpcError,
  hostStatusSchema,
  rpcErrorSchema,
  rpcNotificationSchema,
  rpcRequestSchema,
  rpcSuccessSchema,
  windowDescriptorSchema
} from "@remoteos/contracts";
import { z } from "zod";

import type { BrokerStore } from "./storeInterface.js";
import type { WsTicketStore } from "./wsTicketStore.js";
import {
  clearSocketQueue,
  queueSocketFrame,
  queueSocketMessage
} from "./socketSendQueue.js";

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
  options: {
    store: BrokerStore;
    authMode: "none" | "required";
    wsTickets: WsTicketStore;
  }
) {
  const {
    authMode,
    store,
    wsTickets
  } = options;

  app.get(
    "/ws/host",
    { websocket: true },
    (socket, request) => {
      const routedSocket = socket as RoutedSocket;
      const hostIdentity =
        authMode === "required"
          ? (() => {
              const query = z
                .object({
                  ticket: z.string().min(1)
                })
                .parse(request.query);
              const ticket = wsTickets.consume(query.ticket);
              if (!ticket || ticket.type !== "host") {
                return undefined;
              }
              return {
                deviceId: ticket.deviceId
              };
            })()
          : (() => {
              const query = z
                .object({
                  deviceId: z.string().min(1),
                  deviceSecret: z.string().min(1)
                })
                .parse(request.query);
              const device = store.getDevice(query.deviceId);
              if (!device || device.deviceSecret !== query.deviceSecret) {
                return undefined;
              }
              return {
                deviceId: query.deviceId
              };
            })();

      if (!hostIdentity) {
        routedSocket.send(JSON.stringify(createRpcError(null, 401, "Unauthorized host")));
        routedSocket.close();
        return;
      }

      store.attachHost(hostIdentity.deviceId, routedSocket);
      routedSocket.deviceId = hostIdentity.deviceId;

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
                store.updateWindows(hostIdentity.deviceId, parsed.data.windows);
              }
            } else if (notification.data.method === "host.status") {
              const parsedStatus = hostStatusSchema.safeParse(notification.data.params);
              if (parsedStatus.success) {
                store.updateHostStatus(hostIdentity.deviceId, parsedStatus.data);
              }
            }

            for (const clientSocket of store.getConnectedClientSockets(hostIdentity.deviceId)) {
              if (notification.data.method === "window.frame") {
                queueSocketFrame(clientSocket, notification.data);
              } else {
                queueSocketMessage(clientSocket, notification.data);
              }
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

        for (const clientSocket of store.getConnectedClientSockets(hostIdentity.deviceId)) {
          queueSocketMessage(clientSocket, message);
        }
      });

      routedSocket.on("close", () => {
        store.detachHostSocket(hostIdentity.deviceId, routedSocket);
        clearSocketQueue(routedSocket);
        const status = store.getCurrentHostStatus(hostIdentity.deviceId);
        if (status) {
          for (const clientSocket of store.getConnectedClientSockets(hostIdentity.deviceId)) {
            queueSocketMessage(clientSocket, {
              jsonrpc: "2.0",
              method: "host.status",
              params: status
            });
          }
        }
      });
    }
  );

  app.get(
    "/ws/client",
    { websocket: true },
    (socket, request) => {
      const routedSocket = socket as RoutedSocket;
      const clientIdentity =
        authMode === "required"
          ? (() => {
              const query = z
                .object({
                  ticket: z.string().min(1)
                })
                .parse(request.query);
              const ticket = wsTickets.consume(query.ticket);
              if (!ticket || ticket.type !== "client") {
                return undefined;
              }
              return {
                clientToken: ticket.clientToken
              };
            })()
          : z
              .object({
                clientToken: z.string().min(1)
              })
              .parse(request.query);

      try {
        if (!clientIdentity) {
          throw new Error("Unauthorized client");
        }

        const { session, device } = store.attachClient(clientIdentity.clientToken, routedSocket);
        routedSocket.deviceId = session.deviceId;

        routedSocket.on("message", (raw: RawData) => {
          const message = parseJson(raw);
          if (!message) {
            queueSocketMessage(routedSocket, createRpcError(null, -32700, "Invalid JSON"));
            return;
          }

          if (!device.hostSocket || device.hostSocket.readyState !== device.hostSocket.OPEN) {
            store.detachHostSocket(session.deviceId, device.hostSocket);
            queueSocketMessage(routedSocket, createRpcError(null, 503, "Host is offline"));
            return;
          }

          send(device.hostSocket, message);
        });

        routedSocket.on("close", () => {
          store.detachClientSocket(clientIdentity.clientToken, routedSocket);
          clearSocketQueue(routedSocket);

          // If no clients remain, tell the host to stop streaming
          const remaining = store.getConnectedClientSockets(session.deviceId);
          if (remaining.length === 0 && device.hostSocket) {
            send(device.hostSocket, {
              jsonrpc: "2.0",
              id: `broker-cleanup-${Date.now()}`,
              method: "stream.stop",
              params: { windowId: 0 }
            });
          }
        });
      } catch (error) {
        queueSocketMessage(routedSocket, createRpcError(null, 401, error instanceof Error ? error.message : "Unauthorized client"));
        routedSocket.close();
      }
    }
  );
}
