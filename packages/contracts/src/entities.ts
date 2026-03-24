import { z } from "zod";

export function nullableWire<TSchema extends z.ZodTypeAny>(schema: TSchema) {
  return z.preprocess((value) => (value === undefined ? null : value), schema.nullable());
}

export const windowCapabilitySchema = z.enum([
  "managed_browser",
  "scriptable_native",
  "ax_read",
  "ax_write",
  "pixel_fallback",
  "generic_electron"
]);
export type WindowCapability = z.infer<typeof windowCapabilitySchema>;

export const permissionStatusSchema = z.enum([
  "unknown",
  "granted",
  "denied",
  "needs_prompt"
]);
export type PermissionStatus = z.infer<typeof permissionStatusSchema>;

export const hostModeSchema = z.enum(["hosted", "direct"]);
export type HostMode = z.infer<typeof hostModeSchema>;

export const speechProviderSchema = z.enum(["openai"]);
export type SpeechProvider = z.infer<typeof speechProviderSchema>;

export const speechCapabilitiesSchema = z.object({
  transcriptionAvailable: z.boolean(),
  provider: nullableWire(speechProviderSchema),
  maxDurationMs: z.number().int().positive(),
  maxUploadBytes: z.number().int().positive()
});
export type SpeechCapabilities = z.infer<typeof speechCapabilitiesSchema>;

export const deviceSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  mode: hostModeSchema,
  online: z.boolean(),
  registeredAt: z.string().datetime(),
  lastSeenAt: nullableWire(z.string().datetime())
});
export type Device = z.infer<typeof deviceSchema>;

export const pairingSessionSchema = z.object({
  id: z.string().min(1),
  deviceId: z.string().min(1),
  pairingCode: z.string().min(6).max(12),
  claimed: z.boolean(),
  expiresAt: z.string().datetime(),
  createdAt: z.string().datetime(),
  pairingUrl: z.string().url()
});
export type PairingSession = z.infer<typeof pairingSessionSchema>;

export const rectSchema = z.object({
  x: z.number(),
  y: z.number(),
  width: z.number().nonnegative(),
  height: z.number().nonnegative()
});
export type Rect = z.infer<typeof rectSchema>;

export const windowDescriptorSchema = z.object({
  id: z.number().int().nonnegative(),
  ownerPid: z.number().int().nonnegative(),
  ownerName: z.string(),
  appBundleId: nullableWire(z.string()),
  title: z.string(),
  bounds: rectSchema,
  isOnScreen: z.boolean(),
  capabilities: z.array(windowCapabilitySchema),
  semanticSummary: nullableWire(z.string())
});
export type WindowDescriptor = z.infer<typeof windowDescriptorSchema>;

export const windowSnapshotSchema = z.object({
  window: windowDescriptorSchema,
  capturedAt: z.string().datetime(),
  mimeType: z.enum(["image/webp", "image/jpeg", "image/png"]),
  dataBase64: z.string().min(1)
});
export type WindowSnapshot = z.infer<typeof windowSnapshotSchema>;

export const windowFrameSchema = z.object({
  windowId: z.number().int().nonnegative(),
  frameId: z.string().min(1),
  capturedAt: z.string().datetime(),
  mimeType: z.enum(["image/webp", "image/jpeg", "image/png"]),
  dataBase64: z.string().min(1),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
  displayId: nullableWire(z.number().int().nonnegative()),
  sourceRectPoints: rectSchema,
  pointPixelScale: z.number().positive()
});
export type WindowFrame = z.infer<typeof windowFrameSchema>;

export const semanticElementSchema = z.object({
  role: z.string().min(1),
  title: nullableWire(z.string()),
  value: nullableWire(z.string()),
  help: nullableWire(z.string()),
  enabled: nullableWire(z.boolean())
});
export type SemanticElement = z.infer<typeof semanticElementSchema>;

