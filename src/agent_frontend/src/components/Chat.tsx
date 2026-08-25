import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';
import { Bot, Check, Copy, Eraser, Wrench } from 'lucide-react';
import {
  MAX_INPUT_CHARS,
  SESSION_HEADER,
  STREAM_URL,
  chatFetch,
  messageText,
  groupToolCalls,
  type ChatUIMessage,
} from '@/lib/backend';
import { clearSession } from '@/lib/history';
import { ACCEPT, PollCancelledError, pollFileStatus, uploadFile, validateFile, type FileAttachment } from '@/lib/files';
import type { ReasoningEffort } from '@/lib/settings';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { Conversation } from '@/components/ai-elements/conversation';
import { Message } from '@/components/ai-elements/message';
import { Response } from '@/components/ai-elements/response';
import { Reasoning } from '@/components/ai-elements/reasoning';
import { ToolGroup } from '@/components/ai-elements/tool';
import { PromptInput } from '@/components/ai-elements/prompt-input';
import { AttachmentList } from '@/components/AttachmentPanel';

const USER_NAME = 'Web User';

export function Chat({
  sessionId,
  initialMessages,
  reasoningEffort,
  model,
  ragOnly,
  onTurnComplete,
  onFilesChanged,
  onOpenAttachment,
}: {
  sessionId: string;
  // Prior turns for a reopened conversation ([] for a new chat); seeds `useChat` at init (parent gates rendering + `key={sessionId}` remount).
  initialMessages: ChatUIMessage[];
  reasoningEffort: ReasoningEffort;
  model: string;
  // When true, ground answers strictly in attached documents (RAG only, no general model knowledge).
  ragOnly: boolean;
  // Fired when an assistant turn finishes streaming, so App can refresh the sessions list.
  onTurnComplete?: () => void;
  // Fired when a file upload is accepted or reaches a terminal state, so App can refresh the files panel.
  onFilesChanged?: () => void;
  // Opens a cited attachment in the shared preview popup (owned by App).
  onOpenAttachment: (fileId: string, label: string) => void;
}) {
  // Read the latest settings at send-time without rebuilding the transport (which would drop useChat state).
  const effortRef = useRef(reasoningEffort);
  effortRef.current = reasoningEffort;
  const modelRef = useRef(model);
  modelRef.current = model;
  const ragOnlyRef = useRef(ragOnly);
  ragOnlyRef.current = ragOnly;

  // Custom transport: the backend owns history (keyed by sessionId), so send only the request fields, not the AI SDK's default full `messages` array.
  const transport = useMemo(
    () =>
      new DefaultChatTransport<ChatUIMessage>({
        api: STREAM_URL,
        // Turns a pre-stream 413/429/503 into a readable error for the banner below.
        fetch: chatFetch,
        prepareSendMessagesRequest({ id, messages }) {
          const last = messages[messages.length - 1] as ChatUIMessage | undefined;
          return {
            // The backend rate-limits per conversation and can't read the body to partition on it.
            headers: { [SESSION_HEADER]: id },
            body: {
              sessionId: id,
              chatInput: last ? messageText(last) : '',
              userName: USER_NAME,
              reasoningEffort: effortRef.current,
              model: modelRef.current || undefined,
              ragOnly: ragOnlyRef.current,
            },
          };
        },
      }),
    [],
  );

  const { messages, sendMessage, status, error, stop, setMessages } = useChat<ChatUIMessage>({
    id: sessionId,
    messages: initialMessages,
    transport,
    onFinish: () => onTurnComplete?.(),
  });

  // "Clear chat" confirmation: wipes this conversation's transcript but keeps its attachments (same sessionId ⇒ RAG stays scoped to them).
  const [confirmClear, setConfirmClear] = useState(false);
  const clearChat = useCallback(async () => {
    setConfirmClear(false);
    await clearSession(sessionId);
    setMessages([]);
    onTurnComplete?.(); // the conversation is now empty — refresh the sessions sidebar
  }, [sessionId, setMessages, onTurnComplete]);

  // File attachments: poll status until indexed/failed; the prompt box stays locked while any is still processing (`uploading` = uploading or indexing).
  const [attachments, setAttachments] = useState<FileAttachment[]>([]);
  const indexing = attachments.some((a) => a.status === 'uploading');

  // Client ids of attachments whose polling should stop (removed, or the whole view unmounted).
  const cancelledRef = useRef<Set<string>>(new Set());
  useEffect(() => {
    const cancelled = cancelledRef.current;
    return () => {
      // Cancel every in-flight poll when this conversation view unmounts (e.g. New chat).
      cancelled.clear();
      cancelled.add('*');
    };
  }, []);
  const isCancelled = useCallback((id: string) => cancelledRef.current.has(id) || cancelledRef.current.has('*'), []);

  const ingest = useCallback(
    async (id: string, file: File) => {
      try {
        const accepted = await uploadFile(sessionId, file);
        setAttachments((prev) => prev.map((a) => (a.id === id ? { ...a, fileId: accepted.fileId } : a)));
        onFilesChanged?.(); // now `processing` server-side

        const final = await pollFileStatus(sessionId, accepted.fileId, () => isCancelled(id));
        setAttachments((prev) =>
          prev.map((a) =>
            a.id === id
              ? final.status === 'indexed'
                ? { ...a, status: 'indexed', chunkCount: final.chunkCount }
                : { ...a, status: 'error', error: final.error ?? 'Indexing failed.' }
              : a,
          ),
        );
        onFilesChanged?.(); // terminal state — refresh the panel's status/chunk count
      } catch (err) {
        if (err instanceof PollCancelledError) return; // attachment removed / view gone — drop silently
        setAttachments((prev) =>
          prev.map((a) =>
            a.id === id ? { ...a, status: 'error', error: err instanceof Error ? err.message : 'Upload failed.' } : a,
          ),
        );
      }
    },
    [sessionId, isCancelled, onFilesChanged],
  );

  const addFiles = useCallback(
    (files: FileList) => {
      for (const file of Array.from(files)) {
        const id = crypto.randomUUID();
        const invalid = validateFile(file);
        setAttachments((prev) => [
          ...prev,
          {
            id,
            name: file.name,
            size: file.size,
            file,
            status: invalid ? 'error' : 'uploading',
            error: invalid ?? undefined,
          },
        ]);
        if (!invalid) void ingest(id, file);
      }
    },
    [ingest],
  );

  const removeAttachment = useCallback((id: string) => {
    cancelledRef.current.add(id); // stop any in-flight poll for this attachment
    setAttachments((prev) => prev.filter((a) => a.id !== id));
  }, []);

  const retryAttachment = useCallback(
    (id: string) => {
      cancelledRef.current.delete(id); // re-enable polling for this attachment
      setAttachments((prev) => prev.map((a) => (a.id === id ? { ...a, status: 'uploading', error: undefined } : a)));
      const att = attachments.find((a) => a.id === id);
      if (att) void ingest(id, att.file);
    },
    [attachments, ingest],
  );

  const busy = status === 'submitted' || status === 'streaming';
  const isEmpty = messages.length === 0;

  return (
    <div className="flex h-full flex-col">
      {isEmpty ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-3 px-4 text-center">
          <div className="flex h-12 w-12 items-center justify-center rounded-2xl border border-[var(--color-accent)]/40 bg-[var(--color-accent)]/15 text-[var(--color-accent)]">
            <Bot className="h-6 w-6" />
          </div>
          <h2 className="text-lg font-semibold">How can I help?</h2>
          <p className="max-w-sm text-sm text-[var(--color-muted)]">
            Ask questions, get answers, and explore your documents. Attach files to ground the agent in your own data.
          </p>
        </div>
      ) : (
        <Conversation>
          {messages.map((message) =>
            message.role === 'assistant' ? (
              <AssistantMessage key={message.id} message={message} onOpenAttachment={onOpenAttachment} />
            ) : (
              <div key={message.id} className="flex flex-col gap-1">
                <Message role={message.role}>
                  {/* User/system text is shown verbatim — markdown rendering is reserved for assistant answers. */}
                  <div className="whitespace-pre-wrap break-words">{messageText(message)}</div>
                </Message>
              </div>
            ),
          )}
          {status === 'submitted' && (
            <Message role="assistant">
              <span className="inline-flex gap-1 text-[var(--color-muted)]">
                <Dot /> <Dot /> <Dot />
              </span>
            </Message>
          )}
        </Conversation>
      )}

      {error && (
        <div className="mx-auto mb-2 w-full max-w-3xl px-4">
          <div className="rounded-xl border border-red-500/40 bg-red-500/10 px-3 py-2 text-sm text-red-300">
            {error.message || 'The agent request failed.'}
          </div>
        </div>
      )}

      <div className="px-4 pb-4">
        {messages.length > 0 && (
          <div className="mx-auto mb-2 flex w-full max-w-3xl justify-end">
            <button
              type="button"
              onClick={() => setConfirmClear(true)}
              title="Clear this conversation's messages (attached files are kept)"
              className="inline-flex shrink-0 items-center gap-1 rounded-full border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2.5 py-1 text-xs text-[var(--color-muted)] transition-colors hover:text-[var(--color-fg)]"
            >
              <Eraser className="h-3.5 w-3.5" /> Clear chat
            </button>
          </div>
        )}
        <AttachmentList attachments={attachments} onRemove={removeAttachment} onRetry={retryAttachment} />
        <PromptInput
          onSubmit={(text) => {
            if (indexing) return; // block until every attachment finishes indexing (or fails)
            sendMessage({ text });
          }}
          onStop={stop}
          busy={busy}
          disabled={indexing}
          maxLength={MAX_INPUT_CHARS}
          placeholder="Waiting for file indexing…"
          onAttachFiles={addFiles}
          accept={ACCEPT}
        />
      </div>

      {confirmClear && (
        <ConfirmDialog
          title="Clear chat?"
          message="This permanently deletes this conversation's messages. Attached files are kept, so the agent can still use them. This can't be undone."
          confirmLabel="Clear chat"
          onConfirm={clearChat}
          onCancel={() => setConfirmClear(false)}
        />
      )}
    </div>
  );
}

