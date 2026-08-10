using System.Text.Json;
using AgentBackend.Configuration;
using AgentBackend.Models;
using Azure.Core;
using Azure.Storage.Queues;
using Azure.Storage.Queues.Models;

namespace AgentBackend.Services;

/// <summary>
/// Storage-queue transport for async ingestion: <c>POST /files</c> enqueues an <see cref="IngestionMessage"/>, <see cref="QueueIngestionWorker"/> consumes it.
/// Work + poison queues live in the storage account (managed identity), created on first use. Messages are plain JSON.
/// </summary>
public sealed class QueueService
{
    private readonly QueueClient _queue;
    private readonly QueueClient _poison;

    public QueueService(AgentOptions options, TokenCredential credential)
    {
        var queueService = new QueueServiceClient(options.QueueEndpoint, credential);
        _queue = queueService.GetQueueClient(options.IngestionQueue);
        _poison = queueService.GetQueueClient($"{options.IngestionQueue}-poison");
    }

    /// <summary>Creates the work + poison queues if absent; called once at startup by <see cref="IngestionInitializer"/> before polling begins.</summary>
    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        await CreateIfMissingAsync(_queue, cancellationToken);
        await CreateIfMissingAsync(_poison, cancellationToken);
    }

    // Checks existence first to avoid a 409 the SDK logs at warning.
    private static async Task CreateIfMissingAsync(QueueClient queue, CancellationToken cancellationToken)
    {
        if (!await queue.ExistsAsync(cancellationToken))
        {
            await queue.CreateIfNotExistsAsync(cancellationToken: cancellationToken);
        }
    }

    /// <summary>Enqueues one ingestion message (JSON).</summary>
    public Task EnqueueAsync(IngestionMessage message, CancellationToken cancellationToken) =>
        _queue.SendMessageAsync(JsonSerializer.Serialize(message), cancellationToken);

    /// <summary>Receives a batch, hiding each for <paramref name="visibilityTimeout"/>; an undeleted message reappears after the timeout.</summary>
    public async Task<IReadOnlyList<QueueMessage>> ReceiveBatchAsync(
        int maxMessages, TimeSpan visibilityTimeout, CancellationToken cancellationToken)
    {
        var response = await _queue.ReceiveMessagesAsync(maxMessages, visibilityTimeout, cancellationToken);
        return response.Value;
    }

    /// <summary>Deletes a processed message so it isn't redelivered.</summary>
    public Task DeleteAsync(QueueMessage message, CancellationToken cancellationToken) =>
        _queue.DeleteMessageAsync(message.MessageId, message.PopReceipt, cancellationToken);

    /// <summary>Moves a give-up message onto the poison queue for later inspection.</summary>
    public Task SendToPoisonAsync(string messageText, CancellationToken cancellationToken) =>
        _poison.SendMessageAsync(messageText, cancellationToken);
}