export const semanticSnapshotSchema = z.object({
  windowId: z.number().int().nonnegative(),
  focused: nullableWire(semanticElementSchema),
  elements: z.array(semanticElementSchema),
  summary: z.string(),
  generatedAt: z.string().datetime()
});
export type SemanticSnapshot = z.infer<typeof semanticSnapshotSchema>;

export const semanticDiffSchema = z.object({
  windowId: z.number().int().nonnegative(),
  changedAt: z.string().datetime(),
  summary: z.string()
});
export type SemanticDiff = z.infer<typeof semanticDiffSchema>;

export const inputTapSchema = z.object({
  windowId: z.number().int().nonnegative(),
  frameId: z.string().min(1),
  normalizedX: z.number().min(0).max(1),
  normalizedY: z.number().min(0).max(1),
  clickCount: z.number().int().positive().max(2).default(1)
});

export const inputDragSchema = z.object({
  windowId: z.number().int().nonnegative(),
  frameId: z.string().min(1),
  fromX: z.number().min(0).max(1),
  fromY: z.number().min(0).max(1),
  toX: z.number().min(0).max(1),
  toY: z.number().min(0).max(1)
});

export const inputScrollSchema = z.object({
  windowId: z.number().int().nonnegative(),
  frameId: z.string().min(1),
  deltaX: z.number(),
  deltaY: z.number()
});

export const inputKeySchema = z.object({
  windowId: z.number().int().nonnegative(),
  frameId: z.string().min(1),
  text: z.string().min(1).optional(),
  key: z.string().min(1).optional()
});

export const inputEventSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("tap"),
    payload: inputTapSchema
  }),
  z.object({
    kind: z.literal("drag"),
    payload: inputDragSchema
  }),
  z.object({
    kind: z.literal("scroll"),
    payload: inputScrollSchema
  }),
  z.object({
    kind: z.literal("key"),
    payload: inputKeySchema
  })
]);
export type InputEvent = z.infer<typeof inputEventSchema>;

export const codexRuntimeStateSchema = z.enum([
  "unknown",
  "missing_cli",
  "unauthenticated",
  "starting",
  "ready",
  "running",
  "error"
]);
export type CodexRuntimeState = z.infer<typeof codexRuntimeStateSchema>;

export const codexStatusSchema = z.object({
  state: codexRuntimeStateSchema,
  installed: z.boolean(),
  authenticated: z.boolean(),
  authMode: nullableWire(z.string()),
  model: nullableWire(z.string()),
  threadId: nullableWire(z.string()),
  activeTurnId: nullableWire(z.string()),
  lastError: nullableWire(z.string())
});
export type CodexStatus = z.infer<typeof codexStatusSchema>;

export const hostStatusSchema = z.object({
  deviceId: z.string().min(1),
  online: z.boolean(),
  selectedWindowId: nullableWire(z.number().int().nonnegative()),
  screenRecording: permissionStatusSchema,
  accessibility: permissionStatusSchema,
  directUrl: nullableWire(z.string().url()),
  codex: codexStatusSchema
});
export type HostStatus = z.infer<typeof hostStatusSchema>;

export const agentTurnStatusSchema = z.enum([
  "running",
  "completed",
  "interrupted",
  "failed"
]);
export type AgentTurnStatus = z.infer<typeof agentTurnStatusSchema>;

export const agentTurnSchema = z.object({
  id: z.string().min(1),
  prompt: z.string().min(1),
  targetWindowId: nullableWire(z.number().int().nonnegative()),
  status: agentTurnStatusSchema,
  error: nullableWire(z.string()),
  startedAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  completedAt: nullableWire(z.string().datetime())
});
export type AgentTurn = z.infer<typeof agentTurnSchema>;

export const agentItemKindSchema = z.enum([
  "user_message",
  "assistant_message",
  "reasoning",
  "plan",
  "command",
  "file_change",
  "mcp_tool",
  "dynamic_tool",
  "system"
]);
export type AgentItemKind = z.infer<typeof agentItemKindSchema>;

