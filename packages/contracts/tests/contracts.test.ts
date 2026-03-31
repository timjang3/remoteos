import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  agentPromptResolvedSchema,
  agentPromptResponseSchema,
  agentPromptSchema,
  agentTurnStartResultSchema,
  agentTurnStartParamsSchema,
  codexStatusSchema,
  createRpcRequest,
  hostStatusSchema,
  rpcRequestSchema,
  streamStartParamsSchema,
  windowFrameSchema,
  windowDescriptorSchema,
} from "../src/index.js";

describe("contracts", () => {
  it("validates a window descriptor", () => {
    const window = windowDescriptorSchema.parse({
      id: 42,
      ownerPid: 100,
      ownerName: "Terminal",
      appBundleId: "com.apple.Terminal",
      title: "shell",
      bounds: {
        x: 1,
        y: 2,
        width: 800,
        height: 600,
      },
      isOnScreen: true,
      capabilities: ["ax_read", "pixel_fallback"],
      semanticSummary: null,
    });

    expect(window.id).toBe(42);
  });

  it("validates a captured window frame", () => {
    const frame = windowFrameSchema.parse({
      windowId: 42,
      frameId: "frame_123",
      capturedAt: "2026-03-20T17:10:00.000Z",
      mimeType: "image/webp",
      dataBase64: "ZmFrZQ==",
      width: 1440,
      height: 900,
      displayId: 69733248,
      sourceRectPoints: {
        x: -1728,
        y: 25,
        width: 1440,
        height: 900,
      },
      pointPixelScale: 2,
    });

    expect(frame.frameId).toBe("frame_123");
    expect(frame.sourceRectPoints.x).toBe(-1728);
  });

  it("creates a valid stream start request", () => {
    const request = createRpcRequest("1", "stream.start", {
      windowId: 9,
    });

    expect(rpcRequestSchema.parse(request).method).toBe("stream.start");
    expect(streamStartParamsSchema.parse(request.params)).toMatchObject({
      windowId: 9,
    });
  });

  it("parses the shared mobile stream profile fixture", () => {
    const request = JSON.parse(
      readFileSync(new URL("../fixtures/rpc-request-stream-start-balanced.json", import.meta.url), "utf8")
    );

    expect(rpcRequestSchema.parse(request).method).toBe("stream.start");
    expect(streamStartParamsSchema.parse(request.params)).toMatchObject({
      windowId: 9,
      profile: "balanced",
    });
  });

  it("creates a valid agent turn request", () => {
    const request = createRpcRequest("2", "agent.turn.start", {
      prompt: "Close the selected window.",
    });

    expect(rpcRequestSchema.parse(request).method).toBe("agent.turn.start");
    expect(agentTurnStartParamsSchema.parse(request.params)).toMatchObject({
      prompt: "Close the selected window.",
    });
  });

  it("validates the initial agent turn start result", () => {
    const startedAt = "2026-03-20T17:10:00.000Z";
    const result = agentTurnStartResultSchema.parse({
      turn: {
        id: "turn_1",
        prompt: "Close the selected window.",
        targetWindowId: null,
        status: "running",
        error: null,
        startedAt,
        updatedAt: startedAt,
        completedAt: null
      },
      userItem: {
        id: "user-turn_1",
        turnId: "turn_1",
        kind: "user_message",
        status: "completed",
        title: "User",
        body: "Close the selected window.",
        createdAt: startedAt,
        updatedAt: startedAt,
        metadata: {}
      }
    });

    expect(result.turn.id).toBe("turn_1");
    expect(result.userItem.kind).toBe("user_message");
  });

  it("validates host status with codex readiness", () => {
    const status = hostStatusSchema.parse({
      deviceId: "device_1",
      online: true,
      selectedWindowId: 42,
      screenRecording: "granted",
      accessibility: "granted",
      directUrl: null,
      codex: {
        state: "ready",
        installed: true,
        authenticated: true,
        authMode: "chatgpt",
        model: "gpt-5.4-mini",
        threadId: "thread_1",
        activeTurnId: null,
        lastError: null,
      },
    });

    expect(status.codex.state).toBe("ready");
    expect(status.selectedWindowId).toBe(42);
  });

  it("validates codex status defaults for an unavailable runtime", () => {
    const status = codexStatusSchema.parse({
      state: "missing_cli",
      installed: false,
      authenticated: false,
      authMode: null,
      model: null,
      threadId: null,
      activeTurnId: null,
      lastError: "codex CLI not installed",
    });

    expect(status.installed).toBe(false);
    expect(status.lastError).toContain("not installed");
  });

  it("validates prompt request, response, and resolution payloads", () => {
    const prompt = agentPromptSchema.parse({
      id: "prompt_1",
      turnId: "turn_1",
      source: "computer_use",
      kind: "safety_check",
      title: "Computer use needs confirmation",
      body: "Acknowledge the safety check.",
      questions: [],
      choices: [
        {
          id: "accept",
          label: "Accept",
          description: "Continue."
        }
      ],
      createdAt: "2026-03-20T17:10:00.000Z",
      updatedAt: "2026-03-20T17:10:00.000Z"
    });

    const response = agentPromptResponseSchema.parse({
      id: "prompt_1",
      action: "accept",
      answers: {}
    });

    const resolved = agentPromptResolvedSchema.parse({
      id: "prompt_1",
      turnId: "turn_1",
      status: "accepted",
      resolvedAt: "2026-03-20T17:11:00.000Z"
    });

    expect(prompt.source).toBe("computer_use");
    expect(response.action).toBe("accept");
    expect(resolved.status).toBe("accepted");
  });
});
