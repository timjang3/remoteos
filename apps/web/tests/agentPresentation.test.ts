import { describe, expect, it } from "vitest";

import type { AgentItem, CodexStatus } from "@remoteos/contracts";

import {
  getAgentItemPresentation,
  getBusyStatusPresentation,
  getCodexHeaderChips
} from "../src/agentPresentation";

function makeItem(overrides: Partial<AgentItem> = {}): AgentItem {
  return {
    id: overrides.id ?? "item_1",
    turnId: overrides.turnId ?? "turn_1",
    kind: overrides.kind ?? "command",
    status: overrides.status ?? "completed",
    title: overrides.title ?? "echo ok",
    body: overrides.body === undefined ? "ok" : overrides.body,
    createdAt: overrides.createdAt ?? "2026-03-20T21:00:00.000Z",
    updatedAt: overrides.updatedAt ?? "2026-03-20T21:00:01.000Z",
    metadata: overrides.metadata ?? {}
  };
}

describe("agentPresentation", () => {
  it("formats command items like Codex activity rows", () => {
    expect(
      getAgentItemPresentation(
        makeItem({
          kind: "command",
          title: "pnpm test",
          body: "",
          metadata: { cwd: "/workspace/app" }
        })
      )
    ).toMatchObject({
      headline: "Ran pnpm test",
      meta: "/workspace/app",
      body: "(no output)",
      bodyMode: "code",
      tone: "success"
    });
  });

  it("formats MCP and plan items with Codex-style verbs", () => {
    expect(
      getAgentItemPresentation(
        makeItem({
          kind: "mcp_tool",
          status: "in_progress",
          title: "search.find_docs",
          body: null,
          metadata: { server: "search" }
        })
      )
    ).toMatchObject({
      headline: "Calling search.find_docs",
      meta: "MCP · search",
      tone: "active",
      statusLabel: "Running"
    });

    expect(
      getAgentItemPresentation(
        makeItem({
          kind: "plan",
          title: "Plan",
          body: "1. Inspect the bug\n2. Ship the fix"
        })
      )
    ).toMatchObject({
      headline: "Updated Plan",
      body: "1. Inspect the bug\n2. Ship the fix",
      bodyMode: "plain"
    });
  });

  it("renders commentary-phase assistant items as activity blocks", () => {
    expect(
      getAgentItemPresentation(
        makeItem({
          kind: "assistant_message",
          status: "in_progress",
          body: "Scanning the repo\n\nLooking for the render path.",
          metadata: { phase: "commentary" }
        })
      )
    ).toMatchObject({
      headline: "Scanning the repo",
      body: "Looking for the render path.",
      bodyMode: "plain",
      meta: "Commentary",
      tone: "active"
    });
  });

  it("derives a busy status row from the most recent in-progress item", () => {
    const items = [
      makeItem({
        id: "cmd",
        turnId: "turn_busy",
        kind: "command",
        status: "in_progress",
        title: "pnpm lint",
        body: "src/app.tsx"
      }),
      makeItem({
        id: "assistant",
        turnId: "turn_busy",
        kind: "assistant_message",
        status: "in_progress",
        title: "Codex",
        body: "Working..."
      })
    ];

    expect(getBusyStatusPresentation(items, "turn_busy", false)).toEqual({
      header: "Working",
      detail: "Running pnpm lint"
    });
  });

  it("builds compact header chips from Codex runtime status", () => {
    const status: CodexStatus = {
      state: "running",
      installed: true,
      authenticated: true,
      authMode: "chatgpt",
      model: "gpt-5.4",
      threadId: "thread_1234567890",
      activeTurnId: "turn_1",
      lastError: null
    };

    expect(getCodexHeaderChips(status)).toEqual(["Agent working"]);
  });
});