export const agentItemStatusSchema = z.enum([
  "in_progress",
  "completed",
  "failed",
  "declined"
]);
export type AgentItemStatus = z.infer<typeof agentItemStatusSchema>;

export const agentItemSchema = z.object({
  id: z.string().min(1),
  turnId: z.string().min(1),
  kind: agentItemKindSchema,
  status: agentItemStatusSchema,
  title: z.string().min(1),
  body: nullableWire(z.string()),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  metadata: z.record(z.string(), z.unknown()).default({})
});
export type AgentItem = z.infer<typeof agentItemSchema>;

export const agentPromptSourceSchema = z.enum(["codex", "computer_use"]);
export type AgentPromptSource = z.infer<typeof agentPromptSourceSchema>;

export const agentPromptKindSchema = z.enum(["request_user_input", "safety_check"]);
export type AgentPromptKind = z.infer<typeof agentPromptKindSchema>;

export const agentPromptResponseActionSchema = z.enum(["submit", "accept", "decline", "cancel"]);
export type AgentPromptResponseAction = z.infer<typeof agentPromptResponseActionSchema>;

export const agentPromptResolutionStatusSchema = z.enum([
  "submitted",
  "accepted",
  "declined",
  "cancelled",
  "expired",
  "interrupted"
]);
export type AgentPromptResolutionStatus = z.infer<typeof agentPromptResolutionStatusSchema>;

export const agentPromptOptionSchema = z.object({
  label: z.string().min(1),
  description: z.string().min(1)
});
export type AgentPromptOption = z.infer<typeof agentPromptOptionSchema>;

export const agentPromptQuestionSchema = z.object({
  id: z.string().min(1),
  header: z.string().min(1),
  question: z.string().min(1),
  isOther: z.boolean().default(false),
  isSecret: z.boolean().default(false),
  options: z.array(agentPromptOptionSchema).optional()
});
export type AgentPromptQuestion = z.infer<typeof agentPromptQuestionSchema>;

export const agentPromptChoiceSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  description: z.string().min(1)
});
export type AgentPromptChoice = z.infer<typeof agentPromptChoiceSchema>;

export const agentPromptSchema = z.object({
  id: z.string().min(1),
  turnId: z.string().min(1),
  source: agentPromptSourceSchema,
  kind: agentPromptKindSchema,
  title: z.string().min(1),
  body: nullableWire(z.string()),
  questions: z.array(agentPromptQuestionSchema).default([]),
  choices: z.array(agentPromptChoiceSchema).optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime()
});
export type AgentPrompt = z.infer<typeof agentPromptSchema>;

export const agentPromptAnswerSchema = z.object({
  answers: z.array(z.string())
});
export type AgentPromptAnswer = z.infer<typeof agentPromptAnswerSchema>;

export const agentPromptResponseSchema = z.object({
  id: z.string().min(1),
  action: agentPromptResponseActionSchema,
  answers: z.record(z.string(), agentPromptAnswerSchema).default({})
});
export type AgentPromptResponse = z.infer<typeof agentPromptResponseSchema>;

export const agentPromptResolvedSchema = z.object({
  id: z.string().min(1),
  turnId: z.string().min(1),
  status: agentPromptResolutionStatusSchema,
  resolvedAt: z.string().datetime()
});
export type AgentPromptResolved = z.infer<typeof agentPromptResolvedSchema>;

export const traceEventSchema = z.object({
  id: z.string().min(1),
  taskId: nullableWire(z.string()),
  level: z.enum(["info", "warning", "error"]),
  kind: z.string().min(1),
  message: z.string().min(1),
  createdAt: z.string().datetime(),
  metadata: z.record(z.string(), z.unknown()).default({})
});
export type TraceEvent = z.infer<typeof traceEventSchema>;
