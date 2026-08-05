import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from 'react';
import { ArrowUp, Paperclip, Square } from 'lucide-react';
import { cn } from '@/lib/utils';

/** Composer: auto-growing textarea + submit/stop button + optional attach button. Enter sends, Shift+Enter newlines. Shaped after AI Elements' `PromptInput`. */
export function PromptInput({
  onSubmit,
  onStop,
  busy,
  disabled,
  placeholder,
  onAttachFiles,
  accept,
}: {
  onSubmit: (text: string) => void;
  onStop: () => void;
  busy: boolean;
  disabled?: boolean;
  placeholder?: string;
  onAttachFiles?: (files: FileList) => void;
  accept?: string;
}) {
  const [value, setValue] = useState('');
  const fileInputRef = useRef<HTMLInputElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const maxHeightRef = useRef<number | null>(null);

  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    if (maxHeightRef.current === null) {
      const style = window.getComputedStyle(el);
      const lineHeight = parseFloat(style.lineHeight);
      const verticalExtras =
        parseFloat(style.paddingTop) +
        parseFloat(style.paddingBottom) +
        parseFloat(style.borderTopWidth) +
        parseFloat(style.borderBottomWidth);
      maxHeightRef.current = lineHeight * 3 + verticalExtras;
    }
    const maxHeight = maxHeightRef.current;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, maxHeight)}px`;
    el.style.overflowY = el.scrollHeight > maxHeight ? 'auto' : 'hidden';
  }, [value]);

  function submit(e?: FormEvent) {
    e?.preventDefault();
    const text = value.trim();
    if (!text || busy || disabled) return;
    onSubmit(text);
    setValue('');
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  }

  return (
    <form
      onSubmit={submit}
      className="mx-auto flex w-full max-w-3xl items-end gap-2 rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-2 shadow-lg"
    >
      {onAttachFiles && (
        <>
          <input
            ref={fileInputRef}
            type="file"
            accept={accept}
            className="hidden"
            onChange={(e) => {
              if (e.target.files && e.target.files.length > 0) onAttachFiles(e.target.files);
              e.target.value = ''; // allow re-selecting the same file
            }}
          />
          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            className="flex h-9 w-9 items-center justify-center rounded-xl bg-[var(--color-surface-2)] text-[var(--color-muted)] transition hover:text-[var(--color-fg)] disabled:cursor-not-allowed disabled:opacity-50"
            aria-label="Attach a file"
          >
            <Paperclip className="h-4 w-4" />
          </button>
        </>
      )}
      <textarea
        ref={textareaRef}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={onKeyDown}
        rows={1}
        placeholder={disabled ? (placeholder ?? 'Backend unavailable…') : 'Ask the agent anything…'}
        disabled={disabled}
        className="scroll-thin flex-1 resize-none overflow-y-hidden bg-transparent px-2 py-2 text-[0.95rem] text-[var(--color-fg)] placeholder:text-[var(--color-muted)] focus:outline-none disabled:opacity-60"
      />
      {busy ? (
        <button
          type="button"
          onClick={onStop}
          className="flex h-9 w-9 items-center justify-center rounded-xl bg-[var(--color-surface-2)] text-[var(--color-fg)] transition hover:opacity-80"
          aria-label="Stop"
        >
          <Square className="h-4 w-4" />
        </button>
      ) : (
        <button
          type="submit"
          disabled={!value.trim() || disabled}
          className={cn(
            'flex h-9 w-9 items-center justify-center rounded-xl transition',
            value.trim() && !disabled
              ? 'bg-[var(--color-accent)] text-[var(--color-accent-fg)] hover:opacity-90'
              : 'cursor-not-allowed bg-[var(--color-surface-2)] text-[var(--color-muted)]',
          )}
          aria-label="Send"
        >
          <ArrowUp className="h-4 w-4" />
        </button>
      )}
    </form>
  );
}
