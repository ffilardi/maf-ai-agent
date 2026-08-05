namespace AgentBackend.Services;

/// <summary>
/// Extracts a title from markdown/plain text: first ATX heading (<c>#</c>-prefixed line), else first non-blank line.
/// Used for the verbatim-text path and as the fallback when DI didn't classify a title (see <see cref="IngestionService"/>).
/// </summary>
public static class MarkdownTitle
{
    // Title length cap.
    private const int MaxLength = 200;

    /// <summary>Returns the first ATX heading, else the first non-blank line (trimmed, capped); null when nothing usable.</summary>
    public static string? Extract(string? content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return null;
        }

        string? firstNonBlank = null;
        foreach (var raw in content.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('#'))
            {
                // Strip the leading '#'s (and any trailing closing '#'s).
                var heading = line.TrimStart('#').Trim().Trim('#').Trim();
                if (heading.Length > 0)
                {
                    return Cap(heading);
                }
            }

            firstNonBlank ??= line;
        }

        return firstNonBlank is null ? null : Cap(firstNonBlank);
    }

    private static string Cap(string value) =>
        value.Length <= MaxLength ? value : value[..MaxLength].TrimEnd();
}
