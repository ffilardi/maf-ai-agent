using AgentBackend.Configuration;
using Azure;
using Azure.Search.Documents;
using Azure.Search.Documents.Indexes;
using Azure.Search.Documents.Indexes.Models;
using Azure.Search.Documents.Models;

namespace AgentBackend.Services;

/// <summary>
/// Write side of the RAG index: ensures the hybrid (keyword + vector) schema exists and pushes chunks, through the APIM gateway
/// (api-key = subscription key). Read side is <see cref="SearchAdapter"/>; both agree on the field names below.
/// </summary>
public sealed class SearchIndexer(AgentOptions options, ILogger<SearchIndexer> logger)
{
    // One long-lived client; SearchClient is thread-safe and reuses the underlying HTTP pipeline.
    private readonly SearchClient _searchClient = new(
        new Uri(options.AiSearchEndpoint!),
        options.AiSearchIndex!,
        new AzureKeyCredential(options.AiSearchSubscriptionKey!));

    // text-embedding-3-large produces 3072-dimension vectors.
    private const int VectorDimensions = 3072;
    private const string VectorProfileName = "hnsw-profile";
    private const string VectorAlgorithmName = "hnsw-algorithm";

    // Bounded inline retry while a freshly (re)created index is still offline and 400s pushes (kept under the worker's 5-min visibility timeout).
    private const int MaxIndexReadyAttempts = 12;
    private static readonly TimeSpan IndexReadyRetryDelay = TimeSpan.FromSeconds(10);

    // Max document keys per delete request (Azure AI Search caps a batch at 1000 actions).
    private const int MaxDeleteBatchSize = 1000;

    /// <summary>Name of the index's semantic configuration (title + content); shared by <see cref="InitializeAsync"/> and <see cref="SearchAdapter"/>.</summary>
    public const string SemanticConfigurationName = "semantic-config";

    /// <summary>One indexed chunk: the projected text fields plus its embedding and scope tags. <c>FileNameText</c> is the analyzed, extension-stripped file name that biases keyword/semantic ranking toward a file the user names (soft prioritization).</summary>
    public sealed record ChunkDocument(
        string Id, string Title, string FileName, string FileNameText, string SourceUrl, string Content,
        string SessionId, string FileId, ReadOnlyMemory<float> ContentVector);

    /// <summary>Creates or updates the index with the hybrid schema (idempotent PUT); called once at startup by <see cref="IngestionInitializer"/>.</summary>
    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        var indexClient = new SearchIndexClient(
            new Uri(options.AiSearchEndpoint!),
            new AzureKeyCredential(options.AiSearchSubscriptionKey!));

        var index = new SearchIndex(options.AiSearchIndex!)
        {
            Fields =
            {
                new SimpleField("id", SearchFieldDataType.String) { IsKey = true },
                new SearchableField("title"),
                new SimpleField("fileName", SearchFieldDataType.String),
                new SearchableField("fileNameText"), // Copy of the file name (no extension) so a filename the user types in the query matches every chunk of that file (soft ranking boost)
                new SimpleField("sourceUrl", SearchFieldDataType.String),
                new SearchableField("content"),
                new SimpleField("sessionId", SearchFieldDataType.String) { IsFilterable = true },
                new SimpleField("fileId", SearchFieldDataType.String) { IsFilterable = true },
                new SearchField("contentVector", SearchFieldDataType.Collection(SearchFieldDataType.Single))
                {
                    IsSearchable = true,
                    VectorSearchDimensions = VectorDimensions,
                    VectorSearchProfileName = VectorProfileName,
                },
            },
            VectorSearch = new VectorSearch
            {
                Algorithms = { new HnswAlgorithmConfiguration(VectorAlgorithmName) },
                Profiles = { new VectorSearchProfile(VectorProfileName, VectorAlgorithmName) },
            },
            // Semantic configuration for the re-ranker; prioritizes title + content.
            SemanticSearch = new SemanticSearch
            {
                Configurations =
                {
                    new SemanticConfiguration(SemanticConfigurationName, new SemanticPrioritizedFields
                    {
                        TitleField = new SemanticField("title"),
                        // Reinforce the keyword signal so a named file's chunks also rank higher through the reranker.
                        KeywordsFields = { new SemanticField("fileNameText") },
                        ContentFields = { new SemanticField("content") },
                    }),
                },
            },
        };

