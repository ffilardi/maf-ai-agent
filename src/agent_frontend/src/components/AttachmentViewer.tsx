import { useEffect, useState } from 'react';
import { Download, Loader2, X } from 'lucide-react';
import { attachmentUrl } from '@/lib/backend';
import { Response } from '@/components/ai-elements/response';

// Preview mode by extension: markdown → GFM render, html → sandboxed iframe, everything else → native iframe (PDF/image/text) + Download fallback.
type Mode = 'markdown' | 'html' | 'native';

const MARKDOWN_EXTS = new Set(['md', 'markdown']);
const HTML_EXTS = new Set(['html', 'htm']);

// Extracts the extension from a plain file name or a citation "Title (filename.ext)" label.
function fileExtension(label: string): string {
  const name = label.replace(/\)\s*$/, '');
  const dot = name.lastIndexOf('.');
  return dot === -1 ? '' : name.slice(dot + 1).toLowerCase();
}

function modeFor(ext: string): Mode {
  if (MARKDOWN_EXTS.has(ext)) return 'markdown';
  if (HTML_EXTS.has(ext)) return 'html';
  return 'native';
}

/**
 * Floating popup previewing a cited attachment's original file: markdown → formatted, html → script-disabled sandboxed iframe,
 * everything else → native iframe (Download fallback). Opened from a citation link or the files panel; closes on backdrop click and Escape.
 */
export function AttachmentViewer({
  fileId,
  label,
  sessionId,
  onClose,
}: {
  fileId: string;
  label: string;
  sessionId: string;
  onClose: () => void;
}) {
  const mode = modeFor(fileExtension(label));

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose();
    }
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-2 sm:p-4"
      onMouseDown={onClose}
    >
      <div
        className="flex h-[90vh] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] shadow-2xl sm:h-[85vh]"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between gap-3 border-b border-[var(--color-border)] px-4 py-2.5">
          <p className="truncate text-sm font-medium text-[var(--color-fg)]" title={label}>
            {label}
          </p>
          <div className="flex items-center gap-1">
            <a
              href={attachmentUrl(fileId, sessionId, true)}
              target="_blank"
              rel="noreferrer noopener"
              aria-label="Download"
              className="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]"
            >
              <Download className="h-4 w-4" />
            </a>
            <button
              onClick={onClose}
              aria-label="Close"
              className="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>
        {mode === 'native' ? (
          <iframe
            src={attachmentUrl(fileId, sessionId)}
            title={label}
            className="min-h-0 flex-1 bg-white"
          />
        ) : (
          <TextPreview fileId={fileId} sessionId={sessionId} label={label} mode={mode} />
        )}
      </div>
    </div>
  );
}

// Fetches the raw bytes and renders them: markdown through the shared `Response` renderer, html into a
// maximally-restrictive sandboxed iframe (`sandbox=""` — no scripts, no same-origin) so uploaded markup can't execute.
function TextPreview({
  fileId,
  sessionId,
  label,
  mode,
}: {
  fileId: string;
  sessionId: string;
  label: string;
  mode: 'markdown' | 'html';
}) {
  const [text, setText] = useState<string | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setText(null);
    setError(false);
    fetch(attachmentUrl(fileId, sessionId))
      .then((res) => {
        if (!res.ok) throw new Error(`content ${res.status}`);
        return res.text();
      })
      .then((body) => !cancelled && setText(body))
      .catch(() => !cancelled && setError(true));
    return () => {
      cancelled = true;
    };
  }, [fileId, sessionId]);

  if (error) {
    return (
      <div className="flex min-h-0 flex-1 items-center justify-center px-4 text-center text-sm text-[var(--color-muted)]">
        Couldn't load this file. Use the download button to open it.
      </div>
    );
  }
  if (text === null) {
    return (
      <div className="flex min-h-0 flex-1 items-center justify-center text-[var(--color-muted)]">
        <Loader2 className="h-5 w-5 animate-spin" />
      </div>
    );
  }
  if (mode === 'html') {
    return (
      <iframe
        srcDoc={text}
        title={label}
        sandbox=""
        className="min-h-0 flex-1 bg-white"
      />
    );
  }
  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5 text-sm text-[var(--color-fg)]">
      <Response text={text} />
    </div>
  );
}
