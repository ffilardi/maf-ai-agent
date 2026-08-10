import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Bot, FileText, Loader2, Menu } from 'lucide-react';
import { getConfig, type AppConfig, type ChatUIMessage, type ConversationSummary } from '@/lib/backend';
import { getSessionId, resetSessionId, setSessionId as persistSessionId } from '@/lib/session';
import { getSettings, saveSettings, type ChatSettings } from '@/lib/settings';
import { deleteSession, fetchHistory, fetchSessions } from '@/lib/history';
import { deleteFile, listFiles, type FileStatusResult } from '@/lib/files';
import { Chat } from '@/components/Chat';
import { SessionsPanel } from '@/components/SessionsPanel';
import { FilesPanel } from '@/components/FilesPanel';
import { FileErrorDialog } from '@/components/FileErrorDialog';
import { SettingsPanel } from '@/components/SettingsPanel';
import { AttachmentViewer } from '@/components/AttachmentViewer';

export default function App() {
  const [sessionId, setSessionId] = useState(getSessionId);
  const [settings, setSettings] = useState<ChatSettings>(getSettings);
  const [config, setConfig] = useState<AppConfig | null>(null);
  // Past-conversations list for the sidebar (backend-owned).
  const [sessions, setSessions] = useState<ConversationSummary[]>([]);
  // The active conversation's loaded transcript, tagged with its id; Chat renders only once this matches the active sessionId.
  const [history, setHistory] = useState<{ id: string; messages: ChatUIMessage[] } | null>(null);
  // The active conversation's attachments for the right-side files panel (backend-owned status table).
  const [files, setFiles] = useState<FileStatusResult[]>([]);
  // The attachment open in the preview popup — shared by citation links (via Chat) and the files panel.
  const [preview, setPreview] = useState<{ fileId: string; label: string } | null>(null);
  // The failed file whose backend ingestion error is shown in a popup (opened from the files panel).
  const [fileError, setFileError] = useState<{ fileName: string; error: string } | null>(null);
  // Off-canvas drawer state for the two side panels (mobile/tablet only; static columns at `lg`).
  const [sessionsOpen, setSessionsOpen] = useState(false);
  const [filesOpen, setFilesOpen] = useState(false);
  const openPreview = useCallback((fileId: string, label: string) => {
    setPreview({ fileId, label });
    setFilesOpen(false); // dismiss the files drawer so the preview isn't hidden behind it on mobile
  }, []);

  // Load the backend's non-secret config (models + default prompt) once.
  useEffect(() => {
    void getConfig().then(setConfig);
  }, []);

  const refreshSessions = useCallback(async () => {
    setSessions(await fetchSessions());
  }, []);

  // Sessions with a persisted turn, tracked synchronously so a same-tick "New chat" can't race the async `sessions` refetch and purge a just-persisted session's files.
  const persistedSessionIds = useRef<Set<string>>(new Set());
  const handleTurnComplete = useCallback(() => {
    persistedSessionIds.current.add(sessionId);
    void refreshSessions();
  }, [sessionId, refreshSessions]);

  const refreshFiles = useCallback(async () => {
    setFiles(await listFiles(sessionId));
  }, [sessionId]);

  useEffect(() => {
    void refreshSessions();
  }, [refreshSessions]);

  // Load the active conversation's attachments whenever it changes.
  useEffect(() => {
    void refreshFiles();
  }, [refreshFiles]);

  // While any file is still indexing server-side, keep polling so the panel reaches its true terminal state (the backend's ~25-min retry budget far exceeds the composer's own 5-min poll).
  const anyProcessing = useMemo(() => files.some((f) => f.status === 'processing'), [files]);
  useEffect(() => {
    if (!anyProcessing) return;
    const timer = setInterval(() => void refreshFiles(), 3000);
    return () => clearInterval(timer);
  }, [anyProcessing, refreshFiles]);

  // Load the active conversation's transcript whenever it changes (a New chat is seeded empty in startNewChat, so no fetch flash).
  useEffect(() => {
    let cancelled = false;
    void fetchHistory(sessionId).then((messages) => {
      if (!cancelled) setHistory({ id: sessionId, messages });
    });
    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  function updateSettings(update: Partial<ChatSettings>) {
    setSettings(saveSettings(update));
  }

  // Best-effort purge of an unpersisted session's uploaded files when navigating away from it.
  function purgeAbandonedFiles(abandonedId: string) {
    const persisted = persistedSessionIds.current.has(abandonedId) || sessions.some((s) => s.id === abandonedId);
    if (!persisted && files.length > 0) {
      void deleteSession(abandonedId); // DELETE /chat/{id} tears down chunks/blobs/status rows
    }
  }

  function startNewChat() {
    purgeAbandonedFiles(sessionId);
    const id = resetSessionId();
    setHistory({ id, messages: [] }); // a fresh conversation has no prior turns — skip the fetch flash
    setSessionId(id);
    setSessionsOpen(false); // close the drawer after acting (no-op on desktop)
  }

  function selectSession(id: string) {
    setSessionsOpen(false); // close the drawer after acting (no-op on desktop)
    if (id === sessionId) return;
    purgeAbandonedFiles(sessionId);
    persistSessionId(id);
    setSessionId(id); // the transcript effect loads its prior turns
  }

  async function removeSession(id: string) {
    await deleteSession(id);
    await refreshSessions();
    if (id === sessionId) startNewChat();
  }

  async function removeFile(fileId: string) {
    await deleteFile(sessionId, fileId);
    await refreshFiles();
  }

  // Keep the active conversation visible/highlighted even before its first turn is persisted (not yet in the backend list).
  const displaySessions = useMemo<ConversationSummary[]>(() => {
    if (sessions.some((s) => s.id === sessionId)) return sessions;
    return [{ id: sessionId, title: 'New chat', updatedAt: Math.floor(Date.now() / 1000) }, ...sessions];
  }, [sessions, sessionId]);

  // The effective model sent per request: the user's choice, else the backend default.
  const model = settings.model ?? config?.defaultModel ?? '';

  // True once the conversation has at least one indexed document; gates RAG-only.
  const ragAvailable = useMemo(() => files.some((f) => f.status === 'indexed'), [files]);

  const loadedMessages = history && history.id === sessionId ? history.messages : null;

  return (
    <div className="flex h-full">
      <SessionsPanel
        sessions={displaySessions}
        activeId={sessionId}
        onSelect={selectSession}
        onNew={startNewChat}
        onDelete={removeSession}
        open={sessionsOpen}
        onClose={() => setSessionsOpen(false)}
      />

      <div className="mx-auto flex h-full min-w-0 max-w-4xl flex-1 flex-col">
        <header className="flex items-center justify-between gap-2 border-b border-[var(--color-border)] px-3 py-3 sm:px-4">
          <div className="flex min-w-0 items-center gap-2">
            <button
              onClick={() => setSessionsOpen(true)}
              aria-label="Open conversations"
              className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)] lg:hidden"
            >
              <Menu className="h-4 w-4" />
            </button>
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-[var(--color-accent)]/15 text-[var(--color-accent)]">
              <Bot className="h-5 w-5" />
            </div>
            <span className="truncate font-semibold">AI Agent</span>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <SettingsPanel
              settings={settings}
              onChange={updateSettings}
              config={config}
              ragAvailable={ragAvailable}
            />
            <button
              onClick={() => setFilesOpen(true)}
              aria-label="Open files"
              className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)] lg:hidden"
            >
              <FileText className="h-4 w-4" />
            </button>
          </div>
        </header>

        {/* `key` forces a fresh useChat (and the right seeded messages) when the conversation id changes. */}
        <main className="min-h-0 flex-1">
          {loadedMessages ? (
            <Chat
              key={sessionId}
              sessionId={sessionId}
              initialMessages={loadedMessages}
              reasoningEffort={settings.reasoningEffort}
              model={model}
              ragOnly={settings.ragOnly && ragAvailable}
              onTurnComplete={handleTurnComplete}
              onFilesChanged={refreshFiles}
              onOpenAttachment={openPreview}
            />
          ) : (
            <div className="flex h-full items-center justify-center text-[var(--color-muted)]">
              <Loader2 className="h-5 w-5 animate-spin" />
            </div>
          )}
        </main>
      </div>

      <FilesPanel
        files={files}
        onDelete={removeFile}
        onOpen={openPreview}
        onShowError={(fileName, error) => setFileError({ fileName, error })}
        open={filesOpen}
        onClose={() => setFilesOpen(false)}
      />

      {fileError && (
        <FileErrorDialog
          fileName={fileError.fileName}
          error={fileError.error}
          onClose={() => setFileError(null)}
        />
      )}

      {preview && (
        <AttachmentViewer
          fileId={preview.fileId}
          label={preview.label}
          sessionId={sessionId}
          onClose={() => setPreview(null)}
        />
      )}
    </div>
  );
}
