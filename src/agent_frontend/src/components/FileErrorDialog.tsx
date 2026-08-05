import { useEffect } from 'react';
import { AlertCircle, X } from 'lucide-react';

/** Floating popup surfacing a failed file's backend ingestion error. Closes on backdrop click and Escape. */
export function FileErrorDialog({
  fileName,
  error,
  onClose,
}: {
  fileName: string;
  error: string;
  onClose: () => void;
}) {
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose();
    }
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      onMouseDown={onClose}
    >
      <div
        className="flex w-full max-w-md flex-col overflow-hidden rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] shadow-2xl"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between gap-3 border-b border-[var(--color-border)] px-4 py-2.5">
          <p className="flex min-w-0 items-center gap-2 text-sm font-medium text-red-400">
            <AlertCircle className="h-4 w-4 shrink-0" />
            <span className="truncate" title={fileName}>
              Indexing failed — {fileName}
            </span>
          </p>
          <button
            onClick={onClose}
            aria-label="Close"
            className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="max-h-[50vh] overflow-y-auto px-4 py-3">
          <pre className="whitespace-pre-wrap break-words text-xs text-[var(--color-fg)]">{error}</pre>
        </div>
      </div>
    </div>
  );
}
