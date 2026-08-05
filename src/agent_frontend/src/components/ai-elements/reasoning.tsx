import { useEffect, useState } from 'react';
import { Brain, ChevronDown } from 'lucide-react';
import { cn } from '@/lib/utils';

/** Collapsible "thinking" block for a reasoning part; auto-expands while streaming and collapses when done. Shaped after AI Elements' `Reasoning`. */
export function Reasoning({ text, streaming }: { text: string; streaming: boolean }) {
  const [open, setOpen] = useState(streaming);
  // Follow the stream (open while thinking, collapse when done); a later manual toggle still wins since this re-runs only when `streaming` flips.
  useEffect(() => setOpen(streaming), [streaming]);

  return (
    <div className="rounded-xl border border-[var(--color-border)] bg-[var(--color-surface-2)]">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center gap-2 px-3 py-2 text-xs text-[var(--color-muted)]"
      >
        <Brain className={cn('h-3.5 w-3.5', streaming && 'animate-pulse text-[var(--color-accent)]')} />
        <span>{streaming ? 'Thinking…' : 'Reasoning'}</span>
        <ChevronDown className={cn('ml-auto h-3.5 w-3.5 transition-transform', open && 'rotate-180')} />
      </button>
      {open && text && (
        <div className="whitespace-pre-wrap break-words border-t border-[var(--color-border)] px-3 py-2 text-xs leading-relaxed text-[var(--color-muted)]">
          {text}
        </div>
      )}
    </div>
  );
}
