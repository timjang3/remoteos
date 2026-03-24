import type { AgentItem, AgentItemStatus, CodexStatus } from "@remoteos/contracts";

export type AgentBodyMode = "plain" | "code" | "list";
export type AgentTone = "neutral" | "active" | "success" | "danger" | "warning";

export type AgentItemPresentation = {
  headline: string;
  meta: string | null;
  body: string | null;
  bodyMode: AgentBodyMode;
  tone: AgentTone;
  statusLabel: string | null;
};

export type BusyStatusPresentation = {
  header: string;
  detail: string | null;
};

function lines(text: string | null | undefined) {
  if (!text) {
    return [];
  }

  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function statusTone(status: AgentItemStatus): AgentTone {
  switch (status) {
    case "in_progress":
      return "active";
    case "completed":
      return "success";
    case "failed":
      return "danger";
    case "declined":
      return "warning";
  }

  return "neutral";
}

function statusLabel(status: AgentItemStatus): string | null {
  switch (status) {
    case "in_progress":
      return "Running";
    case "failed":
      return "Failed";
    case "declined":
      return "Declined";
    case "completed":
      return null;
  }

  return null;
}

function countLabel(count: number, singular: string, plural = `${singular}s`) {
  return `${count} ${count === 1 ? singular : plural}`;
}

const remoteosTitleMap: Record<string, [string, string]> = {
  remoteos_window_capture: ["Capturing window", "Captured window"],
  remoteos_window_semantic_snapshot: ["Reading window", "Read window"],
  remoteos_window_focus: ["Focusing window", "Focused window"],
  remoteos_window_press_element: ["Pressing element", "Pressed element"],
  remoteos_window_type_element: ["Typing into element", "Typed into element"],
  remoteos_window_computer_use: ["Using computer", "Used computer"],
  remoteos_window_click: ["Clicking", "Clicked"],
  remoteos_window_drag: ["Dragging", "Dragged"],
  remoteos_window_scroll: ["Scrolling", "Scrolled"],
  remoteos_window_type_text: ["Typing text", "Typed text"],
  remoteos_window_press_key: ["Pressing key", "Pressed key"]
};

function getRemoteosPresentation(title: string, status: AgentItemStatus, body: string | null | undefined) {
  const entry = remoteosTitleMap[title];
  const headline = entry
    ? (status === "in_progress" ? entry[0] : entry[1])
    : (status === "in_progress" ? "Working" : "Done");

  // Extract only the first meaningful line — drop frame metadata and AI instructions
  const firstLine = body?.split(/\r?\n/).find((l) => {
    const t = l.trim();
    return t && !t.startsWith("Window:") && !t.startsWith("frame_id:") &&
      !t.startsWith("image_size:") && !t.startsWith("source_rect") &&
      !t.startsWith("point_pixel") && !t.startsWith("Prefer ") &&
      !t.startsWith("Use image") && !t.startsWith("Use accessibility");
  })?.trim() ?? null;

  return { headline, detail: firstLine };
}

function summarizeReasoning(item: AgentItem) {
  const text = item.body?.trim() || item.title;
  const [headline, ...rest] = text.split(/\n{2,}/).filter(Boolean);
  return {
    headline: headline?.trim() || "Thinking",
    body: rest.join("\n\n").trim() || null
  };
}

function summarizeAssistantCommentary(item: AgentItem) {
  const text = item.body?.trim() || item.title;
  const [headline, ...rest] = text.split(/\n{2,}/).filter(Boolean);
  return {
    headline: headline?.trim() || "Commentary",
    body: rest.join("\n\n").trim() || null
  };
}

function fileChangeCount(item: AgentItem) {
  const metadataCount = Number.parseInt(String(item.metadata.count ?? ""), 10);
  if (Number.isFinite(metadataCount) && metadataCount > 0) {
    return metadataCount;
  }

  return lines(item.body).length;
}

function latestTurnItem(items: AgentItem[], turnId: string | null) {
  if (!turnId) {
    return null;
  }

  return items
    .filter((item) => item.turnId === turnId)
    .sort((left, right) => {
      if (left.updatedAt !== right.updatedAt) {
        return right.updatedAt.localeCompare(left.updatedAt);
      }
      return right.createdAt.localeCompare(left.createdAt);
    })[0] ?? null;
}

function latestRunningTurnItem(items: AgentItem[], turnId: string | null) {
  if (!turnId) {
    return null;
  }

  return items
    .filter((item) => item.turnId === turnId && item.status === "in_progress")
    .sort((left, right) => {
      if (left.updatedAt !== right.updatedAt) {
        return right.updatedAt.localeCompare(left.updatedAt);
      }
      return right.createdAt.localeCompare(left.createdAt);
    })[0] ?? null;
}

export function getCodexHeaderChips(status: CodexStatus | null) {
  if (!status) {
    return [];
  }

  const chips: string[] = [];

  switch (status.state) {
    case "running":
      chips.push("Agent working");
      break;
    case "ready":
      chips.push("Agent ready");
      break;
    case "starting":
      chips.push("Starting up");
      break;
    case "error":
      chips.push("Error");
      break;
    case "unauthenticated":
      chips.push("Sign in required");
      break;
    case "missing_cli":
      chips.push("Unavailable");
      break;
    default:
      break;
  }

  return chips;
}

export function isCommentaryAssistantItem(item: AgentItem) {
  return item.kind === "assistant_message" && item.metadata.phase === "commentary";
}

export function isFinalAssistantItem(item: AgentItem) {
  return item.kind === "assistant_message" && item.metadata.phase !== "commentary";
}

export function getBusyStatusPresentation(
  items: AgentItem[],
  activeTurnId: string | null,
  pending: boolean
): BusyStatusPresentation {
  if (pending) {
    return {
      header: "Starting",
      detail: "Submitting your message"
    };
  }

  const activeItem = latestRunningTurnItem(items, activeTurnId);
  if (activeItem) {
    return {
      header: "Working",
      detail: getAgentItemPresentation(activeItem).headline
    };
  }

  const latestItem = latestTurnItem(items, activeTurnId);
  if (latestItem && isFinalAssistantItem(latestItem)) {
    return {
      header: "Working",
      detail: "Drafting response"
    };
  }

  return {
    header: "Working",
    detail: "Thinking"
  };
}

export function getAgentItemPresentation(item: AgentItem): AgentItemPresentation {
  const tone = statusTone(item.status);
  const common = {
    tone,
    statusLabel: statusLabel(item.status)
  };

  switch (item.kind) {
    case "reasoning": {
      const summary = summarizeReasoning(item);
      return {
        headline: summary.headline,
        meta: item.status === "in_progress" ? "Thinking" : null,
        body: summary.body,
        bodyMode: "plain",
        ...common
      };
    }
    case "plan":
      return {
        headline: "Updated Plan",
        meta: null,
        body: item.body?.trim() || null,
        bodyMode: "plain",
        ...common
      };
    case "command":
      return {
        headline: `${item.status === "in_progress" ? "Running" : "Ran"} ${item.title}`,
        meta: typeof item.metadata.cwd === "string" && item.metadata.cwd ? item.metadata.cwd : null,
        body: item.body?.trim() || (item.status === "completed" ? "(no output)" : null),
        bodyMode: "code",
        ...common
      };
    case "file_change": {
      const count = fileChangeCount(item);
      return {
        headline:
          item.status === "in_progress"
            ? "Preparing file changes"
            : `Updated ${countLabel(Math.max(count, 1), "file")}`,
        meta: count > 0 ? countLabel(count, "path") : null,
        body: item.body?.trim() || null,
        bodyMode: item.status === "in_progress" ? "code" : "list",
        ...common
      };
    }
    case "mcp_tool":
      return {
        headline: `${item.status === "in_progress" ? "Calling" : "Called"} ${item.title}`,
        meta: typeof item.metadata.server === "string" && item.metadata.server ? `MCP · ${item.metadata.server}` : "MCP",
        body: item.body?.trim() || null,
        bodyMode: "code",
        ...common
      };
    case "dynamic_tool": {
      const isRemoteos = item.title?.startsWith("remoteos_");
      const isComputerUse = item.title?.includes("computer_use");

      if (isRemoteos) {
        const rp = getRemoteosPresentation(item.title!, item.status, item.body);
        return {
          headline: rp.headline,
          meta: rp.detail,
          body: null,
          bodyMode: "plain" as AgentBodyMode,
          ...common
        };
      }

      const displayTitle = isComputerUse
        ? (item.status === "in_progress" ? "Using computer" : "Used computer")
        : `${item.status === "in_progress" ? "Calling" : "Called"} ${item.title}`;
      return {
        headline: displayTitle,
        meta: isComputerUse ? null : "Tool",
        body: isComputerUse ? null : (item.body?.trim() || null),
        bodyMode: "code" as AgentBodyMode,
        ...common
      };
    }
    case "assistant_message":
      if (isCommentaryAssistantItem(item)) {
        const summary = summarizeAssistantCommentary(item);
        return {
          headline: summary.headline,
          meta: item.status === "in_progress" ? "Commentary" : null,
          body: summary.body,
          bodyMode: "plain",
          ...common
        };
      }
      return {
        headline: item.body?.trim() || item.title,
        meta: null,
        body: null,
        bodyMode: "plain",
        ...common
      };
    case "user_message":
      return {
        headline: item.body?.trim() || item.title,
        meta: null,
        body: null,
        bodyMode: "plain",
        ...common
      };
    case "system":
      return {
        headline: item.body?.trim() || item.title,
        meta: null,
        body: null,
        bodyMode: "plain",
        ...common
      };
  }

  return {
    headline: item.body?.trim() || item.title,
    meta: null,
    body: null,
    bodyMode: "plain",
    ...common
  };
}
