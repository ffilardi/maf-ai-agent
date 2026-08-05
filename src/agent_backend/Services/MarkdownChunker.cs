using System.Text;
using System.Text.RegularExpressions;

namespace AgentBackend.Services;

/// <summary>
/// Splits markdown/plain text into overlapping chunks for the embedding model. Dependency-free: packs blank-line-separated
/// paragraph blocks up to a char budget with a small tail overlap; an oversized block is hard-split by length (tokens ≈ chars/4).
/// </summary>
public static partial class MarkdownChunker
{
    // ~512 tokens per chunk, ~10% overlap (chars/4 ≈ tokens).
    private const int TargetChars = 2048;
    private const int OverlapChars = 200;

    public static IReadOnlyList<string> Chunk(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return Array.Empty<string>();
        }

        var chunks = new List<string>();
        var current = new StringBuilder();

        void Flush()
        {
            var text = current.ToString().Trim();
            if (text.Length > 0)
            {
                chunks.Add(text);
            }
            current.Clear();
        }

        // Seed the next chunk with the tail of the previous one so a split doesn't sever surrounding context.
        void SeedOverlap()
        {
            if (chunks.Count == 0)
            {
                return;
            }
            var previous = chunks[^1];
            var tail = previous.Length <= OverlapChars ? previous : previous[^OverlapChars..];
            current.Append(tail).Append("\n\n");
        }

        foreach (var block in BlankLineSplit().Split(content))
        {
            var paragraph = block.Trim();
            if (paragraph.Length == 0)
            {
                continue;
            }

            // A block larger than a whole chunk (long table/section) is hard-split by length.
            if (paragraph.Length > TargetChars)
            {
                Flush();
                for (var i = 0; i < paragraph.Length; i += TargetChars - OverlapChars)
                {
                    var length = Math.Min(TargetChars, paragraph.Length - i);
                    chunks.Add(paragraph.Substring(i, length).Trim());
                }
                continue;
            }

            if (current.Length > 0 && current.Length + paragraph.Length + 2 > TargetChars)
            {
                Flush();
                SeedOverlap();
            }

            current.Append(paragraph).Append("\n\n");
        }

        Flush();
        return chunks;
    }

    [GeneratedRegex(@"\n\s*\n")]
    private static partial Regex BlankLineSplit();
}
