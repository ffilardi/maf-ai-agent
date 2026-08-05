using System.Text;
using AgentBackend.Models;
using Azure;

namespace AgentBackend.Services;

/// <summary>
/// The file-attachment RAG pipeline, split for async processing. <see cref="EnqueueAsync"/> (request path) persists the original,
/// records a <c>processing</c> status, and enqueues so <c>POST /files</c> can answer 202. <see cref="ProcessAsync"/> (worker) downloads
/// it, converts to markdown (Document Intelligence for binary/office/HTML, verbatim for text), chunks + embeds, and pushes the chunks tagged by <c>sessionId</c>.
/// </summary>
public sealed class IngestionService(
    StorageService storage,
    QueueService queue,
    IngestionStatusStore statusStore,
    DocumentIntelligenceService documentIntelligence,
    EmbeddingService embeddings,
    SearchIndexer searchIndexer,
    ILogger<IngestionService> logger)
{
    /// <summary>Request-path step: persist the original, mark it <c>processing</c>, enqueue it, and return the generated file id.</summary>
    /// <exception cref="AgentInvocationException">Blob/queue/table failed; carries the mapped HTTP status.</exception>
    public async Task<string> EnqueueAsync(
        string fileName, string contentType, BinaryData content, string sessionId, CancellationToken ct)
    {
        var fileId = Guid.NewGuid().ToString();
        var blobPath = $"{fileId}/{fileName}";

        try
        {
            var sourceUrl = await storage.UploadAsync(blobPath, content, contentType, ct);
            await statusStore.SetProcessingAsync(sessionId, fileId, fileName, ct);
            await queue.EnqueueAsync(
                new IngestionMessage(fileId, sessionId, fileName, contentType, blobPath, sourceUrl), ct);
            return fileId;
        }
        catch (RequestFailedException ex)
        {
            throw new AgentInvocationException(AgentInvocationException.MapProviderStatus(ex.Status), ex.Message, ex);
        }
    }

    /// <summary>Worker step: run the conversion → chunk → embed → index pipeline for one message and return the chunk count. Throws so the worker can retry/poison.</summary>
    public async Task<int> ProcessAsync(IngestionMessage message, CancellationToken ct)
    {
        var content = await storage.DownloadAsync(message.BlobPath, ct);
        var extension = Path.GetExtension(message.FileName).TrimStart('.').ToLowerInvariant();

        // Textual files verbatim (output.{ext}); everything else via Document Intelligence layout → markdown (output.md).
        // Title cascade: DI title → first markdown/text heading → file name without extension.
        string text;
        string outputName;
        string outputContentType;
        string? detectedTitle;
        if (SupportedFileTypes.IsText(extension))
        {
            text = Encoding.UTF8.GetString(content.ToArray());
            outputName = $"output.{extension}";
            outputContentType = "text/plain; charset=utf-8";
            detectedTitle = MarkdownTitle.Extract(text);
        }
        else
        {
            var analysis = await documentIntelligence.AnalyzeAsync(content, ct);
            text = analysis.Markdown;
            outputName = "output.md";
            outputContentType = "text/markdown; charset=utf-8";
            detectedTitle = analysis.Title ?? MarkdownTitle.Extract(text);
        }

        var title = string.IsNullOrWhiteSpace(detectedTitle)
            ? Path.GetFileNameWithoutExtension(message.FileName)
            : detectedTitle;

        await storage.UploadAsync(
            $"{message.FileId}/{outputName}", BinaryData.FromString(text), outputContentType, ct);

        var chunks = MarkdownChunker.Chunk(text);
        var vectors = await embeddings.EmbedAsync(chunks, ct);

        // Extension-stripped file name for the searchable fileNameText field: the extension is pure noise (the analyzer tokenizes "report.pdf" → "report","pdf", and "pdf" would then match every PDF).
        var fileNameText = Path.GetFileNameWithoutExtension(message.FileName);

        // The index is ensured at startup by IngestionInitializer, so the push path just uploads.
        var documents = new List<SearchIndexer.ChunkDocument>(chunks.Count);
        for (var i = 0; i < chunks.Count; i++)
        {
            documents.Add(new SearchIndexer.ChunkDocument(
                Id: $"{message.FileId}-{i}",
                Title: title,
                FileName: message.FileName,
                FileNameText: fileNameText,
                SourceUrl: message.SourceUrl,
                Content: chunks[i],
                SessionId: message.SessionId,
                FileId: message.FileId,
                ContentVector: vectors[i]));
        }

        await searchIndexer.UploadAsync(documents, ct);
        return chunks.Count;
    }

    /// <summary>Removes a conversation's ingestion artifacts (search chunks, blobs, status rows) on delete. Best-effort: each step isolated, never throws, failures logged at Error.</summary>
    public async Task PurgeSessionAsync(string sessionId, CancellationToken ct)
    {
        // Blob layout is keyed by fileId, so list the session's files before deleting the status rows.
        IReadOnlyList<string> fileIds = Array.Empty<string>();
        try
        {
            fileIds = await statusStore.ListFileIdsAsync(sessionId, ct);
        }
        catch (Exception ex)
        {
            logger.LogError(
                ex, "Failed to list ingestion files for session {SessionId}; manual cleanup required.", sessionId);
        }

        await RunBestEffortAsync(
            () => searchIndexer.DeleteBySessionAsync(sessionId, ct),
            $"purge search chunks for session {sessionId}");
        foreach (var fileId in fileIds)
        {
            await RunBestEffortAsync(
                () => storage.DeleteByPrefixAsync($"{fileId}/", ct),
                $"purge blobs for file {fileId} in session {sessionId}");
        }
        await RunBestEffortAsync(
            () => statusStore.DeleteBySessionAsync(sessionId, ct),
            $"purge status rows for session {sessionId}");
    }

    /// <summary>Single-file counterpart of <see cref="PurgeSessionAsync"/> scoped to <paramref name="fileId"/> within <paramref name="sessionId"/>; same best-effort shape.</summary>
    public async Task PurgeFileAsync(string sessionId, string fileId, CancellationToken ct)
    {
        await RunBestEffortAsync(
            () => searchIndexer.DeleteByFileAsync(sessionId, fileId, ct),
            $"purge search chunks for file {fileId} in session {sessionId}");
        await RunBestEffortAsync(
            () => storage.DeleteByPrefixAsync($"{fileId}/", ct),
            $"purge blobs for file {fileId} in session {sessionId}");
        await RunBestEffortAsync(
            () => statusStore.DeleteAsync(sessionId, fileId, ct),
            $"purge status row for file {fileId} in session {sessionId}");
    }

    // Isolates one best-effort cleanup step: a failure is logged at Error (naming the scope) and swallowed.
    private async Task RunBestEffortAsync(Func<Task> step, string description)
    {
        try
        {
            await step();
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to {CleanupStep}; manual cleanup required.", description);
        }
    }
}
