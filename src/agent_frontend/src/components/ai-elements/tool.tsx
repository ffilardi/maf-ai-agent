import { useState } from 'react';
import { ChevronDown, Loader2, Wrench } from 'lucide-react';
import { cn } from '@/lib/utils';

/** One tool invocation: its request (input) and, once available, its result (output). */
export type ToolCall = {
  toolCallId: string;
  input?: unknown;
  output?: unknown;
  pending: boolean;
};

/** A group of calls to a single tool; the header names it + call count, expanding lists each call's request/response as JSON. Shaped after AI Elements' `Tool`. */
export function ToolGroup({ name, calls }: { name: string; calls: ToolCall[] }) {
  const [open, setOpen] = useState(false);
  const pending = calls.some((c) => c.pending);

  return (
    <div className="rounded-xl border border-[var(--color-border)] bg-[var(--color-surface-2)]">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center gap-2 px-3 py-2 text-xs text-[var(--color-fg)]"
      >
        {pending ? (
          <Loader2 className="h-3.5 w-3.5 animate-spin text-[var(--color-accent)]" />
        ) : (
          <Wrench className="h-3.5 w-3.5 text-[var(--color-accent)]" />
        )}
        <span className="font-medium">{name}</span>
        {calls.length > 1 && <span className="text-[var(--color-muted)]">×{calls.length}</span>}
        <ChevronDown className={cn('ml-auto h-3.5 w-3.5 transition-transform', open && 'rotate-180')} />
      </button>
      {open && (
        <div className="flex flex-col gap-3 border-t border-[var(--color-border)] px-3 py-2">
          {calls.map((call, i) => (
            <div key={call.toolCallId} className="flex flex-col gap-1.5">
              {calls.length > 1 && (
                <span className="text-[0.7rem] uppercase tracking-wide text-[var(--color-muted)]">
                  Call {i + 1}
                </span>
              )}
              <JsonBlock label="Request" value={call.input} />
              {call.pending ? (
                <span className="text-[0.7rem] text-[var(--color-muted)]">Awaiting response…</span>
              ) : (
                <JsonBlock label="Response" value={call.output} defaultOpen={false} />
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function JsonBlock({
  label,
  value,
  defaultOpen = true,
}: {
  label: string;
  value: unknown;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="flex flex-col gap-1">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1 self-start text-[0.7rem] uppercase tracking-wide text-[var(--color-muted)]"
      >
        <ChevronDown className={cn('h-3 w-3 transition-transform', !open && '-rotate-90')} />
        {label}
      </button>
      {open && (
        <pre className="scroll-thin overflow-x-auto rounded-lg bg-[var(--color-bg)] px-2.5 py-1.5 text-[0.72rem] leading-relaxed text-[var(--color-fg)]">
          {format(value)}
        </pre>
      )}
    </div>
  );
}

function format(value: unknown): string {
  if (value === undefined || value === null) return '—';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}