function AssistantMessage({
  message,
  onOpenAttachment,
}: {
  message: ChatUIMessage;
  onOpenAttachment: (fileId: string, label: string) => void;
}) {
  // Renders reasoning summary, then tool groups, then the answer; reasoning/tool blocks indented to align with the answer bubble (ml-11).
  const reasoningParts = message.parts.filter(
    (part): part is { type: 'reasoning'; text: string; state?: 'streaming' | 'done' } =>
      part.type === 'reasoning',
  );
  const toolGroups = groupToolCalls(message);
  const text = messageText(message);

  return (
    <div className="flex flex-col gap-2">
      {(reasoningParts.length > 0 || toolGroups.length > 0) && (
        <div className="ml-11 flex flex-col gap-2">
          {reasoningParts.map((part, i) => (
            <Reasoning key={i} text={part.text} streaming={part.state === 'streaming'} />
          ))}
          {toolGroups.map((group) => (
            <ToolGroup key={group.name} name={group.name} calls={group.calls} />
          ))}
        </div>
      )}
      {text && (
        <Message role="assistant">
          <Response text={text} onOpenAttachment={onOpenAttachment} />
        </Message>
      )}
      <MessageFooter metadata={message.metadata} text={text} />
    </div>
  );
}

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  const copy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard blocked (e.g. insecure context) — no-op rather than surfacing an error.
    }
  }, [text]);

  return (
    <button
      type="button"
      onClick={copy}
      title={copied ? 'Copied' : 'Copy response'}
      aria-label={copied ? 'Copied' : 'Copy response'}
      className="inline-flex items-center gap-1 rounded-full border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2 py-0.5 transition-colors hover:text-[var(--color-fg)]"
    >
      {copied ? <Check className="h-3 w-3 text-green-400" /> : <Copy className="h-3 w-3" />}
    </button>
  );
}

