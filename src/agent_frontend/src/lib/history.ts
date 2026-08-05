import {
  SESSIONS_URL,
  historyUrl,
  sessionUrl,
  type ChatUIMessage,
  type ConversationSummary,
} from '@/lib/backend';

/** Backend-owned conversation history (session list + transcripts). Every call degrades to a safe empty result on failure. */

/** Fetch the past-conversations list (newest-first). */
export async function fetchSessions(): Promise<ConversationSummary[]> {
  try {
    const res = await fetch(SESSIONS_URL);
    if (!res.ok) throw new Error(`sessions ${res.status}`);
    const data = (await res.json()) as { conversations?: ConversationSummary[] };
    return Array.isArray(data.conversations) ? data.conversations : [];
  } catch {
    return [];
  }
}

/** Fetch a conversation's transcript, mapped to UI messages ready to seed `useChat`. */
export async function fetchHistory(sessionId: string): Promise<ChatUIMessage[]> {
  try {
    const res = await fetch(historyUrl(sessionId));
    if (!res.ok) throw new Error(`history ${res.status}`);
    const data = (await res.json()) as { messages?: { role: string; text: string }[] };
    const messages = Array.isArray(data.messages) ? data.messages : [];
    return messages.map((m) => ({
      id: crypto.randomUUID(),
      role: m.role === 'assistant' ? 'assistant' : m.role === 'system' ? 'system' : 'user',
      parts: [{ type: 'text', text: m.text }],
    }));
  } catch {
    return [];
  }
}

/** Delete a whole conversation, including its attached files. Resolves true on success (idempotent on the backend). */
export async function deleteSession(sessionId: string): Promise<boolean> {
  try {
    const res = await fetch(sessionUrl(sessionId), { method: 'DELETE' });
    return res.ok;
  } catch {
    return false;
  }
}

/** Clear a conversation's messages while keeping its attached files indexed (RAG stays scoped to the same session). */
export async function clearSession(sessionId: string): Promise<boolean> {
  try {
    const res = await fetch(sessionUrl(sessionId, true), { method: 'DELETE' });
    return res.ok;
  } catch {
    return false;
  }
}
