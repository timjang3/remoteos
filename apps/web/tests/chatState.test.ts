import { describe, expect, it } from "vitest";

import type { AgentItem } from "@remoteos/contracts";

import {
  buildDisplayedTranscript,
  buildOptimisticUserItem,
  hasVisibleAssistantOutput
} from "../src/chatState";

function makeItem(overrides: Partial<AgentItem> = {}): AgentItem {
  return {
    id: overrides.id ?? "item_1",
    turnId: overrides.turnId ?? "turn_1",
    kind: overrides.kind ?? "user_message",
    status: overrides.status ?? "completed",
    title: overrides.title ?? "Item",
    body: overrides.body ?? "Hello",
    createdAt: overrides.createdAt ?? "2026-03-20T21:00:00.000Z",
    updatedAt: overrides.updatedAt ?? "2026-03-20T21:00:00.000Z",
    metadata: overrides.metadata ?? {}
  };
}

describe("chatState", () => {
  it("adds an optimistic user message immediately and keeps transcript order stable", () => {
    const transcript = buildDisplayedTranscript(
      [
        makeItem({
          id: "assistant_1",
          turnId: "turn_0",
          kind: "assistant_message",
          title: "Codex",
          body: "Earlier reply",
          createdAt: "2026-03-20T21:00:00.000Z"
        })
      ],
      {
        id: "pending_1",
        prompt: "Do the thing",
        createdAt: "2026-03-20T21:00:05.000Z"
      }
    );

    expect(transcript.map((item) => item.id)).toEqual(["assistant_1", "pending_1"]);
    expect(transcript[1]).toEqual(
      buildOptimisticUserItem({
        id: "pending_1",
        prompt: "Do the thing",
        createdAt: "2026-03-20T21:00:05.000Z"
      })
    );
  });

  it("hides empty completed assistant and reasoning items until they have visible content", () => {
    const transcript = buildDisplayedTranscript([
      makeItem({
        id: "assistant_empty",
        kind: "assistant_message",
        title: "Codex",
        body: "",
        createdAt: "2026-03-20T21:00:01.000Z"
      }),
      makeItem({
        id: "reasoning_empty",
        kind: "reasoning",
        title: "Reasoning",
        body: "",
        createdAt: "2026-03-20T21:00:02.000Z"
      }),
      makeItem({
        id: "assistant_full",
        kind: "assistant_message",
        title: "Codex",
        body: "Visible output",
        createdAt: "2026-03-20T21:00:03.000Z"
      })
    ], null);

    expect(transcript.map((item) => item.id)).toEqual(["assistant_full"]);
  });

  it("detects when a running turn has started streaming visible assistant text", () => {
    const items = [
      makeItem({
        id: "assistant_empty",
        turnId: "turn_a",
        kind: "assistant_message",
        title: "Codex",
        body: ""
      }),
      makeItem({
        id: "assistant_full",
        turnId: "turn_b",
        kind: "assistant_message",
        title: "Codex",
        body: "Streaming"
      })
    ];

    expect(hasVisibleAssistantOutput(items, "turn_a")).toBe(false);
    expect(hasVisibleAssistantOutput(items, "turn_b")).toBe(true);
  });

  it("ignores commentary-phase assistant updates when detecting final output", () => {
    const items = [
      makeItem({
        id: "commentary",
        turnId: "turn_c",
        kind: "assistant_message",
        body: "Still inspecting",
        metadata: { phase: "commentary" }
      }),
      makeItem({
        id: "final",
        turnId: "turn_d",
        kind: "assistant_message",
        body: "Done",
        metadata: { phase: "final_answer" }
      })
    ];

    expect(hasVisibleAssistantOutput(items, "turn_c")).toBe(false);
    expect(hasVisibleAssistantOutput(items, "turn_d")).toBe(true);
  });
});
