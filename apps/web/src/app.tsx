import type {
  AgentItem,
  AgentPrompt,
  AgentTurn,
  CodexStatus,
  HostStatus,
  SemanticSnapshot,
  TraceEvent,
  WindowDescriptor,
  WindowFrame,
  WindowSnapshot
} from "@remoteos/contracts";

import React, { useCallback, useEffect, useMemo, useRef, useState, useTransition, startTransition } from "react";


import {
  BrokerClient,
  claimPairing,
  createWsTicket,
  getBootstrap,
  getResolvedControlPlaneAuthMode,
  resolveBrokerWebSocketUrl,
  resolveControlPlaneBaseUrl,
  storeControlPlaneBaseUrl
} from "./api.js";
import { createControlPlaneAuthClient } from "./authClient.js";

import { BottomSheet } from "./components/BottomSheet.js";
import { RemoteOSBrandHeader, RemoteOSLogoMark } from "./components/RemoteOSBranding.js";
import {
  getAgentItemPresentation,
  getCodexHeaderChips,
  isCommentaryAssistantItem,
  isFinalAssistantItem
} from "./agentPresentation.js";
import {
  buildDisplayedTranscript,
  type PendingAgentSend
} from "./chatState.js";
import {
  clearStoredToken,
  getStoredToken,
  logoutWebSession,
  setStoredToken
} from "./session.js";
import "./app.css";

const AVAILABLE_MODELS = [
  { id: "gpt-5.4", name: "GPT-5.4", description: "Most capable" },
  { id: "gpt-5.4-mini", name: "GPT-5.4 Mini", description: "Fast & capable" },
  { id: "gpt-5.3-codex", name: "Codex 5.3", description: "Coding optimized" },
  { id: "gpt-5.3-codex-spark", name: "Codex Spark", description: "Quick coding" },
  { id: "gpt-5.2-codex", name: "Codex 5.2", description: "Coding optimized" },
  { id: "gpt-5.2", name: "GPT-5.2", description: "General purpose" },
  { id: "gpt-5.1-codex-max", name: "Codex Max", description: "Extended thinking" },
  { id: "gpt-5.1-codex-mini", name: "Codex Mini", description: "Lightweight" },
];

const MODEL_DISPLAY: Record<string, string> = Object.fromEntries(
  AVAILABLE_MODELS.map((m) => [m.id, m.name])
);

function getModelDisplayName(modelId: string | null | undefined): string {
  if (!modelId) return "Model";
  return MODEL_DISPLAY[modelId] ?? modelId;
}

/**
 * Convert a base64-encoded frame to an object URL.
 * Object URLs are far cheaper for the browser to render than data URLs
 * because the browser doesn't need to re-parse megabytes of base64 on
 * every img src change.
 */
function frameToObjectUrl(frame: WindowFrame): string {
  const binary = atob(frame.dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const blob = new Blob([bytes], { type: frame.mimeType });
  return URL.createObjectURL(blob);
}

/**
 * Hook that converts incoming WindowFrames to object URLs, throttled to
 * the display refresh rate so we never queue more React re-renders than
 * the screen can paint.  Revokes stale URLs to prevent memory leaks.
 */
function useThrottledFrameUrl(frame: WindowFrame | undefined, paused?: boolean): string | null {
  const [url, setUrl] = useState<string | null>(null);
  const prevUrlRef = useRef<string | null>(null);
  const pendingFrameRef = useRef<WindowFrame | undefined>(undefined);
  const rafIdRef = useRef<number>(0);

  useEffect(() => {
    if (!frame) {
      if (prevUrlRef.current) {
        URL.revokeObjectURL(prevUrlRef.current);
        prevUrlRef.current = null;
      }
      setUrl(null);
      return;
    }

    // Stash the latest frame; the RAF callback always processes the newest one.
    pendingFrameRef.current = frame;

    // When paused (tab hidden), skip rendering — the latest frame will be
    // picked up automatically when the tab becomes visible again.
    if (paused) return;

    if (rafIdRef.current) return; // already scheduled

    rafIdRef.current = requestAnimationFrame(() => {
      rafIdRef.current = 0;
      const pending = pendingFrameRef.current;
      if (!pending) return;
      pendingFrameRef.current = undefined;

      const nextUrl = frameToObjectUrl(pending);
      if (prevUrlRef.current) {
        URL.revokeObjectURL(prevUrlRef.current);
      }
      prevUrlRef.current = nextUrl;
      setUrl(nextUrl);
    });
  }, [frame, paused]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (rafIdRef.current) cancelAnimationFrame(rafIdRef.current);
      if (prevUrlRef.current) URL.revokeObjectURL(prevUrlRef.current);
    };
  }, []);

  return url;
}

export function isInvalidClientError(message: string) {
  return /unknown client|unauthorized client/i.test(message);
}

function upsertAgentItem(items: AgentItem[], next: AgentItem) {
  const index = items.findIndex((item) => item.id === next.id);
  if (index === -1) {
    return [...items, next];
  }
  const updated = [...items];
  updated[index] = next;
  return updated;
}

function upsertAgentPrompt(prompts: AgentPrompt[], next: AgentPrompt) {
  const index = prompts.findIndex((prompt) => prompt.id === next.id);
  if (index === -1) {
    return [...prompts, next];
  }
  const updated = [...prompts];
  updated[index] = next;
  return updated;
}

function isOptimisticItem(item: AgentItem) {
  return item.metadata.optimistic === true;
}

