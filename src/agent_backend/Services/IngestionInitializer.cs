namespace AgentBackend.Services;

/// <summary>
/// One-time startup initializer: ensures the Blob container, work + poison queues, status table, and search index exist before traffic,
/// so the hot paths never re-check. Runs ahead of <see cref="QueueIngestionWorker"/> (StartAsync completes first). Failures are logged, not fatal.
/// </summary>
public sealed class IngestionInitializer(
    StorageService storage,
    QueueService queue,
    IngestionStatusStore statusStore,
    SearchIndexer searchIndexer,
    ILogger<IngestionInitializer> logger) : IHostedService
{
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        try
        {
            await storage.InitializeAsync(cancellationToken);
            await queue.InitializeAsync(cancellationToken);
            await statusStore.InitializeAsync(cancellationToken);
            await searchIndexer.InitializeAsync(cancellationToken);
            logger.LogInformation("Ingestion resources ensured.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to ensure ingestion resources at startup; ingestion may degrade.");
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