function MessageFooter({ metadata, text }: { metadata?: ChatUIMessage['metadata']; text: string }) {
  const usedTools = metadata?.usedTools ?? [];
  const tokenUsage = metadata?.tokenUsage;
  const cachedDetails = tokenUsage?.cached_details;
  const reasoningTokens = tokenUsage?.reasoning_tokens ?? 0;

  const inputTokens = tokenUsage?.prompt_tokens ?? 0;
  const outputTokens = tokenUsage?.completion_tokens ?? 0;
  const cachedRead = cachedDetails?.read_tokens ?? 0;

  // Render the footer if we have tools, token info, or answer text to copy.
  const hasTokenInfo = inputTokens > 0 || outputTokens > 0 || cachedRead > 0 || reasoningTokens > 0;
  if (usedTools.length === 0 && !hasTokenInfo && !text) return null;

  const tokenSegments: { label: string; value: number; className?: string }[] = [];
  if (inputTokens > 0) {
    tokenSegments.push({ label: 'In', value: inputTokens });
  }
  if (outputTokens > 0) {
    tokenSegments.push({ label: 'Out', value: outputTokens });
  }
  if (cachedRead > 0) {
    tokenSegments.push({ label: 'Cached', value: cachedRead });
  }
  if (reasoningTokens > 0) {
    tokenSegments.push({ label: 'Reasoning', value: reasoningTokens, className: 'text-violet-300' });
  }

  return (
    <div className="ml-11 flex flex-wrap items-center gap-2 text-xs text-[var(--color-muted)]">
      {text && <CopyButton text={text} />}
      {usedTools.map((tool) => (
        <span
          key={tool}
          className="inline-flex items-center gap-1 rounded-full border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2 py-0.5"
        >
          <Wrench className="h-3 w-3" /> {tool}
        </span>
      ))}
      {tokenSegments.length > 0 && (
        <span className="inline-flex items-center gap-2 rounded-full border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2 py-0.5">
          {tokenSegments.map((seg, i) => (
            <span key={i} className="flex items-center gap-2">
              <span>{seg.value.toLocaleString()}</span>
              <span className={seg.className}>{seg.label}</span>
              {i < tokenSegments.length - 1 && (
                <span className="ml-2 text-[var(--color-muted)]/40">·</span>
              )}
            </span>
          ))}
        </span>
      )}
    </div>
  );
}

function Dot() {
  return <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-current" />;
}
