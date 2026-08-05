import { useEffect } from 'react';
import { AlertTriangle, X } from 'lucide-react';

/** Floating confirm/cancel popup for a destructive action. Closes on backdrop click, Escape, or Cancel. */
export function ConfirmDialog({
  title,
  message,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  onConfirm,
  onCancel,
}: {
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onCancel();
    }
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onCancel]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      onMouseDown={onCancel}
    >
      <div
        className="flex w-full max-w-md flex-col overflow-hidden rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] shadow-2xl"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between gap-3 border-b border-[var(--color-border)] px-4 py-2.5">
          <p className="flex min-w-0 items-center gap-2 text-sm font-medium text-amber-400">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            <span className="truncate" title={title}>
              {title}
            </span>
          </p>
          <button
            onClick={onCancel}
            aria-label="Close"
            className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="px-4 py-3">
          <p className="text-sm text-[var(--color-fg)]">{message}</p>
        </div>
        <div className="flex justify-end gap-2 border-t border-[var(--color-border)] px-4 py-3">
          <button
            onClick={onCancel}
            className="inline-flex items-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] px-3 py-1.5 text-sm text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]"
          >
            {cancelLabel}
          </button>
          <button
            onClick={onConfirm}
            className="inline-flex items-center rounded-lg border border-red-500/50 bg-red-500/15 px-3 py-1.5 text-sm font-medium text-red-300 transition hover:bg-red-500/25"
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
