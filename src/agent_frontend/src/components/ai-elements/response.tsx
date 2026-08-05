import { Children, memo, useMemo, type ComponentPropsWithoutRef, type ReactNode } from 'react';
import ReactMarkdown, { defaultUrlTransform, type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';

// App-scheme prefix for citation links the model emits (attachment://{fileId}); resolved to the preview popup, not navigated.
const ATTACHMENT_SCHEME = 'attachment://';

// Repairs a common model malformation in the Sources list: the opening `[` of a citation link gets dropped
// after the footnote number, e.g. `[1] Some Source (file.pdf)](attachment://id)`, so react-markdown prints it
// literally instead of as a link. Re-insert the missing `[`. Correctly-formed links (which already have `[`
// right after the number) never match — the name group forbids brackets, so the leading `[` blocks the match.
function repairCitations(text: string): string {
  return text.replace(
    /(\[\d+\]\s+)([^[\]\n]+?)\]\((attachment:\/\/[^\s)]+)\)/g,
    '$1[$2]($3)',
  );
}

// Flatten a markdown link's children to plain text so it can title the preview popup ("Title (filename.ext)").
function nodeText(node: ReactNode): string {
  return Children.toArray(node)
    .map((child) => (typeof child === 'string' || typeof child === 'number' ? String(child) : ''))
    .join('');
}

// Markdown component map, built per-Response so the citation `a` renderer can close over `onOpenAttachment`; everything else is static.
function makeComponents(
  onOpenAttachment?: (fileId: string, label: string) => void,
): Components {
  return {
  p: (props) => <p className="my-2 first:mt-0 last:mb-0 leading-relaxed" {...props} />,
  a: ({ href, children, ...props }) => {
    // Citation links (attachment://{fileId}) open the preview popup; everything else is a real anchor.
    if (href?.startsWith(ATTACHMENT_SCHEME) && onOpenAttachment) {
      const fileId = href.slice(ATTACHMENT_SCHEME.length);
      const label = nodeText(children);
      const open = () => onOpenAttachment(fileId, label);
      const linkClass = 'text-[var(--color-accent)] underline underline-offset-2 hover:opacity-80';
      // For "Title (filename.ext)" labels, only the trailing "(filename.ext)" is clickable; fully clickable when there's no parenthetical.
      const parts = /^(.*?)\s*(\([^()]*\))\s*$/.exec(label);
      if (parts) {
        const [, title, paren] = parts;
        return (
          <>
            {title && <span>{title} </span>}
            <button type="button" onClick={open} className={linkClass}>
              {paren}
            </button>
          </>
        );
      }
      return (
        <button type="button" onClick={open} className={linkClass}>
          {children}
        </button>
      );
    }
    return (
      <a
        href={href}
        target="_blank"
        rel="noreferrer noopener"
        className="text-[var(--color-accent)] underline underline-offset-2 hover:opacity-80"
        {...props}
      >
        {children}
      </a>
    );
  },
  ul: (props) => <ul className="my-2 list-disc space-y-1 pl-5" {...props} />,
  ol: (props) => <ol className="my-2 list-decimal space-y-1 pl-5" {...props} />,
  li: (props) => <li className="leading-relaxed" {...props} />,
  h1: (props) => <h1 className="mb-2 mt-4 text-xl font-semibold first:mt-0" {...props} />,
  h2: (props) => <h2 className="mb-2 mt-4 text-lg font-semibold first:mt-0" {...props} />,
  h3: (props) => <h3 className="mb-1 mt-3 text-base font-semibold first:mt-0" {...props} />,
  h4: (props) => <h4 className="mb-1 mt-3 text-sm font-semibold first:mt-0" {...props} />,
  blockquote: (props) => (
    <blockquote
      className="my-2 border-l-2 border-[var(--color-border)] pl-3 text-[var(--color-muted)]"
      {...props}
    />
  ),
  hr: () => <hr className="my-3 border-[var(--color-border)]" />,
  strong: (props) => <strong className="font-semibold" {...props} />,
  code: CodeBlock,
  pre: (props) => (
    <pre
      className="my-2 overflow-x-auto rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-2)] p-3 text-sm"
      {...props}
    />
  ),
  table: (props) => (
    <div className="my-2 overflow-x-auto">
      <table className="w-full border-collapse text-sm" {...props} />
    </div>
  ),
  th: (props) => (
    <th className="border border-[var(--color-border)] bg-[var(--color-surface-2)] px-2 py-1 text-left font-semibold" {...props} />
  ),
  td: (props) => <td className="border border-[var(--color-border)] px-2 py-1" {...props} />,
  };
}

// Inline code gets a subtle pill; fenced code (inside <pre>) stays unstyled so the <pre> owns the frame.
function CodeBlock({ className, children, ...props }: ComponentPropsWithoutRef<'code'>) {
  const isBlock = className?.includes('language-');
  if (isBlock) {
    return (
      <code className={className} {...props}>
        {children}
      </code>
    );
  }
  return (
    <code
      className="rounded bg-[var(--color-surface-2)] px-1 py-0.5 text-[0.9em] text-[var(--color-fg)]"
      {...props}
    >
      {children}
    </code>
  );
}

export const Response = memo(function Response({
  text,
  onOpenAttachment,
}: {
  text: string;
  // Opens a cited attachment's preview popup; absent ⇒ citation links render as inert buttons (renderer works standalone).
  onOpenAttachment?: (fileId: string, label: string) => void;
}) {
  const components = useMemo(() => makeComponents(onOpenAttachment), [onOpenAttachment]);
  // Repair dropped-bracket citation links before parsing so malformed source lists still render as links.
  const markdown = useMemo(() => repairCitations(text), [text]);
  return (
    <div className="break-words">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={components}
        // Preserve the attachment:// citation scheme (default transform would strip it); other URLs keep react-markdown's sanitisation.
        urlTransform={(url) => (url.startsWith(ATTACHMENT_SCHEME) ? url : defaultUrlTransform(url))}
      >
        {markdown}
      </ReactMarkdown>
    </div>
  );
});
