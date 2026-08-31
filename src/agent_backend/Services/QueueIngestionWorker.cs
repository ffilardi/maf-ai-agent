using System.Text.Json;
using AgentBackend.Models;
using Azure.Storage.Queues.Models;

namespace AgentBackend.Services;

/// <summary>
/// Background consumer for the ingestion queue. Runs <see cref="IngestionService.ProcessAsync"/> per message and records the outcome in
/// <see cref="IngestionStatusStore"/>: on success delete, on transient failure leave to reappear (retry), after <see cref="MaxDequeueCount"/> failures mark <c>failed</c> and poison.
/// </summary>
public sealed class QueueIngestionWorker(
    QueueService queue,
    IngestionService ingestion,
    IngestionStatusStore statusStore,
    ILogger<QueueIngestionWorker> logger) : BackgroundService
{
    private const int MaxMessages = 4;                                          // per-batch concurrency
    private const int MaxDequeueCount = 5;                                      // give up → poison after this
    private static readonly TimeSpan VisibilityTimeout = TimeSpan.FromMinutes(5); // must exceed processing time
    private static readonly TimeSpan IdlePollInterval = TimeSpan.FromSeconds(3);   // wait when the queue is empty

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // The queues are ensured at startup by IngestionInitializer (registered ahead of this worker).
        logger.LogInformation("Ingestion worker started.");

        while (!stoppingToken.IsCancellationRequested)
        {
            IReadOnlyList<QueueMessage> messages;
            try
            {
                messages = await queue.ReceiveBatchAsync(MaxMessages, VisibilityTimeout, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Failed to receive ingestion messages; backing off.");
                await DelayQuietly(IdlePollInterval, stoppingToken);
                continue;
            }

            if (messages.Count == 0)
            {
                await DelayQuietly(IdlePollInterval, stoppingToken);
                continue;
            }

            await Task.WhenAll(messages.Select(m => HandleMessageAsync(m, stoppingToken)));
        }
    }

    private async Task HandleMessageAsync(QueueMessage message, CancellationToken ct)
    {
        IngestionMessage? payload = null;
        try
        {
            payload = JsonSerializer.Deserialize<IngestionMessage>(message.MessageText);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Malformed ingestion message {MessageId}; moving to poison.", message.MessageId);
        }

        // Unparseable message: can't process or record status — poison it so it doesn't loop forever.
        if (payload is null)
        {
            await queue.SendToPoisonAsync(message.MessageText, ct);
            await queue.DeleteAsync(message, ct);
            return;
        }

        try
        {
            var chunkCount = await ingestion.ProcessAsync(payload, ct);
            await statusStore.SetIndexedAsync(payload.SessionId, payload.FileId, payload.FileName, chunkCount, ct);
            await queue.DeleteAsync(message, ct);
            logger.LogInformation(
                "Indexed {FileName} ({FileId}) into {ChunkCount} chunks.", payload.FileName, payload.FileId, chunkCount);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Host is shutting down mid-run; leave the message to be redelivered after the visibility timeout.
        }
        catch (Exception ex)
        {
            if (message.DequeueCount >= MaxDequeueCount)
            {
                logger.LogError(
                    ex, "Giving up on {FileName} ({FileId}) after {Attempts} attempts; moving to poison.",
                    payload.FileName, payload.FileId, message.DequeueCount);
                // The status row is read back by the SPA, so it records fixed text, not the provider's message
                // (CWE-209); the fileId logged above is the handle for the full exception.
                await statusStore.SetFailedAsync(
                    payload.SessionId, payload.FileId, payload.FileName,
                    $"{AgentInvocationException.SafeMessage(AgentInvocationException.MapExceptionStatus(ex))} "
                        + $"(reference: {payload.FileId})",
                    ct);
                await queue.SendToPoisonAsync(message.MessageText, ct);
                await queue.DeleteAsync(message, ct);
            }
            else
            {
                // Transient failure: leave the message hidden; it reappears after the visibility timeout to retry.
                logger.LogWarning(
                    ex, "Ingestion of {FileName} ({FileId}) failed (attempt {Attempts}); will retry.",
                    payload.FileName, payload.FileId, message.DequeueCount);
            }
        }
    }

    private static async Task DelayQuietly(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, ct);
        }
        catch (OperationCanceledException)
        {
            // shutting down
        }
    }
}
