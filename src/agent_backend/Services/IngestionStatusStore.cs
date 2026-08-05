using AgentBackend.Configuration;
using AgentBackend.Models;
using Azure;
using Azure.Core;
using Azure.Data.Tables;

namespace AgentBackend.Services;

/// <summary>
/// Per-file ingestion status in Table Storage, polled by <c>GET /files/{fileId}</c> while the worker runs.
/// Partitioned by <c>sessionId</c> with <c>fileId</c> as the row key (point read = single lookup); table created on first use.
/// </summary>
public sealed class IngestionStatusStore(AgentOptions options, TokenCredential credential)
{
    private readonly TableClient _table =
        new(options.TableEndpoint, options.IngestionStatusTable, credential);
    private readonly TableServiceClient _tableService = new(options.TableEndpoint, credential);

    private sealed class StatusEntity : ITableEntity
    {
        public string PartitionKey { get; set; } = string.Empty; // sessionId
        public string RowKey { get; set; } = string.Empty;       // fileId
        public string FileName { get; set; } = string.Empty;
        public string Status { get; set; } = string.Empty;
        public int? ChunkCount { get; set; }
        public string? Error { get; set; }
        public DateTimeOffset? Timestamp { get; set; }
        public ETag ETag { get; set; }
    }

    /// <summary>Ensures the status table exists; called once at startup by <see cref="IngestionInitializer"/>. Checks existence first (via a service query) to avoid a 409 warning.</summary>
    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        if (!await TableExistsAsync(cancellationToken))
        {
            await _table.CreateIfNotExistsAsync(cancellationToken);
        }
    }

    private async Task<bool> TableExistsAsync(CancellationToken cancellationToken)
    {
        var tables = _tableService.QueryAsync(
            filter: $"TableName eq '{options.IngestionStatusTable}'", cancellationToken: cancellationToken);
        await foreach (var _ in tables)
        {
            return true;
        }
        return false;
    }

    public Task SetProcessingAsync(string sessionId, string fileId, string fileName, CancellationToken ct) =>
        UpsertAsync(sessionId, fileId, fileName, IngestionStatuses.Processing, null, null, ct);

    public Task SetIndexedAsync(string sessionId, string fileId, string fileName, int chunkCount, CancellationToken ct) =>
        UpsertAsync(sessionId, fileId, fileName, IngestionStatuses.Indexed, chunkCount, null, ct);

    public Task SetFailedAsync(string sessionId, string fileId, string fileName, string error, CancellationToken ct) =>
        UpsertAsync(sessionId, fileId, fileName, IngestionStatuses.Failed, null, error, ct);

    private async Task UpsertAsync(
        string sessionId, string fileId, string fileName, string status, int? chunkCount, string? error,
        CancellationToken cancellationToken)
    {
        var entity = new StatusEntity
        {
            PartitionKey = sessionId,
            RowKey = fileId,
            FileName = fileName,
            Status = status,
            ChunkCount = chunkCount,
            Error = error,
        };
        await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace, cancellationToken);
    }

    /// <summary>Lists every file id (row key) recorded for a conversation — the single-partition query.</summary>
    public async Task<IReadOnlyList<string>> ListFileIdsAsync(string sessionId, CancellationToken cancellationToken)
    {
        var fileIds = new List<string>();
        var entities = _table.QueryAsync<StatusEntity>(
            e => e.PartitionKey == sessionId, cancellationToken: cancellationToken);
        await foreach (var entity in entities.WithCancellation(cancellationToken))
        {
            fileIds.Add(entity.RowKey);
        }
        return fileIds;
    }

    /// <summary>Lists every file's status for a conversation (the single-partition query), for the files panel.</summary>
    public async Task<IReadOnlyList<FileStatusResponse>> ListAsync(string sessionId, CancellationToken cancellationToken)
    {
        var files = new List<FileStatusResponse>();
        var entities = _table.QueryAsync<StatusEntity>(
            e => e.PartitionKey == sessionId, cancellationToken: cancellationToken);
        await foreach (var e in entities.WithCancellation(cancellationToken))
        {
            files.Add(new FileStatusResponse(e.RowKey, e.FileName, e.Status, e.ChunkCount, e.Error));
        }
        return files;
    }

    /// <summary>Deletes a single file's status row. Idempotent (a missing row 404s and is ignored).</summary>
    public async Task DeleteAsync(string sessionId, string fileId, CancellationToken cancellationToken)
    {
        try
        {
            await _table.DeleteEntityAsync(sessionId, fileId, ETag.All, cancellationToken);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
        }
    }

    /// <summary>Deletes every status row for a conversation. Idempotent (a missing row 404s and is ignored).</summary>
    public async Task DeleteBySessionAsync(string sessionId, CancellationToken cancellationToken)
    {
        var entities = _table.QueryAsync<StatusEntity>(
            e => e.PartitionKey == sessionId, cancellationToken: cancellationToken);
        await foreach (var entity in entities.WithCancellation(cancellationToken))
        {
            try
            {
                await _table.DeleteEntityAsync(sessionId, entity.RowKey, ETag.All, cancellationToken);
            }
            catch (RequestFailedException ex) when (ex.Status == 404)
            {
            }
        }
    }

    /// <summary>Reads a file's status; null when unknown (no record yet / wrong conversation).</summary>
    public async Task<FileStatusResponse?> GetAsync(string sessionId, string fileId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await _table.GetEntityAsync<StatusEntity>(sessionId, fileId, cancellationToken: cancellationToken);
            var e = response.Value;
            return new FileStatusResponse(e.RowKey, e.FileName, e.Status, e.ChunkCount, e.Error);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }
}
