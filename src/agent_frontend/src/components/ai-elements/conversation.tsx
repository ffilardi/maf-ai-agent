import { useEffect, useRef, type ReactNode } from 'react';
import { cn } from '@/lib/utils';

/** Scrollable conversation pane that keeps the newest message in view as tokens stream in. Shaped after AI Elements' `Conversation`. */
export function Conversation({ children, className }: { children: ReactNode; className?: string }) {
  const endRef = useRef<HTMLDivElement>(null);

  // Re-run on every render (streaming mutates children in place) to follow the answer's tail.
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  });

  return (
    <div className={cn('scroll-thin flex-1 overflow-y-auto px-4', className)}>
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 py-6">
        {children}
        <div ref={endRef} />
      </div>
    </div>
  );
}
