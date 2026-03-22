import type {
  AgentItem,
  AgentPrompt,
  AgentPromptResolved,
  AgentPromptResponse,
  AgentTurnStartResult,
  AgentTurn,
  CodexStatus,
  HostStatus,
  SemanticSnapshot,
  TraceEvent,
  WindowDescriptor,
  WindowFrame,
  WindowSnapshot
} from "@remoteos/contracts";
import {
  createRpcRequest,
  rpcErrorSchema,
  rpcNotificationSchema,
  rpcSuccessSchema
} from "@remoteos/contracts";
import type { RpcRequest } from "@remoteos/contracts";

type ListenerMap = {
  windows: (windows: WindowDescriptor[]) => void;
  snapshot: (snapshot: WindowSnapshot) => void;
  frame: (frame: WindowFrame) => void;
  agentTurn: (turn: AgentTurn) => void;
  agentItem: (item: AgentItem) => void;
  agentPromptRequested: (prompt: AgentPrompt) => void;
  agentPromptResolved: (payload: AgentPromptResolved) => void;
  trace: (event: TraceEvent) => void;
  hostStatus: (status: HostStatus) => void;
  codexStatus: (status: CodexStatus) => void;
  semanticDiff: (summary: string) => void;
};

export type BootstrapPayload = {
  client: {
    id: string;
    deviceId: string;
    name: string;
    token: string;
  };
  device: {
    id: string;
    name: string;
    online: boolean;
    mode: "hosted" | "direct";
  };
  windows: WindowDescriptor[];
  status: HostStatus;
  wsUrl: string;
};

const apiBaseUrlStorageKey = "remoteos.controlPlaneBaseUrl";

function normalizeBaseUrl(value: string) {
  return value.replace(/\/$/, "");
}

function getCurrentUrl() {
  if (typeof window === "undefined") {
    return new URL("http://localhost");
  }

  const href =
    window.location.href ??
    `${window.location.protocol ?? "http:"}//${window.location.hostname ?? "localhost"}${window.location.search ?? ""}`;
  return new URL(href);
}

function isLoopbackHost(hostname: string) {
  return (
    hostname === "localhost" ||
    hostname === "0.0.0.0" ||
    hostname === "::1" ||
    hostname === "[::1]" ||
    hostname.startsWith("127.")
  );
}

function rewriteLoopbackUrl(rawUrl: string) {
  if (typeof window === "undefined") {
    return normalizeBaseUrl(rawUrl);
  }

  const current = getCurrentUrl();
  const target = new URL(rawUrl, current.href);

  if (isLoopbackHost(target.hostname) && !isLoopbackHost(current.hostname)) {
    target.hostname = current.hostname;
  }

  return normalizeBaseUrl(target.toString());
}

function inferBaseUrlFromWindow() {
  if (typeof window === "undefined") {
    return "http://localhost:8787";
  }

  const current = getCurrentUrl();
  return rewriteLoopbackUrl(`${current.protocol}//${current.hostname}:8787`);
}

function bindUrlToCurrentHost(rawUrl: string) {
  if (typeof window === "undefined") {
    return normalizeBaseUrl(rawUrl);
  }

  const current = getCurrentUrl();
  const target = new URL(rawUrl, current.href);
  target.hostname = current.hostname;
  return normalizeBaseUrl(target.toString());
}

function buildControlPlaneCandidates(baseUrl: string) {
  const candidates = new Set<string>();

  const addCandidate = (value: string) => {
    if (!value) {
      return;
    }
    candidates.add(normalizeBaseUrl(value));
  };

  addCandidate(baseUrl);
  addCandidate(rewriteLoopbackUrl(baseUrl));
  addCandidate(bindUrlToCurrentHost(baseUrl));
  addCandidate(inferBaseUrlFromWindow());

  return [...candidates];
}

