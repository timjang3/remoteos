import type { AgentItem } from "@remoteos/contracts";

import { isFinalAssistantItem } from "./agentPresentation.js";

export type PendingAgentSend = {
  id: string;
  prompt: string;
  createdAt: string;
};

function compareTranscriptItems(left: AgentItem, right: AgentItem) {
  if (left.createdAt !== right.createdAt) {
    return left.createdAt.localeCompare(right.createdAt);
  }
  return left.id.localeCompare(right.id);
}

function shouldDisplayTranscriptItem(item: AgentItem) {
  if (item.kind === "assistant_message") {
    return Boolean(item.body?.trim());
  }

  if ((item.kind === "reasoning" || item.kind === "plan") && item.status === "completed") {
    return Boolean(item.body?.trim());
  }

  return true;
}

export function buildOptimisticUserItem(pending: PendingAgentSend): AgentItem {
  return {
    id: pending.id,
    turnId: pending.id,
    kind: "user_message",
    status: "completed",
    title: "User",
    body: pending.prompt,
    createdAt: pending.createdAt,
    updatedAt: pending.createdAt,
    metadata: {
      optimistic: true
    }
  };
}

export function buildDisplayedTranscript(
  items: AgentItem[],
  pending: PendingAgentSend | null
) {
  const transcript = [...items.filter(shouldDisplayTranscriptItem)].sort(compareTranscriptItems);

  if (!pending) {
    return transcript;
  }

  return [...transcript, buildOptimisticUserItem(pending)].sort(compareTranscriptItems);
}

export function hasVisibleAssistantOutput(items: AgentItem[], turnId: string | null) {
  if (!turnId) {
    return false;
  }

  return items.some(
    (item) =>
      item.turnId === turnId &&
      isFinalAssistantItem(item) &&
      Boolean(item.body?.trim())
  );
}