function createPendingSendId() {
  return `pending-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

type ConnectionState = "idle" | "pairing" | "bootstrapping" | "connecting" | "connected" | "error";
type PromptAction = "submit" | "accept" | "decline" | "cancel";

function WindowsIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="3" width="7" height="9" rx="1" />
      <rect x="14" y="3" width="7" height="5" rx="1" />
      <rect x="14" y="12" width="7" height="9" rx="1" />
      <rect x="3" y="16" width="7" height="5" rx="1" />
    </svg>
  );
}

function SendIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M22 2L11 13" />
      <path d="M22 2l-7 20-4-9-9-4 20-7z" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <rect x="6" y="6" width="12" height="12" rx="2" />
    </svg>
  );
}

function NewChatIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
    </svg>
  );
}

function ChevronDownIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="6 9 12 15 18 9" />
    </svg>
  );
}

function SpinnerIcon({ size = 14 }: { size?: number }) {
  return (
    <svg className="tool-spinner" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
      <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="20 6 9 17 4 12" />
    </svg>
  );
}

function XIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

function PersonIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
      <circle cx="12" cy="7" r="4" />
    </svg>
  );
}

function ActivityStatusIcon({ item }: { item: AgentItem }) {
  if (item.status === "in_progress") {
    return <SpinnerIcon size={12} />;
  }

  if (item.status === "failed") {
    return <XIcon />;
  }

  if (item.status === "declined") {
    return <span className="activity-bullet activity-bullet-warning">•</span>;
  }

  if (item.status === "completed") {
    if (item.kind === "command" || item.kind === "file_change") {
      return <CheckIcon />;
    }
    return <span className="activity-bullet activity-bullet-success">•</span>;
  }

  return <span className="activity-bullet">•</span>;
}

function ActivityBody({
  item
}: {
  item: AgentItem;
}) {
  const presentation = getAgentItemPresentation(item);
  if (!presentation.body) {
    return null;
  }

  if (presentation.bodyMode === "list") {
    return (
      <div className="activity-body activity-body-list">
        {presentation.body.split(/\r?\n/).filter(Boolean).map((line) => (
          <div key={line} className="activity-list-line">{line}</div>
        ))}
      </div>
    );
  }

  if (presentation.bodyMode === "code") {
    return <pre className="activity-body activity-body-code">{presentation.body}</pre>;
  }

  return <div className="activity-body activity-body-plain">{presentation.body}</div>;
}

function ActivityBlock({ item, traceEvents }: { item: AgentItem; traceEvents?: TraceEvent[] }) {
  const presentation = getAgentItemPresentation(item);
  const statusMeta = [presentation.meta, presentation.statusLabel].filter(Boolean).join(" · ");

  const isComputerUse = item.kind === "dynamic_tool" && item.title?.includes("computer_use");
  const isRemoteos = item.kind === "dynamic_tool" && item.title?.startsWith("remoteos_");
  const hideBody = isComputerUse || isRemoteos;
  const latestCuStep = isComputerUse && item.status === "in_progress" && traceEvents
    ? traceEvents.filter((e) => e.kind === "computer_use").at(-1) ?? null
    : null;

  return (
    <div className={`activity-block activity-tone-${presentation.tone}`}>
      <div className="activity-block-header">
        <div className={`activity-status-icon activity-status-icon-${presentation.tone}`}>
          <ActivityStatusIcon item={item} />
        </div>
        <div className="activity-block-copy">
          <div className="activity-block-headline">
            {presentation.headline}
            {latestCuStep ? <span className="cua-current-action"> — {latestCuStep.message}</span> : null}
          </div>
          {statusMeta && (isRemoteos || !hideBody) ? <div className="activity-block-meta">{statusMeta}</div> : null}
        </div>
      </div>
      {hideBody ? null : <ActivityBody item={item} />}
    </div>
  );
}

function TracePanel({ events }: { events: TraceEvent[] }) {
  const filtered = events.filter((e) => e.kind !== "computer_use");
  if (filtered.length === 0) {
    return null;
  }

  return (
    <details className="trace-panel">
      <summary className="trace-panel-summary">Agent traces</summary>
      <div className="trace-panel-body">
        {filtered.map((event) => (
          <div key={event.id} className={`trace-line trace-line-${event.level}`}>
            <span className="trace-line-kind">{event.kind}</span>
            <span className="trace-line-message">{event.message}</span>
          </div>
        ))}
      </div>
    </details>
  );
}

function ChatTranscript({
  transcript,
  agentTurn,
  selectedWindow,
  showHomeState,
  streamingAssistantItemId,
  traceEvents,
  onOpenWindows,
  chatEndRef
}: {
  transcript: AgentItem[];
  agentTurn: AgentTurn | null;
  selectedWindow: WindowDescriptor | null;
  showHomeState: boolean;
  streamingAssistantItemId: string | null;
  traceEvents: TraceEvent[];
  onOpenWindows: () => void;
  chatEndRef: React.RefObject<HTMLDivElement | null>;
}) {
  const shouldShowEmptyState = showHomeState || (transcript.length === 0 && !agentTurn);

  return (
    <div className="chat-messages">
      {shouldShowEmptyState ? (
        <div className="chat-empty-state">
          {!selectedWindow ? (
            <>
              <div className="chat-empty-brand">
                <RemoteOSLogoMark decorative size={38} />
              </div>
              <p className="chat-empty-title">Welcome to RemoteOS</p>
              <p className="chat-empty-subtitle">
                Select a window to get started, or ask the agent anything.
              </p>
              <button className="chat-empty-action" onClick={onOpenWindows}>
                Select a window
              </button>
            </>
          ) : (
            <>
              <p className="chat-empty-title">Ready to help</p>
              <p className="chat-empty-subtitle">
                Ask the agent to do something on your Mac.
              </p>
            </>
          )}
        </div>
      ) : (
        <div className="transcript-items">
          {transcript.map((item) => {
            const isUser = item.kind === "user_message";
            const isAssistant = isFinalAssistantItem(item);
            const isOptimistic = isOptimisticItem(item);

            if (isUser) {
              return (
                <div
                  key={item.id}
                  className={`user-prompt ${isOptimistic ? "user-prompt-pending" : ""}`}
                >
                  <div className="user-prompt-bubble">{item.body || item.title}</div>
                </div>
              );
            }

            if (isAssistant) {
              return (
                <div
                  key={item.id}
                  className={`assistant-output ${streamingAssistantItemId === item.id ? "assistant-streaming" : ""}`}
                >
                  <div className="assistant-output-text">{item.body || item.title}</div>
                </div>
              );
            }

            if (isCommentaryAssistantItem(item)) {
              return <ActivityBlock key={item.id} item={item} traceEvents={traceEvents} />;
            }

            return <ActivityBlock key={item.id} item={item} traceEvents={traceEvents} />;
          })}
        </div>
      )}

      <div ref={chatEndRef} />
    </div>
  );
}

function PromptCard({
  prompt,
  submitting,
  onSubmit
}: {
  prompt: AgentPrompt;
  submitting: boolean;
  onSubmit: (promptId: string, action: PromptAction, answers?: Record<string, { answers: string[] }>) => Promise<void>;
}) {
  const [selectedOptions, setSelectedOptions] = useState<Record<string, string>>({});
  const [textAnswers, setTextAnswers] = useState<Record<string, string>>({});
  const [validationError, setValidationError] = useState<string | null>(null);

  const buildAnswers = useCallback(() => {
    const answers: Record<string, { answers: string[] }> = {};

    for (const question of prompt.questions) {
      const selectedValue = selectedOptions[question.id];
      const typedValue = textAnswers[question.id]?.trim() ?? "";
      const resolvedValue =
        selectedValue === "__other__" || !selectedValue
          ? typedValue
          : selectedValue;

      if (!resolvedValue) {
        return null;
      }

      answers[question.id] = {
        answers: [resolvedValue]
      };
    }

    return answers;
  }, [prompt.questions, selectedOptions, textAnswers]);

  const submitQuestions = useCallback(async () => {
    const answers = buildAnswers();
    if (!answers) {
      setValidationError("Answer every prompt before continuing.");
      return;
    }
    setValidationError(null);
    await onSubmit(prompt.id, "submit", answers);
  }, [buildAnswers, onSubmit, prompt.id]);

  const submitChoice = useCallback(async (choiceId: string) => {
    if (choiceId === "accept" || choiceId === "decline" || choiceId === "cancel") {
      await onSubmit(prompt.id, choiceId);
    }
  }, [onSubmit, prompt.id]);

  return (
    <div className="agent-prompt-card">
      <div className="agent-prompt-header">
        <div>
          <div className="agent-prompt-eyebrow">
            {prompt.source === "computer_use" ? "Computer Use" : "Codex"}
          </div>
          <div className="agent-prompt-title">{prompt.title}</div>
        </div>
        {submitting ? <SpinnerIcon size={14} /> : null}
      </div>

      {prompt.body ? <div className="agent-prompt-body">{prompt.body}</div> : null}

      {prompt.questions.length > 0 ? (
        <div className="agent-prompt-questions">
          {prompt.questions.map((question: AgentPrompt["questions"][number]) => {
            const selectedValue = selectedOptions[question.id] ?? "";
            const showTextInput = !question.options?.length || selectedValue === "__other__";

            return (
              <div key={question.id} className="agent-prompt-question">
                <label className="agent-prompt-label">
                  <span className="agent-prompt-label-header">{question.header}</span>
                  <span>{question.question}</span>
                </label>

                {question.options?.length ? (
                  <select
                    className="agent-prompt-select"
                    value={selectedValue}
                    disabled={submitting}
                    onChange={(event) => {
                      setValidationError(null);
                      setSelectedOptions((current) => ({
                        ...current,
                        [question.id]: event.target.value
                      }));
                    }}
                  >
                    <option value="">Select an option</option>
                    {question.options.map((option: NonNullable<AgentPrompt["questions"][number]["options"]>[number]) => (
                      <option key={option.label} value={option.label}>
                        {option.label}
                      </option>
                    ))}
                    {question.isOther ? <option value="__other__">Other</option> : null}
                  </select>
                ) : null}

                {showTextInput ? (
                  <input
                    className="agent-prompt-input"
                    type={question.isSecret ? "password" : "text"}
                    value={textAnswers[question.id] ?? ""}
                    disabled={submitting}
                    onChange={(event) => {
                      setValidationError(null);
                      setTextAnswers((current) => ({
                        ...current,
                        [question.id]: event.target.value
                      }));
                    }}
                    placeholder={question.isSecret ? "Enter a secret value" : "Enter your answer"}
                  />
                ) : null}
              </div>
            );
          })}

          {validationError ? <div className="agent-prompt-error">{validationError}</div> : null}

          <button
            className="agent-prompt-button agent-prompt-button-primary"
            disabled={submitting}
            onClick={() => void submitQuestions()}
          >
            Continue
          </button>
        </div>
      ) : null}

      {prompt.choices?.length ? (
        <div className="agent-prompt-actions">
          {prompt.choices.map((choice: NonNullable<AgentPrompt["choices"]>[number]) => (
            <button
              key={choice.id}
              className={`agent-prompt-button ${choice.id === "accept" ? "agent-prompt-button-primary" : ""}`}
              disabled={submitting}
              onClick={() => void submitChoice(choice.id)}
            >
              {choice.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export function App() {
  const [controlPlaneBaseUrl] = useState(() => resolveControlPlaneBaseUrl());
  const [clientName, setClientName] = useState("Phone");
  const [pairingCode, setPairingCode] = useState(() =>
    typeof window === "undefined" ? "" : new URLSearchParams(window.location.search).get("code") ?? ""
  );
  const [connectionState, setConnectionState] = useState<ConnectionState>("idle");
  const [error, setError] = useState<string | null>(null);

  const [windows, setWindows] = useState<WindowDescriptor[]>([]);
  const [selectedWindowId, setSelectedWindowId] = useState<number | null>(null);
  const [frame, setFrame] = useState<WindowFrame | undefined>();
  const [snapshots, setSnapshots] = useState<Record<number, WindowSnapshot>>({});
  const [semanticSnapshot, setSemanticSnapshot] = useState<SemanticSnapshot | null>(null);
  const [semanticDiff, setSemanticDiff] = useState<string | null>(null);

  const [agentPrompt, setAgentPrompt] = useState("");
  const [agentTurn, setAgentTurn] = useState<AgentTurn | null>(null);
  const [agentItems, setAgentItems] = useState<AgentItem[]>([]);
  const [agentPrompts, setAgentPrompts] = useState<AgentPrompt[]>([]);
  const [pendingAgentSend, setPendingAgentSend] = useState<PendingAgentSend | null>(null);
  const [submittingPromptIds, setSubmittingPromptIds] = useState<Set<string>>(new Set());
  const [chatError, setChatError] = useState<string | null>(null);
  const [hostStatus, setHostStatus] = useState<HostStatus | null>(null);
  const [codexStatus, setCodexStatus] = useState<CodexStatus | null>(null);
  const [traceEvents, setTraceEvents] = useState<TraceEvent[]>([]);

  const [showWindows, setShowWindows] = useState(false);
  const [showModelPicker, setShowModelPicker] = useState(false);
  const [showAccount, setShowAccount] = useState(false);
  const [showHomeState, setShowHomeState] = useState(false);
  const [tabVisible, setTabVisible] = useState(true);
  const [isAgentStartPending, startAgentStartTransition] = useTransition();
  const [activeBrokerConnectionId, setActiveBrokerConnectionId] = useState(0);

  const authClient = useMemo(
    () => createControlPlaneAuthClient(controlPlaneBaseUrl),
    [controlPlaneBaseUrl]
  );
  const session = authClient.useSession();
  const clientRef = useRef<BrokerClient | null>(null);
  const chatEndRef = useRef<HTMLDivElement>(null);
  const chatInputRef = useRef<HTMLTextAreaElement>(null);
  const previousBrokerConnectionIdRef = useRef(0);
  const showHomeStateRef = useRef(false);

  const selectedWindow = useMemo(
    () => windows.find((window) => window.id === selectedWindowId) ?? null,
    [selectedWindowId, windows]
  );
  const frameUrl = useThrottledFrameUrl(frame, !tabVisible);
  const isShowingHomeState = showHomeState && selectedWindow === null;

  useEffect(() => {
    showHomeStateRef.current = showHomeState;
  }, [showHomeState]);

  useEffect(() => {
    function handleVisibility() {
      setTabVisible(document.visibilityState === "visible");
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, []);

  // ── Virtual keyboard handling ──────────────────────────────
  // Use the visualViewport API to resize the session container to the
  // visible area. This keeps the composer above the keyboard while the
  // rest of the layout stays stationary (no full-page reflow).
  useEffect(() => {
    const viewport = window.visualViewport;
    if (!viewport) return;

    let raf: number | null = null;

    function update() {
      raf = null;
      const session = document.querySelector(".session") as HTMLElement | null;
      if (!session || !viewport) return;

      session.style.height = `${viewport.height}px`;
      session.style.transform = `translateY(${viewport.offsetTop}px)`;
    }

    function scheduleUpdate() {
      if (raf !== null) return;
      raf = requestAnimationFrame(update);
    }

    viewport.addEventListener("resize", scheduleUpdate);
    viewport.addEventListener("scroll", scheduleUpdate);
    update();

    return () => {
      viewport.removeEventListener("resize", scheduleUpdate);
      viewport.removeEventListener("scroll", scheduleUpdate);
      if (raf !== null) cancelAnimationFrame(raf);
    };
  }, []);

  // Prevent iOS from scrolling the window when focusing inputs.
  // Our layout is position:fixed, so any window scroll is unwanted.
  useEffect(() => {
    function resetScroll() {
      if (window.scrollY !== 0 || window.scrollX !== 0) {
        window.scrollTo(0, 0);
      }
    }
    window.addEventListener("scroll", resetScroll);
    return () => window.removeEventListener("scroll", resetScroll);
  }, []);

  // Pre-compute blob URLs for snapshot thumbnails to avoid inline base64 data URLs
  const snapshotUrlsRef = useRef<Record<number, string>>({});
  const snapshotUrls = useMemo(() => {
    const next: Record<number, string> = {};
    for (const [idStr, snapshot] of Object.entries(snapshots)) {
      const id = Number(idStr);
      // Reuse existing blob URL if the snapshot hasn't changed (same capturedAt)
      const existing = snapshotUrlsRef.current[id];
      if (existing) {
        // We can't easily compare — just revoke and recreate.
        // Snapshots update infrequently so this is fine.
        URL.revokeObjectURL(existing);
      }
      const binary = atob(snapshot.dataBase64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      const blob = new Blob([bytes], { type: snapshot.mimeType });
      next[id] = URL.createObjectURL(blob);
    }
    // Revoke any URLs for windows that no longer have snapshots
    for (const [idStr, url] of Object.entries(snapshotUrlsRef.current)) {
      if (!(Number(idStr) in next)) {
        URL.revokeObjectURL(url);
      }
    }
    snapshotUrlsRef.current = next;
    return next;
  }, [snapshots]);

  const transcript = useMemo(
    () => buildDisplayedTranscript(agentItems, pendingAgentSend),
    [agentItems, pendingAgentSend]
  );
  const activeAssistantTurnId = agentTurn?.status === "running" ? agentTurn.id : null;
  const streamingAssistantItemId = useMemo(() => {
    if (!activeAssistantTurnId) {
      return null;
    }

    for (let index = transcript.length - 1; index >= 0; index -= 1) {
      const item = transcript[index]!;
      if (
        item.turnId === activeAssistantTurnId &&
        isFinalAssistantItem(item) &&
        item.body?.trim()
      ) {
        return item.id;
      }
    }

    return null;
  }, [activeAssistantTurnId, transcript]);
  const codexHeaderChips = useMemo(
    () => getCodexHeaderChips(codexStatus),
    [codexStatus]
  );

  const clearClientSessionState = useCallback(() => {
    clientRef.current?.disconnect();
    clientRef.current = null;
    setWindows([]);
    setSelectedWindowId(null);
    setFrame(undefined);
    setSnapshots({});
    setSemanticSnapshot(null);
    setSemanticDiff(null);
    setAgentTurn(null);
    setAgentItems([]);
    setAgentPrompts([]);
    setPendingAgentSend(null);
    setSubmittingPromptIds(new Set());
    setChatError(null);
    setHostStatus(null);
    setCodexStatus(null);
    setTraceEvents([]);
    setShowWindows(false);
    setShowModelPicker(false);
    showHomeStateRef.current = false;
    setShowHomeState(false);
    setActiveBrokerConnectionId(0);
    previousBrokerConnectionIdRef.current = 0;
    setConnectionState("idle");
  }, []);

  const resetExpiredSession = useCallback((message: string) => {
    clearStoredToken();
    clearClientSessionState();
    setError(message);
  }, [clearClientSessionState]);

  useEffect(() => {
    const token = getStoredToken();
    if (!token) return;

    let cancelled = false;
    let bootstrapBroker: BrokerClient | null = null;

    async function bootstrap() {
      setConnectionState("bootstrapping");
      try {
        const bootstrapResult = await getBootstrap(controlPlaneBaseUrl, token!);
        const payload = bootstrapResult.data;
        storeControlPlaneBaseUrl(bootstrapResult.baseUrl);
        if (cancelled) return;

        setWindows(payload.windows);
        setHostStatus(payload.status);
        setCodexStatus(payload.status.codex);
        setSelectedWindowId(payload.status.selectedWindowId ?? null);
        showHomeStateRef.current = false;
        setShowHomeState(false);
        setConnectionState("connecting");
        const authMode = getResolvedControlPlaneAuthMode();
        const wsTicketResult =
          authMode === "required"
            ? await createWsTicket(bootstrapResult.baseUrl, {
                type: "client",
                clientToken: token!
              })
            : null;
        const wsUrl = wsTicketResult?.data.wsUrl ?? payload.wsUrl;
        if (wsTicketResult) {
          storeControlPlaneBaseUrl(wsTicketResult.baseUrl);
        }

        const broker = new BrokerClient(resolveBrokerWebSocketUrl(wsUrl), {
          windows(updated) {
            setWindows(updated);
          },
          snapshot(snapshot) {
            setSnapshots((prev) => ({ ...prev, [snapshot.window.id]: snapshot }));
          },
          frame(nextFrame) {
            setFrame(nextFrame);
          },
          agentTurn(nextTurn) {
            startTransition(() => {
              setChatError(null);
              if (nextTurn.status !== "running") {
                setPendingAgentSend(null);
              }
              setAgentTurn(nextTurn);
            });
          },
          agentItem(nextItem) {
            startTransition(() => {
              if (nextItem.kind === "user_message") {
                setPendingAgentSend(null);
              }
              setAgentItems((prev) => upsertAgentItem(prev, nextItem));
            });
          },
          agentPromptRequested(nextPrompt) {
            startTransition(() => {
              setAgentPrompts((current) => upsertAgentPrompt(current, nextPrompt));
            });
          },
          agentPromptResolved(payload) {
            startTransition(() => {
              setAgentPrompts((current) => current.filter((prompt) => prompt.id !== payload.id));
              setSubmittingPromptIds((current) => {
                const next = new Set(current);
                next.delete(payload.id);
                return next;
              });
            });
          },
          trace(event) {
            setTraceEvents((prev) => [event, ...prev].slice(0, 24));
          },
          hostStatus(status) {
            setHostStatus(status);
            setCodexStatus(status.codex);
            const nextSelectedWindowId = status.selectedWindowId ?? null;
            if (nextSelectedWindowId === null || !showHomeStateRef.current) {
              setSelectedWindowId(nextSelectedWindowId);
            }
          },
          codexStatus(status) {
            setCodexStatus(status);
          },
          semanticDiff(summary) {
            setSemanticDiff(summary);
          }
        });
        bootstrapBroker = broker;

        const socket = broker.connect();
        socket.addEventListener("open", async () => {
          if (cancelled) {
            broker.disconnect();
            return;
          }
          setConnectionState("connected");
          clientRef.current = broker;
          setActiveBrokerConnectionId((current) => current + 1);
          try {
            const listed = await broker.listWindows();
            setWindows(listed.windows);
          } catch (err) {
            setError(err instanceof Error ? err.message : "Failed to list windows");
          }
        });
        socket.addEventListener("close", () => {
          if (cancelled) {
            return;
          }
          if (clientRef.current === broker) {
            clientRef.current = null;
          }
          setActiveBrokerConnectionId(0);
          setConnectionState("idle");
        });
      } catch (err) {
        if (!cancelled) {
          const message = err instanceof Error ? err.message : "Failed to bootstrap";
          if (isInvalidClientError(message)) {
            resetExpiredSession("This client session expired. Pair again with the code shown on your Mac.");
            return;
          }
          setConnectionState("error");
          setError(message);
        }
      }
    }

    void bootstrap();
    return () => {
      cancelled = true;
      bootstrapBroker?.disconnect();
      if (clientRef.current === bootstrapBroker) {
        clientRef.current = null;
      }
    };
  }, [controlPlaneBaseUrl, resetExpiredSession]);

  const refreshSemanticSnapshot = useCallback(async (windowId: number) => {
    if (!clientRef.current) return;
    try {
      setSemanticSnapshot(await clientRef.current.semanticSnapshot(windowId));
    } catch {
      setSemanticSnapshot(null);
    }
  }, []);

  useEffect(() => {
    if (!selectedWindowId || !clientRef.current || activeBrokerConnectionId === 0) return;
    void refreshSemanticSnapshot(selectedWindowId);
  }, [activeBrokerConnectionId, refreshSemanticSnapshot, selectedWindowId]);

  useEffect(() => {
    if (activeBrokerConnectionId === 0) {
      previousBrokerConnectionIdRef.current = 0;
      return;
    }

    if (previousBrokerConnectionIdRef.current === activeBrokerConnectionId) {
      return;
    }
    previousBrokerConnectionIdRef.current = activeBrokerConnectionId;

    if (!selectedWindowId || !clientRef.current) {
      return;
    }

    void clientRef.current.startStream(selectedWindowId).catch(() => {});
  }, [activeBrokerConnectionId, selectedWindowId]);

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({
      behavior: pendingAgentSend || agentTurn?.status === "running" ? "auto" : "smooth"
    });
  }, [agentTurn, pendingAgentSend, transcript]);

  // Stop streaming when the tab/browser closes so the host doesn't keep capturing
  useEffect(() => {
    function handlePageHide() {
      const socket = clientRef.current?.getRawSocket();
      if (socket && socket.readyState === WebSocket.OPEN && selectedWindowId) {
        socket.send(JSON.stringify({
          jsonrpc: "2.0",
          id: `cleanup-${Date.now()}`,
          method: "stream.stop",
          params: { windowId: selectedWindowId }
        }));
      }
    }
    window.addEventListener("pagehide", handlePageHide);
    return () => window.removeEventListener("pagehide", handlePageHide);
  }, [selectedWindowId]);

  async function handlePairing() {
    setConnectionState("pairing");
    setError(null);
    setChatError(null);
    try {
      const result = await claimPairing(
        controlPlaneBaseUrl,
        pairingCode.trim().toUpperCase(),
        clientName
      );
      storeControlPlaneBaseUrl(result.baseUrl);
      if (typeof window !== "undefined") {
        setStoredToken(result.data.clientToken);
        window.location.reload();
      }
    } catch (err) {
      setConnectionState("error");
      setError(err instanceof Error ? err.message : "Failed to pair");
    }
  }

  async function handleSelectWindow(windowId: number) {
    if (!clientRef.current) return;
    showHomeStateRef.current = false;
    setShowHomeState(false);
    setSelectedWindowId(windowId);
    setFrame(undefined);
    setShowWindows(false);
    setAgentItems([]);
    setAgentTurn(null);
    setAgentPrompts([]);
    setPendingAgentSend(null);
    setSubmittingPromptIds(new Set());
    await clientRef.current.resetAgentThread();
    await clientRef.current.selectWindow(windowId);
  }

  async function handleDeselectWindow() {
    if (!clientRef.current || !selectedWindowId) return;
    const windowId = selectedWindowId;
    if (agentTurn?.status === "running") {
      void clientRef.current.cancelAgent(agentTurn.id);
    }
    showHomeStateRef.current = true;
    setShowHomeState(true);
    setSelectedWindowId(null);
    setFrame(undefined);
    setSemanticSnapshot(null);
    setSemanticDiff(null);
    setChatError(null);
    try {
      await clientRef.current.stopStream(windowId);
    } catch {
      // Stream may already be stopped
    }
  }

  async function handleAgent() {
    const prompt = agentPrompt.trim();
    if (!prompt || pendingAgentSend || agentTurn?.status === "running") return;

    if (!clientRef.current || connectionState !== "connected" || hostStatus?.online === false) {
      setChatError("Connecting to your Mac. Wait a moment and try again.");
      return;
    }

    showHomeStateRef.current = false;
    setShowHomeState(false);
    setChatError(null);
    const pendingSend: PendingAgentSend = {
      id: createPendingSendId(),
      prompt,
      createdAt: new Date().toISOString()
    };
    setPendingAgentSend(pendingSend);
    setAgentPrompt("");
    if (chatInputRef.current) {
      chatInputRef.current.style.height = "auto";
    }
    const broker = clientRef.current;

    startAgentStartTransition(async () => {
      try {
        if (!broker) {
          throw new Error("Socket is not open");
        }
        const result = await broker.startAgent(prompt);
        startTransition(() => {
          setChatError(null);
          setPendingAgentSend(null);
          setAgentTurn(result.turn);
          setAgentItems((current) => upsertAgentItem(current, result.userItem));
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : "Failed to send message";
        startTransition(() => {
          setPendingAgentSend(null);
          if (isInvalidClientError(message)) {
            resetExpiredSession("This client session expired. Pair again with the code shown on your Mac.");
            return;
          }
          setAgentPrompt((current) => (current.trim() ? current : prompt));
          setChatError(message);
        });
      }
    });
  }

  function handleAgentKeyDown(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void handleAgent();
    }
  }

  async function handleResetThread() {
    if (!clientRef.current) return;
    setAgentItems([]);
    setAgentTurn(null);
    setAgentPrompts([]);
    setPendingAgentSend(null);
    setSubmittingPromptIds(new Set());
    await clientRef.current.resetAgentThread();
  }

  async function handleAgentPromptResponse(
    promptId: string,
    action: PromptAction,
    answers?: Record<string, { answers: string[] }>
  ) {
    if (!clientRef.current) {
      setChatError("Connecting to your Mac. Wait a moment and try again.");
      return;
    }

    setChatError(null);
    setSubmittingPromptIds((current) => {
      const next = new Set(current);
      next.add(promptId);
      return next;
    });

    try {
      await clientRef.current.respondAgentPrompt({
        id: promptId,
        action,
        answers: answers ?? {}
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to answer prompt";
      setChatError(message);
      setSubmittingPromptIds((current) => {
        const next = new Set(current);
        next.delete(promptId);
        return next;
      });
    }
  }

  function openWindowsSheet() {
    setShowWindows(true);
  }

  async function handleSelectModel(modelId: string) {
    if (!clientRef.current) return;
    setShowModelPicker(false);
    try {
      await clientRef.current.setAgentModel(modelId);
    } catch (err) {
      setChatError(err instanceof Error ? err.message : "Failed to set model");
    }
  }

  async function handleDisconnect() {
    setError(null);
    setChatError(null);
    clearClientSessionState();

    try {
      await logoutWebSession(authClient);
      window.location.assign(window.location.pathname);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to log out");
    }
  }

  const isConnected = connectionState === "connected";
  const hasToken = !!getStoredToken();
  const requiresControlPlaneSignIn = getResolvedControlPlaneAuthMode() === "required";
  const isCodexReady =
    codexStatus?.state === "ready" ||
    codexStatus?.state === "running";
  const isAgentReady = isConnected && !!clientRef.current && hostStatus?.online !== false && isCodexReady;
  const isAgentBusy = pendingAgentSend !== null || agentTurn?.status === "running";
  const canSendAgentPrompt = isAgentReady && !!agentPrompt.trim() && !isAgentBusy;
  const chatStatusMessage =
    chatError ??
    agentTurn?.error ??
    ((!isAgentReady && codexStatus?.lastError) ? codexStatus.lastError : null);

  if (!hasToken) {
    return (
      <div className="pairing-screen">
        <RemoteOSBrandHeader
          title="RemoteOS"
          subtitle="Control your Mac from anywhere. Enter the pairing code shown on your computer."
        />
        <div className="pairing-form">
          <input
            className="pairing-input code-input"
            value={pairingCode}
            onChange={(event) => setPairingCode(event.target.value)}
            placeholder="ABC123"
            autoCapitalize="characters"
            maxLength={12}
          />
          <input
            className="pairing-input"
            value={clientName}
            onChange={(event) => setClientName(event.target.value)}
            placeholder="Device name"
          />
          <button
            className="pairing-button"
            onClick={() => void handlePairing()}
            disabled={connectionState === "pairing" || !pairingCode.trim()}
          >
            {connectionState === "pairing" ? "Connecting..." : "Connect"}
          </button>
          {error ? <p className="pairing-error">{error}</p> : null}
        </div>
      </div>
    );
  }

  return (
    <div className="session">
      <div className="chat-view">
        <div className="chat-window-header">
          <div className="chat-window-header-left">
            <div className={`status-dot ${isConnected && hostStatus?.online ? "online" : "offline"}`} />
            <span className="chat-window-title">
              {selectedWindow ? selectedWindow.title : "RemoteOS"}
            </span>
          </div>
          <button className="model-select-btn" onClick={() => setShowModelPicker(true)}>
            <span>{getModelDisplayName(codexStatus?.model)}</span>
            <ChevronDownIcon />
          </button>
          <div className="chat-window-header-actions">
            <button
              className="chat-header-btn"
              onClick={() => void handleResetThread()}
              aria-label="New chat"
            >
              <NewChatIcon />
            </button>
            <button className="chat-header-btn" onClick={openWindowsSheet}>
              <WindowsIcon />
            </button>
            <button className="chat-header-btn" onClick={() => setShowAccount(true)} aria-label="Account">
              {requiresControlPlaneSignIn && session.data?.user ? (
                <span className="account-btn-initial">
                  {(session.data.user.name || session.data.user.email || "U")[0]!.toUpperCase()}
                </span>
              ) : (
                <PersonIcon />
              )}
            </button>
          </div>
        </div>

        {selectedWindow && frameUrl ? (
          <div className="window-preview">
            <img src={frameUrl} alt={selectedWindow.title} draggable={false} />
            <button
              className="window-preview-close"
              onClick={() => void handleDeselectWindow()}
              aria-label="Stop streaming"
            >
              <XIcon />
            </button>
          </div>
        ) : selectedWindow ? (
          <div className="window-preview window-preview-loading">
            <p>Loading...</p>
            <button
              className="window-preview-close"
              onClick={() => void handleDeselectWindow()}
              aria-label="Stop streaming"
            >
              <XIcon />
            </button>
          </div>
        ) : null}

        <ChatTranscript
          transcript={transcript}
          agentTurn={agentTurn}
          selectedWindow={selectedWindow}
          showHomeState={isShowingHomeState}
          streamingAssistantItemId={streamingAssistantItemId}
          traceEvents={traceEvents}
          onOpenWindows={openWindowsSheet}
          chatEndRef={chatEndRef}
        />

        {!isShowingHomeState && agentPrompts.length > 0 ? (
          <div className="agent-prompts">
            {agentPrompts.map((prompt) => (
              <PromptCard
                key={prompt.id}
                prompt={prompt}
                submitting={submittingPromptIds.has(prompt.id)}
                onSubmit={handleAgentPromptResponse}
              />
            ))}
          </div>
        ) : null}

        <div className="chat-composer">
          <textarea
            ref={chatInputRef}
            className="chat-composer-input"
            value={agentPrompt}
            onChange={(event) => {
              if (chatError) {
                setChatError(null);
              }
              setAgentPrompt(event.target.value);
              const el = event.target;
              el.style.height = "auto";
              el.style.height = `${Math.min(el.scrollHeight, 120)}px`;
            }}
            onFocus={() => {
              // Scroll chat to bottom when keyboard opens so latest messages stay visible
              setTimeout(() => {
                chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
              }, 300);
            }}
            onKeyDown={handleAgentKeyDown}
            disabled={!isAgentReady}
            enterKeyHint="send"
            placeholder={
              isAgentReady
                ? "Ask Codex to answer or act..."
                : hostStatus?.online === false || !isConnected
                  ? "Connecting to your Mac..."
                  : codexStatus?.state === "starting"
                    ? "Preparing Codex..."
                    : "Codex is unavailable..."
            }
            rows={1}
          />
          {agentTurn?.status === "running" ? (
            <button
              className="chat-composer-stop"
              onClick={() => void clientRef.current?.cancelAgent(agentTurn.id)}
            >
              <StopIcon />
            </button>
          ) : pendingAgentSend ? (
            <button
              className={`chat-composer-send chat-composer-send-pending ${isAgentStartPending ? "pending" : ""}`}
              disabled
            >
              <div className="chat-composer-pending-spinner" />
            </button>
          ) : (
            <button
              className="chat-composer-send"
              disabled={!canSendAgentPrompt}
              onClick={() => void handleAgent()}
            >
              <SendIcon />
            </button>
          )}
        </div>

        {chatStatusMessage ? (
          <div className="chat-error-msg">{chatStatusMessage}</div>
        ) : null}

        {hasToken && !isConnected ? (
          <div className="disconnected-banner">
            <p>
              {connectionState === "bootstrapping"
                ? "Connecting to your Mac..."
                : connectionState === "connecting"
                  ? "Establishing stream..."
                  : connectionState === "error"
                    ? (error ?? "Connection failed")
                    : "Disconnected"}
            </p>
            {connectionState === "error" ? (
              <button className="reconnect-btn" onClick={() => window.location.reload()}>
                Retry
              </button>
            ) : null}
          </div>
        ) : null}
      </div>

      <BottomSheet
        open={showWindows}
        onClose={() => setShowWindows(false)}
        title={`Windows (${windows.length})`}
      >
        {windows.length === 0 ? (
          <div className="empty-windows">
            <p>No windows available. Make sure your Mac has visible or shareable windows open.</p>
          </div>
        ) : (
          <div className="window-grid">
            {windows.map((window) => (
              <div
                key={window.id}
                className={`window-item ${selectedWindowId === window.id ? "selected" : ""}`}
                onClick={() => void handleSelectWindow(window.id)}
              >
                {snapshotUrls[window.id] ? (
                  <img
                    className="window-item-thumb"
                    src={snapshotUrls[window.id]}
                    alt={window.title}
                    draggable={false}
                    loading="lazy"
                  />
                ) : (
                  <div className="window-item-thumb" />
                )}
                <div className="window-item-info">
                  <span className="window-item-title">{window.ownerName}</span>
                  {window.title !== window.ownerName ? (
                    <span className="window-item-app">{window.title}</span>
                  ) : null}
                </div>
                {selectedWindowId === window.id ? (
                  <div className="window-item-badge">
                    <div className="live-dot" />
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        )}

      </BottomSheet>

      <BottomSheet
        open={showModelPicker}
        onClose={() => setShowModelPicker(false)}
        title="Select Model"
      >
        <div className="model-picker-list">
          {AVAILABLE_MODELS.map((model) => (
            <div
              key={model.id}
              className={`model-picker-item ${codexStatus?.model === model.id ? "selected" : ""}`}
              onClick={() => void handleSelectModel(model.id)}
            >
              <div className="model-picker-item-info">
                <div className="model-picker-item-name">{model.name}</div>
                <div className="model-picker-item-desc">{model.description}</div>
              </div>
              {codexStatus?.model === model.id ? (
                <div className="model-picker-item-check">
                  <CheckIcon />
                </div>
              ) : null}
            </div>
          ))}
        </div>
      </BottomSheet>

      <BottomSheet
        open={showAccount}
        onClose={() => setShowAccount(false)}
        title="Account"
      >
        {requiresControlPlaneSignIn && session.data?.user ? (
          <div className="account-user-info">
            <div className="account-user-avatar">
              {(session.data.user.name || session.data.user.email || "U")[0]!.toUpperCase()}
            </div>
            <div>
              {session.data.user.name ? (
                <div className="account-user-name">{session.data.user.name}</div>
              ) : null}
              <div className="account-user-email">{session.data.user.email}</div>
            </div>
          </div>
        ) : (
          <div className="account-user-info">
            <div className="account-user-avatar">
              {(clientName || "P")[0]!.toUpperCase()}
            </div>
            <div>
              <div className="account-user-name">{clientName || "Phone"}</div>
              <div className="account-user-email">Connected to Mac</div>
            </div>
          </div>
        )}
        <button
          className="account-signout-btn"
          onClick={() => { setShowAccount(false); void handleDisconnect(); }}
        >
          {requiresControlPlaneSignIn ? "Sign out" : "Disconnect"}
        </button>
      </BottomSheet>
    </div>
  );
}
