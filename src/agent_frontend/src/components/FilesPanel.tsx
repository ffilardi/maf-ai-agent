import { useState } from 'react';
import { AlertCircle, Check, FileText, Loader2, Trash2, X } from 'lucide-react';
import type { FileStatusResult } from '@/lib/files';
import { cn } from '@/lib/utils';

/**
 * Right sidebar listing the active conversation's attachments and their ingestion status; the trash button deletes one file
 * behind an inline confirm. Presentational: state lives in `App.tsx`.
 * A static column at `lg`; an off-canvas drawer (with backdrop) below it, toggled via `open`/`onClose`.
 */
export function FilesPanel({
  files,
  onDelete,
  onOpen,
  onShowError,
  open,
  onClose,
}: {
  files: FileStatusResult[];
  onDelete: (fileId: string) => void;
  // Opens the file in the shared preview popup (same viewer citation links use). Label is the file name.
  onOpen: (fileId: string, fileName: string) => void;
  // Opens the backend ingestion error for a failed file in a popup.
  onShowError: (fileName: string, error: string) => void;
  open: boolean;
  onClose: () => void;
}) {
  // Which file id is awaiting delete confirmation (its trash button flipped to a "Confirm?" state).
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
          'fixed inset-y-0 right-0 z-40 flex h-full w-64 shrink-0 flex-col border-l border-[var(--color-border)] bg-[var(--color-surface)] transition-transform duration-200 lg:static lg:z-auto lg:translate-x-0',
          open ? 'translate-x-0' : 'translate-x-full',
        )}
      >
        <div className="flex items-center justify-between gap-2 border-b border-[var(--color-border)] px-4 py-3">
          <h2 className="flex items-center gap-2 text-sm font-semibold text-[var(--color-fg)]">
            <FileText className="h-4 w-4 opacity-70" /> Files
          </h2>
          <button
            onClick={onClose}
            aria-label="Close files"
            className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)] lg:hidden"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-2 py-3">
        {files.length === 0 ? (
          <p className="px-2 py-4 text-center text-xs text-[var(--color-muted)]">
            No files attached to this conversation.
          </p>
        ) : (
          <ul className="flex flex-col gap-1">
            {files.map((file) => (
              <li
                key={file.fileId}
                className="group flex flex-col gap-1 rounded-lg px-2 py-2 text-sm text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]"
              >
                <div className="flex items-center gap-2">
                  <FileText className="h-4 w-4 shrink-0 opacity-70" />
                  <button
                    onClick={() => onOpen(file.fileId, file.fileName)}
                    title={`Preview ${file.fileName}`}
                    className="min-w-0 flex-1 truncate text-left transition hover:text-[var(--color-accent)] hover:underline"
                  >
                    {file.fileName}
                  </button>
                  {confirmingId === file.fileId ? (
                    <span className="flex shrink-0 items-center gap-1 text-xs">
                      <button
                        onClick={() => {
                          setConfirmingId(null);
                          onDelete(file.fileId);
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
                      onClick={() => setConfirmingId(file.fileId)}
                      aria-label={`Delete ${file.fileName}`}
                      title="Delete file"
                      className="shrink-0 rounded p-1 text-[var(--color-muted)] opacity-0 transition hover:text-red-400 group-hover:opacity-100"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  )}
                </div>
                <FileStatusLine file={file} onShowError={onShowError} />
              </li>
            ))}
          </ul>
        )}
      </div>
      </aside>
    </>
  );
}

// The per-file status affordance — mirrors the composer chip vocabulary in AttachmentPanel.
function FileStatusLine({
  file,
  onShowError,
}: {
  file: FileStatusResult;
  onShowError: (fileName: string, error: string) => void;
}) {
  return (
    <span className={cn('flex items-center gap-1 pl-6 text-xs', statusColor(file.status))}>
      {file.status === 'processing' && (
        <>
          <Loader2 className="h-3 w-3 animate-spin" /> Indexing…
        </>
      )}
      {file.status === 'indexed' && (
        <>
          <Check className="h-3 w-3" />
          {typeof file.chunkCount === 'number' ? `${file.chunkCount} chunks` : 'Indexed'}
        </>
      )}
      {file.status === 'failed' && (
        <button
          type="button"
          onClick={() => onShowError(file.fileName, file.error ?? 'Indexing failed.')}
          title="Show error"
          className="flex items-center gap-1 rounded transition hover:underline"
        >
          <AlertCircle className="h-3 w-3" /> Failed
        </button>
      )}
    </span>
  );
}

function statusColor(status: FileStatusResult['status']): string {
  if (status === 'indexed') return 'text-emerald-400';
  if (status === 'failed') return 'text-red-400';
  return 'text-[var(--color-muted)]';
}