async function fetchControlPlaneJson<T>(
  baseUrl: string,
  path: string,
  init?: RequestInit
): Promise<{ data: T; baseUrl: string }> {
  const attempted: string[] = [];
  let lastError: Error | undefined;

  for (const candidate of buildControlPlaneCandidates(baseUrl)) {
    attempted.push(candidate);

    try {
      const response = await fetch(`${candidate}${path}`, init);
      if (!response.ok) {
        throw new Error((await response.json()).error ?? `Request failed with ${response.status}`);
      }

      return {
        data: (await response.json()) as T,
        baseUrl: candidate
      };
    } catch (error) {
      if (!(error instanceof TypeError)) {
        throw error;
      }

      lastError = error;
    }
  }

  throw new Error(
    `Failed to reach control plane. Attempted: ${attempted.join(", ")}${lastError ? ` (${lastError.message})` : ""}`
  );
}

export function resolveControlPlaneBaseUrl() {
  if (typeof window === "undefined") {
    return "http://localhost:8787";
  }

  const current = getCurrentUrl();
  const apiQuery = current.searchParams.get("api");
  if (apiQuery) {
    const resolved = rewriteLoopbackUrl(new URL(apiQuery, current.href).toString());
    window.localStorage.setItem(apiBaseUrlStorageKey, resolved);
    return resolved;
  }

  const stored = window.localStorage.getItem(apiBaseUrlStorageKey);
  if (stored) {
    return rewriteLoopbackUrl(stored);
  }

  const envBaseUrl = import.meta.env.VITE_REMOTEOS_HTTP_BASE_URL;
  if (envBaseUrl) {
    const resolved = rewriteLoopbackUrl(envBaseUrl);
    window.localStorage.setItem(apiBaseUrlStorageKey, resolved);
    return resolved;
  }

  const inferred = inferBaseUrlFromWindow();
  window.localStorage.setItem(apiBaseUrlStorageKey, inferred);
  return inferred;
}

export function storeControlPlaneBaseUrl(baseUrl: string) {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(apiBaseUrlStorageKey, rewriteLoopbackUrl(baseUrl));
}

export function resolveBrokerWebSocketUrl(wsUrl: string) {
  if (typeof window === "undefined") {
    return wsUrl;
  }

  const current = getCurrentUrl();
  const target = new URL(wsUrl, current.href);

  if (isLoopbackHost(target.hostname) && !isLoopbackHost(current.hostname)) {
    target.hostname = current.hostname;
  }

  return target.toString();
}

export async function claimPairing(baseUrl: string, pairingCode: string, clientName: string) {
  return fetchControlPlaneJson<{
    pairing: {
      id: string;
      deviceId: string;
      pairingCode: string;
      claimed: boolean;
      createdAt: string;
      expiresAt: string;
      pairingUrl: string;
    };
    clientToken: string;
    wsUrl: string;
  }>(baseUrl, `/pairings/${pairingCode}/claim`, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify({
      clientName
    })
  });
}

export async function getBootstrap(
  baseUrl: string,
  clientToken: string
): Promise<{ data: BootstrapPayload; baseUrl: string }> {
  return fetchControlPlaneJson<BootstrapPayload>(
    baseUrl,
    `/bootstrap?clientToken=${encodeURIComponent(clientToken)}`
  );
}

type PendingRequest = {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
};

export class BrokerClient {
  private socket: WebSocket | undefined;

  private readonly pending = new Map<string, PendingRequest>();

  private requestId = 0;

  constructor(
    private readonly wsUrl: string,
    private readonly listeners: Partial<ListenerMap>
  ) {}

  private rejectPending(error: Error) {
    for (const [id, pending] of this.pending) {
      pending.reject(error);
      this.pending.delete(id);
    }
  }

