import { z } from "zod";

import {
  agentItemSchema,
  agentPromptResolvedSchema,
  agentPromptResponseSchema,
  agentPromptSchema,
  agentTurnSchema,
  codexStatusSchema,
  hostStatusSchema,
  inputDragSchema,
  inputKeySchema,
  inputScrollSchema,
  inputTapSchema,
  semanticDiffSchema,
  semanticSnapshotSchema,
  traceEventSchema,
  windowDescriptorSchema,
  windowFrameSchema,
  windowSnapshotSchema
} from "./entities.js";

export const rpcMethodSchema = z.enum([
  "windows.list",
  "window.select",
  "stream.start",
  "stream.stop",
  "input.tap",
  "input.drag",
  "input.scroll",
  "input.key",
  "semantic.snapshot",
  "semantic.diff.subscribe",
  "agent.turn.start",
  "agent.turn.cancel",
  "agent.thread.reset",
  "agent.prompt.respond",
  "agent.config.setModel",
  "agent.state.get",
  "windows.updated",
  "window.snapshot",
  "window.frame",
  "semantic.diff",
  "agent.turn",
  "agent.item",
  "agent.prompt.requested",
  "agent.prompt.resolved",
  "trace.event",
  "host.status",
  "codex.status"
]);
export type RpcMethod = z.infer<typeof rpcMethodSchema>;

export const rpcEnvelopeSchema = z.object({
  jsonrpc: z.literal("2.0")
});

export const rpcRequestSchema = rpcEnvelopeSchema.extend({
  id: z.union([z.string(), z.number()]),
  method: rpcMethodSchema,
  params: z.unknown().optional()
});
export type RpcRequest = z.infer<typeof rpcRequestSchema>;

export const rpcSuccessSchema = rpcEnvelopeSchema.extend({
  id: z.union([z.string(), z.number()]),
  result: z.unknown()
});
export type RpcSuccess = z.infer<typeof rpcSuccessSchema>;

export const rpcErrorSchema = rpcEnvelopeSchema.extend({
  id: z.union([z.string(), z.number(), z.null()]),
  error: z.object({
    code: z.number().int(),
    message: z.string().min(1),
    data: z.unknown().optional()
  })
});
export type RpcError = z.infer<typeof rpcErrorSchema>;

export const rpcNotificationSchema = rpcEnvelopeSchema.extend({
  method: rpcMethodSchema,
  params: z.unknown().optional()
});
export type RpcNotification = z.infer<typeof rpcNotificationSchema>;

export type RpcMessage = RpcRequest | RpcSuccess | RpcError | RpcNotification;

export const windowsListResultSchema = z.object({
  windows: z.array(windowDescriptorSchema)
});

export const windowSelectParamsSchema = z.object({
  windowId: z.number().int().nonnegative()
});

export const streamStartParamsSchema = z.object({
  windowId: z.number().int().nonnegative()
});

export const streamStopParamsSchema = z.object({
  windowId: z.number().int().nonnegative()
});

export const semanticSnapshotParamsSchema = z.object({
  windowId: z.number().int().nonnegative()
});

export const semanticDiffSubscribeParamsSchema = z.object({
  windowId: z.number().int().nonnegative()
});

export const agentTurnStartParamsSchema = z.object({
  prompt: z.string().min(1)
});

export const agentTurnStartResultSchema = z.object({
  turn: agentTurnSchema,
  userItem: agentItemSchema
});
export type AgentTurnStartResult = z.infer<typeof agentTurnStartResultSchema>;

export const agentStateGetResultSchema = z.object({
  turn: agentTurnSchema.nullable(),
  items: z.array(agentItemSchema),
  prompts: z.array(agentPromptSchema)
});
export type AgentStateGetResult = z.infer<typeof agentStateGetResultSchema>;

export const agentTurnCancelParamsSchema = z.object({
  turnId: z.string().min(1)
});

export const agentThreadResetParamsSchema = z.object({}).default({});

export const agentPromptRespondParamsSchema = agentPromptResponseSchema;

export const agentConfigSetModelParamsSchema = z.object({
  modelId: z.string().min(1)
});

export const rpcParamsByMethod = {
  "window.select": windowSelectParamsSchema,
  "stream.start": streamStartParamsSchema,
  "stream.stop": streamStopParamsSchema,
  "input.tap": inputTapSchema,
  "input.drag": inputDragSchema,
  "input.scroll": inputScrollSchema,
  "input.key": inputKeySchema,
  "semantic.snapshot": semanticSnapshotParamsSchema,
  "semantic.diff.subscribe": semanticDiffSubscribeParamsSchema,
  "agent.turn.start": agentTurnStartParamsSchema,
  "agent.turn.cancel": agentTurnCancelParamsSchema,
  "agent.thread.reset": agentThreadResetParamsSchema,
  "agent.prompt.respond": agentPromptRespondParamsSchema,
  "agent.config.setModel": agentConfigSetModelParamsSchema,
  "agent.state.get": z.object({}).default({})
} as const;

export const notificationParamsByMethod = {
  "windows.updated": windowsListResultSchema,
  "window.snapshot": windowSnapshotSchema,
  "window.frame": windowFrameSchema,
  "semantic.diff": semanticDiffSchema,
  "agent.turn": agentTurnSchema,
  "agent.item": agentItemSchema,
  "agent.prompt.requested": agentPromptSchema,
  "agent.prompt.resolved": agentPromptResolvedSchema,
  "trace.event": traceEventSchema,
  "host.status": hostStatusSchema,
  "codex.status": codexStatusSchema
} as const;

export function createRpcRequest<TParams>(
  id: string | number,
  method: RpcMethod,
  params?: TParams
): RpcRequest {
  return {
    jsonrpc: "2.0",
    id,
    method,
    params
  };
}

export function createRpcNotification<TParams>(
  method: RpcMethod,
  params?: TParams
): RpcNotification {
  return {
    jsonrpc: "2.0",
    method,
    params
  };
}

export function createRpcSuccess<TResult>(
  id: string | number,
  result: TResult
): RpcSuccess {
  return {
    jsonrpc: "2.0",
    id,
    result
  };
}

export function createRpcError(
  id: string | number | null,
  code: number,
  message: string,
  data?: unknown
): RpcError {
  return {
    jsonrpc: "2.0",
    id,
    error: {
      code,
      message,
      data
    }
  };
}
