using AgentBackend.Configuration;
using Azure;
using Azure.AI.DocumentIntelligence;

namespace AgentBackend.Services;

/// <summary>
/// Converts an uploaded binary document (PDF, image, Office, HTML) into markdown via Document Intelligence <c>prebuilt-layout</c>,
/// through the APIM gateway (key as <c>Ocp-Apim-Subscription-Key</c>). Text uploads skip this step (see <see cref="IngestionService"/>).
/// </summary>
public sealed class DocumentIntelligenceService(AgentOptions options)
{
    private readonly DocumentIntelligenceClient _client = new(
        new Uri(options.DocIntelEndpoint!),
        new AzureKeyCredential(options.ApimSubscriptionKey!));

    /// <summary>The markdown rendering of a document plus the title DI detected (null when none was classified).</summary>
    public sealed record DocumentAnalysis(string Markdown, string? Title);

    /// <summary>Analyzes <paramref name="content"/> and returns its markdown plus the title from the first <see cref="ParagraphRole.Title"/> paragraph (null when none).</summary>
    public async Task<DocumentAnalysis> AnalyzeAsync(BinaryData content, CancellationToken cancellationToken)
    {
        var analyzeOptions = new AnalyzeDocumentOptions("prebuilt-layout", content)
        {
            OutputContentFormat = DocumentContentFormat.Markdown,
        };

        Operation<AnalyzeResult> operation =
            await _client.AnalyzeDocumentAsync(WaitUntil.Completed, analyzeOptions, cancellationToken);
        var result = operation.Value;

        var title = result.Paragraphs?
            .FirstOrDefault(p => p.Role == ParagraphRole.Title)?.Content;

        return new DocumentAnalysis(result.Content ?? string.Empty, title);
    }
}