  connect() {
    this.rejectPending(new Error("Socket was replaced"));
    this.socket = new WebSocket(this.wsUrl);

    this.socket.addEventListener("message", (event) => {
      const parsed = JSON.parse(event.data);

      const success = rpcSuccessSchema.safeParse(parsed);
      if (success.success) {
        const pending = this.pending.get(String(success.data.id));
        if (pending) {
          pending.resolve(success.data.result);
          this.pending.delete(String(success.data.id));
        }
        return;
      }

      const error = rpcErrorSchema.safeParse(parsed);
      if (error.success) {
        const pending = this.pending.get(String(error.data.id));
        if (pending) {
          pending.reject(new Error(error.data.error.message));
          this.pending.delete(String(error.data.id));
        }
        return;
      }

      const notification = rpcNotificationSchema.safeParse(parsed);
      if (!notification.success) {
        return;
      }

      switch (notification.data.method) {
        case "windows.updated":
          this.listeners.windows?.((notification.data.params as { windows: WindowDescriptor[] }).windows);
          break;
        case "window.frame":
          this.listeners.frame?.(notification.data.params as WindowFrame);
          break;
        case "window.snapshot":
          this.listeners.snapshot?.(notification.data.params as WindowSnapshot);
          break;
        case "agent.turn":
          this.listeners.agentTurn?.(notification.data.params as AgentTurn);
          break;
        case "agent.item":
          this.listeners.agentItem?.(notification.data.params as AgentItem);
          break;
        case "agent.prompt.requested":
          this.listeners.agentPromptRequested?.(notification.data.params as AgentPrompt);
          break;
        case "agent.prompt.resolved":
          this.listeners.agentPromptResolved?.(notification.data.params as AgentPromptResolved);
          break;
        case "trace.event":
          this.listeners.trace?.(notification.data.params as TraceEvent);
          break;
        case "host.status":
          this.listeners.hostStatus?.(notification.data.params as HostStatus);
          break;
        case "codex.status":
          this.listeners.codexStatus?.(notification.data.params as CodexStatus);
          break;
        case "semantic.diff":
          this.listeners.semanticDiff?.((notification.data.params as { summary: string }).summary);
          break;
        default:
          break;
      }
    });

    this.socket.addEventListener("close", () => {
      this.rejectPending(new Error("Socket closed"));
    });

    this.socket.addEventListener("error", () => {
      this.rejectPending(new Error("Socket error"));
    });

    return this.socket;
  }

  disconnect() {
    this.rejectPending(new Error("Socket closed"));
    this.socket?.close();
    this.socket = undefined;
  }

  request<TResult = unknown>(method: RpcRequest["method"], params?: unknown): Promise<TResult> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("Socket is not open"));
    }
    const id = `${++this.requestId}`;

    return new Promise<TResult>((resolve, reject) => {
      this.pending.set(id, {
        resolve,
        reject
      });
      this.socket?.send(JSON.stringify(createRpcRequest(id, method, params)));
    });
  }

  async listWindows() {
    return this.request<{ windows: WindowDescriptor[] }>("windows.list");
  }

  async selectWindow(windowId: number) {
    return this.request("window.select", { windowId });
  }

  async startStream(windowId: number) {
    return this.request("stream.start", { windowId });
  }

  async stopStream(windowId: number) {
    return this.request("stream.stop", { windowId });
  }

  async semanticSnapshot(windowId: number) {
    return this.request<SemanticSnapshot>("semantic.snapshot", { windowId });
  }

  async tap(windowId: number, frameId: string, normalizedX: number, normalizedY: number) {
    return this.request("input.tap", {
      windowId,
      frameId,
      normalizedX,
      normalizedY,
      clickCount: 1
    });
  }

  async scroll(windowId: number, frameId: string, deltaY: number) {
    return this.request("input.scroll", {
      windowId,
      frameId,
      deltaX: 0,
      deltaY
    });
  }

  async type(windowId: number, frameId: string, text: string) {
    return this.request("input.key", {
      windowId,
      frameId,
      text
    });
  }

  async startAgent(prompt: string) {
    return this.request<AgentTurnStartResult>("agent.turn.start", { prompt });
  }

  async cancelAgent(turnId: string) {
    return this.request("agent.turn.cancel", { turnId });
  }

  async resetAgentThread() {
    return this.request("agent.thread.reset", {});
  }

  async respondAgentPrompt(response: AgentPromptResponse) {
    return this.request("agent.prompt.respond", response);
  }
}
