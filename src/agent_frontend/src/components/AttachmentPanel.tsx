import { FileText, Loader2, Check, X, RotateCw, AlertCircle } from 'lucide-react';
import type { FileAttachment } from '@/lib/files';

/** Composer attachment chips, one per file, showing ingestion status (spinner/check/error + retry). Presentational: state lives in Chat.tsx. */
export function AttachmentList({
  attachments,
  onRemove,
  onRetry,
}: {
  attachments: FileAttachment[];
  onRemove: (id: string) => void;
  onRetry: (id: string) => void;
}) {
  if (attachments.length === 0) return null;

  return (
    <div className="mx-auto mb-2 flex w-full max-w-3xl flex-wrap gap-2 px-1">
      {attachments.map((att) => (
        <div
          key={att.id}
          className="flex items-center gap-2 rounded-xl border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2.5 py-1.5 text-xs"
        >
          <FileText className="h-3.5 w-3.5 shrink-0 text-[var(--color-muted)]" />
          <span className="max-w-[12rem] truncate text-[var(--color-fg)]" title={att.name}>
            {att.name}
          </span>

          {att.status === 'uploading' && (
            <span className="inline-flex items-center gap-1 text-[var(--color-muted)]">
              <Loader2 className="h-3.5 w-3.5 animate-spin" /> Indexing…
            </span>
          )}
          {att.status === 'indexed' && (
            <span className="inline-flex items-center gap-1 text-emerald-400">
              <Check className="h-3.5 w-3.5" />
              {typeof att.chunkCount === 'number' ? `${att.chunkCount} chunks` : 'Indexed'}
            </span>
          )}
          {att.status === 'error' && (
            <>
              <span className="inline-flex items-center gap-1 text-red-400" title={att.error}>
                <AlertCircle className="h-3.5 w-3.5" /> Failed
              </span>
              <button
                type="button"
                onClick={() => onRetry(att.id)}
                className="text-[var(--color-muted)] transition hover:text-[var(--color-fg)]"
                aria-label={`Retry ${att.name}`}
              >
                <RotateCw className="h-3.5 w-3.5" />
              </button>
            </>
          )}

          {att.status !== 'uploading' && (
            <button
              type="button"
              onClick={() => onRemove(att.id)}
              className="text-[var(--color-muted)] transition hover:text-[var(--color-fg)]"
              aria-label={`Remove ${att.name}`}
            >
              <X className="h-3.5 w-3.5" />
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
