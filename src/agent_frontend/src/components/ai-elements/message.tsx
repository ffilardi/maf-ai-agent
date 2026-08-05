import type { ReactNode } from 'react';
import { Bot, User } from 'lucide-react';
import { cn } from '@/lib/utils';

type Role = 'system' | 'user' | 'assistant';

/** A single chat row: role avatar + bubble. Shaped after AI Elements' `Message` / `MessageContent`. */
export function Message({ role, children }: { role: Role; children: ReactNode }) {
  const isUser = role === 'user';
  return (
    <div className={cn('flex gap-3', isUser && 'flex-row-reverse')}>
      <div
        className={cn(
          'mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full border',
          isUser
            ? 'border-[var(--color-border)] bg-[var(--color-user-bubble)] text-[var(--color-fg)]'
            : 'border-[var(--color-accent)]/40 bg-[var(--color-accent)]/15 text-[var(--color-accent)]',
        )}
      >
        {isUser ? <User className="h-4 w-4" /> : <Bot className="h-4 w-4" />}
      </div>
      <div
        className={cn(
          'max-w-full rounded-2xl border px-4 py-2.5 text-[0.9rem] leading-relaxed',
          isUser
            ? 'border-[var(--color-border)] bg-[var(--color-user-bubble)]'
            : 'border-[var(--color-border)] bg-[var(--color-surface)]',
        )}
      >
        {children}
      </div>
    </div>
  );
}