        await indexClient.CreateOrUpdateIndexAsync(index, cancellationToken: cancellationToken);
    }

    /// <summary>Pushes the chunk documents into the index (upload/overwrite by id).</summary>
    public async Task UploadAsync(IReadOnlyList<ChunkDocument> chunks, CancellationToken cancellationToken)
    {
        if (chunks.Count == 0)
        {
            return;
        }

        var documents = chunks.Select(c => new SearchDocument
        {
            ["id"] = c.Id,
            ["title"] = c.Title,
            ["fileName"] = c.FileName,
            ["fileNameText"] = c.FileNameText,
            ["sourceUrl"] = c.SourceUrl,
            ["content"] = c.Content,
            ["sessionId"] = c.SessionId,
            ["fileId"] = c.FileId,
            ["contentVector"] = c.ContentVector.ToArray(),
        });

        var batch = IndexDocumentsBatch.Upload(documents);
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await _searchClient.IndexDocumentsAsync(batch, cancellationToken: cancellationToken);
                return;
            }
            catch (RequestFailedException ex) when (IsIndexNotReady(ex) && attempt < MaxIndexReadyAttempts)
            {
                logger.LogInformation(
                    "Index {Index} is not ready yet (attempt {Attempt}/{Max}); retrying push in {Delay}s.",
                    options.AiSearchIndex, attempt, MaxIndexReadyAttempts, IndexReadyRetryDelay.TotalSeconds);
                await Task.Delay(IndexReadyRetryDelay, cancellationToken);
            }
        }
    }

    /// <summary>Quotes <paramref name="value"/> as an OData string literal (single quotes doubled); the one escaping rule shared with <see cref="SearchAdapter"/>'s scope filter.</summary>
    public static string FilterLiteral(string value) => $"'{value.Replace("'", "''")}'";

    /// <summary>Deletes every chunk tagged with <paramref name="sessionId"/> (filter-then-delete); called on conversation delete, best-effort.</summary>
    public Task DeleteBySessionAsync(string sessionId, CancellationToken cancellationToken) =>
        DeleteByFilterAsync($"sessionId eq {FilterLiteral(sessionId)}", cancellationToken);

    /// <summary>Deletes every chunk for one <paramref name="fileId"/> within <paramref name="sessionId"/>; called on single-attachment delete, best-effort.</summary>
    public Task DeleteByFileAsync(string sessionId, string fileId, CancellationToken cancellationToken) =>
        DeleteByFilterAsync(
            $"sessionId eq {FilterLiteral(sessionId)} and fileId eq {FilterLiteral(fileId)}",
            cancellationToken);

    private async Task DeleteByFilterAsync(string filter, CancellationToken cancellationToken)
    {
        // Select only the key field so each page is cheap.
        var searchOptions = new SearchOptions
        {
            Filter = filter,
            Size = MaxDeleteBatchSize,
        };
        searchOptions.Select.Add("id");

        while (true)
        {
            var response = await _searchClient.SearchAsync<SearchDocument>("*", searchOptions, cancellationToken);
            var keys = new List<string>();
            await foreach (var result in response.Value.GetResultsAsync().WithCancellation(cancellationToken))
            {
                keys.Add((string)result.Document["id"]);
            }

            if (keys.Count == 0)
            {
                return;
            }

            var batch = IndexDocumentsBatch.Delete("id", keys);
            await _searchClient.IndexDocumentsAsync(batch, cancellationToken: cancellationToken);

            if (keys.Count < MaxDeleteBatchSize)
            {
                return;
            }
        }
    }

    // True for the transient "index is currently offline" 400 raised while an index is being (re)created.
    private static bool IsIndexNotReady(RequestFailedException ex) =>
        ex.Status == 400 && ex.Message.Contains("offline", StringComparison.OrdinalIgnoreCase);
}
