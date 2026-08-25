import type { UIMessage } from 'ai';
import type { ToolCall } from '@/components/ai-elements/tool';

/** Message-level metadata the backend attaches via a `message-metadata` stream part; read through `message.metadata`. */
export type ChatMetadata = {
  tokenUsage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
    cached_details?: { read_tokens: number };
    reasoning_tokens?: number;
  };
  usedTools?: string[];
  sessionId?: string;
};

export type ChatUIMessage = UIMessage<ChatMetadata>;

/** Base URL of the C# backend (baked at build time; see .env.example / VITE_AGENT_BACKEND_URL). */
export const BACKEND_URL: string =
  import.meta.env.VITE_AGENT_BACKEND_URL ?? 'http://localhost:8000';

const ROOT = BACKEND_URL.replace(/\/$/, '');

/** The streaming endpoint that speaks the AI SDK UI Message Stream protocol. */
export const STREAM_URL = `${ROOT}/chat/stream`;

/** Characters the backend accepts in one `chatInput` (mirrors `MAX_INPUT_CHARS`; over it the backend returns 413). */
export const MAX_INPUT_CHARS = 10_000;

/** Header the backend partitions its rate limits on (mirrors `RateLimiting.SessionHeader`), since it can't read the POST body to do it. */
export const SESSION_HEADER = 'X-Session-Id';

/** Renders an RFC 7807 problem response as a display message, folding in the server's `Retry-After` hint on a 429. */
export async function problemMessage(response: Response, fallback: string): Promise<string> {
  let detail = fallback;
  try {
    const problem = await response.json();
    detail = problem.detail || problem.title || fallback;
  } catch {
    // Non-JSON body — keep the fallback.
  }

  if (response.status === 429) {
    const retryAfter = Number(response.headers.get('Retry-After'));
    if (Number.isFinite(retryAfter) && retryAfter > 0) return `${detail} (retry in ${retryAfter}s)`;
  }
  return detail;
}

/** `fetch` for the chat transport: turns a pre-stream failure (413/429/503) into a readable message. */
export const chatFetch: typeof fetch = async (input, init) => {
  const response = await fetch(input, init);
  if (!response.ok) {
    throw new Error(await problemMessage(response, `The agent request failed (${response.status}).`));
  }
  return response;
};

/** Non-secret runtime config endpoint (selectable models + default model + default system prompt). */
export const CONFIG_URL = `${ROOT}/config`;

/** Past-conversations list for the sessions sidebar (GET → { conversations: ConversationSummary[] }). */
export const SESSIONS_URL = `${ROOT}/chat/sessions`;

/** A conversation's stored transcript (GET → { sessionId, messages: {role,text}[] }). */
export const historyUrl = (sessionId: string) => `${ROOT}/chat/${encodeURIComponent(sessionId)}/messages`;

/** A conversation resource (DELETE removes the transcript; `keepFiles` leaves attachments indexed under the same session for RAG). */
export const sessionUrl = (sessionId: string, keepFiles = false) =>
  `${ROOT}/chat/${encodeURIComponent(sessionId)}${keepFiles ? '?keepFiles=true' : ''}`;

/** The original-file endpoint a citation opens (GET /files/{fileId}/content); the SPA appends sessionId to the model's `attachment://{fileId}` link. `download` forces an attachment disposition. */
export const attachmentUrl = (fileId: string, sessionId: string, download = false) =>
  `${ROOT}/files/${encodeURIComponent(fileId)}/content?sessionId=${encodeURIComponent(sessionId)}${
    download ? '&download=1' : ''
  }`;

/** One row in the sessions sidebar (see agent_backend `ConversationSummary`). */
export type ConversationSummary = {
  id: string;
  title: string;
  /** Last-message timestamp, unix seconds. */
  updatedAt: number;
};

/** Shape of GET /config (see agent_backend `ConfigResponse`). Used to seed the model controls. */
export type AppConfig = {
  models: string[];
  defaultModel: string;
};

/** Fetch the backend's non-secret config. Returns safe empty defaults if the backend is unreachable. */
export async function getConfig(): Promise<AppConfig> {
  try {
    const res = await fetch(CONFIG_URL);
    if (!res.ok) throw new Error(`config ${res.status}`);
    const data = (await res.json()) as Partial<AppConfig>;
    return {
      models: Array.isArray(data.models) ? data.models : [],
      defaultModel: data.defaultModel ?? '',
    };
  } catch {
    return { models: [], defaultModel: '' };
  }
}

/** Collapse a UI message's text parts into a single string (the backend contract takes one `chatInput`). */
export function messageText(message: ChatUIMessage): string {
  return message.parts
    .filter((part): part is { type: 'text'; text: string } => part.type === 'text')
    .map((part) => part.text)
    .join('');
}

/** A tool and every call the assistant made to it in one message (repeats grouped, first-use order). */
export type ToolGroupData = { name: string; calls: ToolCall[] };

/** Collapse a message's `dynamic-tool` parts into one group per tool name, preserving first-appearance order (repeat calls grouped together). */
export function groupToolCalls(message: ChatUIMessage): ToolGroupData[] {
  const order: string[] = [];
  const groups = new Map<string, ToolCall[]>();

  for (const part of message.parts) {
    if (part.type !== 'dynamic-tool') continue;
    if (!groups.has(part.toolName)) {
      groups.set(part.toolName, []);
      order.push(part.toolName);
    }
    groups.get(part.toolName)!.push({
      toolCallId: part.toolCallId,
      input: part.input,
      output: 'output' in part ? part.output : undefined,
      pending: part.state !== 'output-available' && part.state !== 'output-error',
    });
  }

  return order.map((name) => ({ name, calls: groups.get(name)! }));
}
