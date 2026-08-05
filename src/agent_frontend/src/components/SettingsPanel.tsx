import { useEffect, useRef, useState } from 'react';
import { Settings2 } from 'lucide-react';
import type { AppConfig } from '@/lib/backend';
import { cn } from '@/lib/utils';
import { REASONING_EFFORTS, type ChatSettings, type ReasoningEffort } from '@/lib/settings';

/** Gear-button popover for the chat model, reasoning effort, and RAG-only grounding. Closes on outside-click and Escape. */
export function SettingsPanel({
  settings,
  onChange,
  config,
  ragAvailable,
}: {
  settings: ChatSettings;
  onChange: (update: Partial<ChatSettings>) => void;
  config: AppConfig | null;
  // Gates the "Answer only from attachments" toggle; true once a document is indexed.
  ragAvailable: boolean;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function onDocClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        aria-label="Settings"
        aria-expanded={open}
        className={cn(
          'inline-flex h-9 w-9 items-center justify-center rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-fg)] transition hover:bg-[var(--color-surface-2)]',
          open && 'bg-[var(--color-surface-2)]',
        )}
      >
        <Settings2 className="h-4 w-4" />
      </button>

      {open && (
        <div className="absolute right-0 z-20 mt-2 w-[calc(100vw-1.5rem)] max-w-96 rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] p-3 shadow-xl">
          {config && config.models.length > 0 && (
            <div className="mb-4">
              <p className="mb-2 text-xs font-medium text-[var(--color-muted)]">Model</p>
              <select
                value={settings.model ?? config.defaultModel}
                onChange={(e) => onChange({ model: e.target.value })}
                className="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2 py-1.5 text-sm text-[var(--color-fg)]"
              >
                {config.models.map((m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ))}
              </select>
            </div>
          )}

          <p className="mb-2 text-xs font-medium text-[var(--color-muted)]">Reasoning effort</p>
          <div className="grid grid-cols-4 gap-1">
            {REASONING_EFFORTS.map((effort) => (
              <EffortButton
                key={effort}
                effort={effort}
                active={settings.reasoningEffort === effort}
                onSelect={() => onChange({ reasoningEffort: effort })}
              />
            ))}
          </div>
          <p className="mt-2 text-[0.7rem] leading-snug text-[var(--color-muted)]">
            Higher effort lets the model think longer before answering.
          </p>

          <div className="mt-4">
            <div className="flex items-center justify-between gap-3">
              <p className="text-xs font-medium text-[var(--color-muted)]">Answer only from attachments</p>
              <ToggleSwitch
                checked={settings.ragOnly && ragAvailable}
                onChange={(v) => onChange({ ragOnly: v })}
                disabled={!ragAvailable}
                label="Answer only from attachments"
              />
            </div>
            <p className="mt-2 text-[0.7rem] leading-snug text-[var(--color-muted)]">
              {ragAvailable
                ? "When on, the agent grounds every answer in your attached documents and won't fall back on general knowledge."
                : 'Attach a document and let it finish indexing to enable grounding.'}
            </p>
          </div>
        </div>
      )}
    </div>
  );
}

function ToggleSwitch({
  checked,
  onChange,
  label,
  disabled = false,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={cn(
        'relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition',
        checked
          ? 'bg-[var(--color-accent)]'
          : 'border border-[var(--color-border)] bg-[var(--color-surface-2)]',
        disabled && 'cursor-not-allowed opacity-50',
      )}
    >
      <span
        className={cn(
          'inline-block h-3.5 w-3.5 transform rounded-full bg-white transition',
          checked ? 'translate-x-4' : 'translate-x-1',
        )}
      />
    </button>
  );
}

function EffortButton({
  effort,
  active,
  onSelect,
}: {
  effort: ReasoningEffort;
  active: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      onClick={onSelect}
      className={cn(
        'rounded-md border px-1.5 py-1 text-xs capitalize transition',
        active
          ? 'border-[var(--color-accent)] bg-[var(--color-accent)]/15 text-[var(--color-accent)]'
          : 'border-[var(--color-border)] bg-[var(--color-surface-2)] text-[var(--color-muted)] hover:text-[var(--color-fg)]',
      )}
    >
      {effort}
    </button>
  );
}
