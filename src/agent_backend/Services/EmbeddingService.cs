using AgentBackend.Configuration;
using OpenAI.Embeddings;

namespace AgentBackend.Services;

/// <summary>
/// Generates embedding vectors through the APIM gateway (<c>text-embedding-3-large</c>), used at ingestion (<see cref="IngestionService"/>) and query time (<see cref="SearchAdapter"/>).
/// Shares <see cref="AgentFactory.BuildAzureOpenAIClient"/> so it routes through the same gateway/api-version wiring.
/// </summary>
public sealed class EmbeddingService(AgentOptions options)
{
    // Point at the gateway root (not the `/openai` base): the embedding client prepends its own `/openai/deployments/{deployment}/embeddings` (a `/openai` base would 404).
    // The embedding-only retry override lets a backend 429 (RateLimitReached) be retried honoring its Retry-After without adding backoff to interactive chat.
    private readonly EmbeddingClient _client =
        AgentFactory.BuildAzureOpenAIClient(options, appendOpenAiPath: false, maxRetries: options.EmbeddingMaxRetries)
            .GetEmbeddingClient(options.AiEmbeddingDeployment);

    private readonly int _batchSize = options.EmbeddingBatchSize;

    /// <summary>
    /// Embeds a batch of chunk texts, preserving order (result[i] is the vector for texts[i]).
    /// Splits into <see cref="AgentOptions.EmbeddingBatchSize"/>-sized requests (a large file must not embed every chunk in one
    /// oversized call that blows the deployment's TPM).
    /// </summary>
    public async Task<IReadOnlyList<ReadOnlyMemory<float>>> EmbedAsync(
        IReadOnlyList<string> texts, CancellationToken cancellationToken)
    {
        if (texts.Count == 0)
        {
            return Array.Empty<ReadOnlyMemory<float>>();
        }

        var vectors = new ReadOnlyMemory<float>[texts.Count];
        for (var start = 0; start < texts.Count; start += _batchSize)
        {
            var batch = texts.Skip(start).Take(_batchSize).ToArray();
            var response = await _client.GenerateEmbeddingsAsync(batch, cancellationToken: cancellationToken);

            var i = start;
            foreach (var embedding in response.Value)
            {
                vectors[i++] = embedding.ToFloats();
            }
        }

        return vectors;
    }

    /// <summary>Embeds a single query string; returns null if the text is blank.</summary>
    public async Task<ReadOnlyMemory<float>?> EmbedQueryAsync(string query, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return null;
        }

        var response = await _client.GenerateEmbeddingAsync(query, cancellationToken: cancellationToken);
        return response.Value.ToFloats();
    }
}
