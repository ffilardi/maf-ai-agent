using System.Text.Json;
using AgentBackend.Configuration;
using Azure;
using Azure.Search.Documents;
using Azure.Search.Documents.Models;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;

namespace AgentBackend.Services;

/// <summary>
/// Retrieval backend for the agent's RAG <see cref="TextSearchProvider"/>. Runs a hybrid (keyword + vector) query with semantic
/// re-ranking against Azure AI Search through the APIM gateway (api-key = subscription key), scoped to the current conversation via a
/// <c>sessionId</c> filter (fails closed when the scope is absent). Projects each hit into a <see cref="TextSearchProvider.TextSearchResult"/>
/// with a "Title (fileName)" <c>SourceName</c> and an <c>attachment://{fileId}</c> <c>SourceLink</c> the SPA resolves to the preview endpoint.
/// </summary>
public sealed class SearchAdapter(AgentOptions options, EmbeddingService embeddings, ILogger<SearchAdapter> logger)
{
    // Number of grounding passages to retrieve per query.
    private const int MaxResults = 5;

    // One long-lived client; SearchClient is thread-safe and reuses the underlying HTTP pipeline.
    private readonly SearchClient _client = new(
        new Uri(options.AiSearchEndpoint!),
        options.AiSearchIndex!,
        new AzureKeyCredential(options.AiSearchSubscriptionKey!));

    /// <summary>
    /// The retrieval delegate the <see cref="TextSearchProvider"/> expects; returns grounding passages for <paramref name="query"/>.
    /// Never throws, so an empty/absent index or gateway hiccup degrades to an ungrounded answer.
    /// </summary>
    public async Task<IEnumerable<TextSearchProvider.TextSearchResult>> SearchAsync(
        string query, CancellationToken cancellationToken)
    {
        // Conversation scope from the active tool invocation; resolved outside the try so the catch/audit can report it.
        var sessionId = ResolveSessionScope();

        try
        {
            // Fail closed: no scope ⇒ skip the query (an unfiltered search would leak other conversations' chunks) and answer ungrounded.
            if (string.IsNullOrEmpty(sessionId))
            {
                logger.LogWarning("RAG retrieval skipped: no session scope on the tool invocation; returning no grounding");
                return Enumerable.Empty<TextSearchProvider.TextSearchResult>();
            }

            var searchOptions = new SearchOptions { Size = MaxResults };

            // Semantic re-ranking over the fused keyword + vector set using the index's semantic configuration.
            searchOptions.QueryType = SearchQueryType.Semantic;
            searchOptions.SemanticSearch = new SemanticSearchOptions
            {
                SemanticConfigurationName = SearchIndexer.SemanticConfigurationName,
            };

            // Vector leg of the hybrid query: embed the query text and match it against contentVector.
            var queryVector = await embeddings.EmbedQueryAsync(query, cancellationToken);
            if (queryVector is not null)
            {
                searchOptions.VectorSearch = new VectorSearchOptions
                {
                    Queries =
                    {
                        new VectorizedQuery(queryVector.Value)
                        {
                            KNearestNeighborsCount = MaxResults,
                            Fields = { "contentVector" },
                        },
                    },
                };
            }

            // Scope to the current conversation's uploaded documents (sessionId guaranteed non-empty above).
            searchOptions.Filter = $"sessionId eq '{sessionId.Replace("'", "''")}'";

            var response = await _client.SearchAsync<SearchDocument>(query, searchOptions, cancellationToken);

            var results = new List<TextSearchProvider.TextSearchResult>();
            var manifest = new List<RetrievalAuditHit>();
            await foreach (var hit in response.Value.GetResultsAsync())
            {
                var fileId = hit.Document.GetString("fileId");
                var sourceName = BuildSourceName(hit.Document.GetString("title"), hit.Document.GetString("fileName"));
                var content = hit.Document.GetString("content");

                results.Add(new TextSearchProvider.TextSearchResult
                {
                    // Citation label "Title (filename.ext)"; SourceLink is an app-scheme handle the SPA rewrites to /files/{fileId}/content.
                    SourceName = sourceName,
                    SourceLink = BuildSourceLink(fileId),
                    Text = content,
                });

                // Semantic reranker score when present (QueryType=Semantic), else the hybrid fusion score.
                manifest.Add(new RetrievalAuditHit(
                    fileId, sourceName, hit.SemanticSearch?.RerankerScore ?? hit.Score, content?.Length ?? 0));
            }

            LogRetrievalManifest(sessionId, query, manifest);
            return results;
        }
        catch (Exception ex)
        {
            // Never throw — degrade to an ungrounded answer, but log so a retrieval outage is visible in App Insights.
            logger.LogWarning(ex, "RAG retrieval failed (session={SessionId}); answering ungrounded", sessionId);
            return Enumerable.Empty<TextSearchProvider.TextSearchResult>();
        }
    }

    // Reads the request's sessionId off the active tool invocation's ChatOptions.AdditionalProperties
    // (FunctionInvokingChatClient.CurrentContext, set by MAF on the tool's own flow). Null when absent.
    private static string? ResolveSessionScope()
    {
        var options = FunctionInvokingChatClient.CurrentContext?.Options;
        if (options?.AdditionalProperties is { } props
            && props.TryGetValue(AgentFactory.SessionIdPropertyKey, out var raw)
            && raw is string sessionId && sessionId.Length > 0)
        {
            return sessionId;
        }
        return null;
    }

    // Emits a per-turn retrieval audit to App Insights: fileId + citation label + score + chunk length per hit, no chunk text (stays under the 8KB customDimension cap).
    private void LogRetrievalManifest(string sessionId, string query, IReadOnlyList<RetrievalAuditHit> manifest)
    {
        if (!logger.IsEnabled(LogLevel.Information))
        {
            return;
        }

        logger.LogInformation(
            "RAG retrieval audit: session={SessionId} hits={HitCount} query={Query} manifest={Manifest}",
            sessionId,
            manifest.Count,
            query,
            JsonSerializer.Serialize(manifest));
    }

    // One retrieved chunk's audit fields. Text length only — never the text itself (see LogRetrievalManifest).
    private sealed record RetrievalAuditHit(string? FileId, string? Source, double? Score, int Length);

    // Builds the "Title (filename.ext)" citation label, falling back to whichever part is present.
    private static string? BuildSourceName(string? title, string? fileName)
    {
        var hasTitle = !string.IsNullOrWhiteSpace(title);
        var hasFileName = !string.IsNullOrWhiteSpace(fileName);

        return (hasTitle, hasFileName) switch
        {
            (true, true) => $"{title} ({fileName})",
            (true, false) => title,
            (false, true) => fileName,
            _ => null,
        };
    }

    // Builds the citation link: an attachment://{fileId} app-scheme handle, or null when the hit has no fileId.
    private static string? BuildSourceLink(string? fileId) =>
        string.IsNullOrWhiteSpace(fileId) ? null : $"attachment://{fileId}";
}
