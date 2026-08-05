import { useState } from 'react';
import { MessageSquare, Plus, Trash2, X } from 'lucide-react';
import type { ConversationSummary } from '@/lib/backend';
import { cn } from '@/lib/utils';

/**
 * Left sidebar listing past conversations (newest-first). "New chat" mints one; a row reopens it; the trash button deletes
 * it behind an inline confirm; the active conversation is highlighted. State lives in `App.tsx`.
 * A static column at `lg`; an off-canvas drawer (with backdrop) below it, toggled via `open`/`onClose`.
 */
export function SessionsPanel({
  sessions,
  activeId,
  onSelect,
  onNew,
  onDelete,
  open,
  onClose,
}: {
  sessions: ConversationSummary[];
  activeId: string;
  onSelect: (id: string) => void;
  onNew: () => void;
  onDelete: (id: string) => void;
  open: boolean;
  onClose: () => void;
}) {
  // Which conversation id is awaiting delete confirmation (its trash button flipped to a "Delete?" state).
  const [confirmingId, setConfirmingId] = useState<string | null>(null);

  return (
    <>
      {/* Scrim behind the drawer on mobile; static column has no backdrop (hidden at lg). */}
      <div
        className={cn(
          'fixed inset-0 z-30 bg-black/60 transition-opacity lg:hidden',
          open ? 'opacity-100' : 'pointer-events-none opacity-0',
        )}
        onClick={onClose}
        aria-hidden
      />
      <aside
        className={cn(
          'fixed inset-y-0 left-0 z-40 flex h-full w-64 shrink-0 flex-col border-r border-[var(--color-border)] bg-[var(--color-surface)] transition-transform duration-200 lg:static lg:z-auto lg:translate-x-0',
          open ? 'translate-x-0' : '-translate-x-full',
        )}
      >
        <div className="flex items-center gap-2 p-3">
          <button
            onClick={onNew}
            className="flex flex-1 items-center justify-center gap-1.5 rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-2)] px-3 py-2 text-sm font-medium text-[var(--color-fg)] transition hover:bg-[var(--color-accent)]/15 hover:text-[var(--color-accent)]"
          >
            <Plus className="h-4 w-4" /> New chat
          </button>
          <button
            onClick={onClose}
            aria-label="Close conversations"
            className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)] lg:hidden"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-3">
        {sessions.length === 0 ? (
          <p className="px-2 py-4 text-center text-xs text-[var(--color-muted)]">No conversations yet.</p>
        ) : (
          <ul className="flex flex-col gap-0.5">
            {sessions.map((session) => (
              <li key={session.id}>
                <div
                  className={cn(
                    'group flex items-center gap-2 rounded-lg px-2 py-2 text-sm transition',
                    session.id === activeId
                      ? 'bg-[var(--color-accent)]/15 text-[var(--color-accent)]'
                      : 'text-[var(--color-fg)] hover:bg-[var(--color-surface-2)]',
                  )}
                >
                  <button
                    onClick={() => onSelect(session.id)}
                    className="flex min-w-0 flex-1 items-center gap-2 text-left"
                    title={session.title}
                  >
                    <MessageSquare className="h-4 w-4 shrink-0 opacity-70" />
                    <span className="min-w-0 flex-1 truncate">{session.title}</span>
                    <span className="shrink-0 text-[0.7rem] text-[var(--color-muted)]">
                      {relativeTime(session.updatedAt)}
                    </span>
                  </button>
                  {confirmingId === session.id ? (
                    <span className="flex shrink-0 items-center gap-1 text-xs">
                      <button
                        onClick={() => {
                          setConfirmingId(null);
                          onDelete(session.id);
                        }}
                        className="rounded px-1.5 py-0.5 text-red-400 transition hover:bg-red-500/10"
                      >
                        Delete
                      </button>
                      <button
                        onClick={() => setConfirmingId(null)}
                        className="rounded px-1.5 py-0.5 text-[var(--color-muted)] transition hover:text-[var(--color-fg)]"
                      >
                        Cancel
                      </button>
                    </span>
                  ) : (
                    <button
                      onClick={() => setConfirmingId(session.id)}
                      aria-label="Delete conversation"
                      title="Delete conversation"
                      className="shrink-0 rounded p-1 text-[var(--color-muted)] opacity-0 transition hover:text-red-400 group-hover:opacity-100"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
      </aside>
    </>
  );
}

// Compact relative label from a unix-seconds timestamp (0/unknown ⇒ blank).
function relativeTime(unixSeconds: number): string {
  if (!unixSeconds) return '';
  const diffMs = Date.now() - unixSeconds * 1000;
  const min = Math.floor(diffMs / 60000);
  if (min < 1) return 'now';
  if (min < 60) return `${min}m`;
  const hours = Math.floor(min / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d`;
  return new Date(unixSeconds * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
