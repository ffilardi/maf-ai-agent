using AgentBackend.Configuration;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;

namespace AgentBackend.Services;

/// <summary>
/// Persists uploaded attachments in Blob Storage, each under its own fileId folder (<c>{fileId}/{originalName}</c> + <c>{fileId}/output.{ext}</c>).
/// Container created on first use; authenticates with the App Service's managed identity (<see cref="TokenCredential"/>), no account key.
/// </summary>
public sealed class StorageService(AgentOptions options, TokenCredential credential)
{
    private readonly BlobContainerClient _container =
        new BlobServiceClient(options.BlobEndpoint, credential).GetBlobContainerClient(options.StorageContainer);

    /// <summary>Ensures the (private) container exists; called once at startup by <see cref="IngestionInitializer"/>. Checks existence first to avoid a 409 warning.</summary>
    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        if (!await _container.ExistsAsync(cancellationToken))
        {
            await _container.CreateIfNotExistsAsync(PublicAccessType.None, cancellationToken: cancellationToken);
        }
    }

    /// <summary>Uploads a blob at <paramref name="blobPath"/> (overwriting) and returns its URI.</summary>
    public async Task<string> UploadAsync(
        string blobPath, BinaryData content, string contentType, CancellationToken cancellationToken)
    {
        var blob = _container.GetBlobClient(blobPath);
        await blob.UploadAsync(
            content.ToStream(),
            new BlobUploadOptions { HttpHeaders = new BlobHttpHeaders { ContentType = contentType } },
            cancellationToken);

        return blob.Uri.ToString();
    }

    /// <summary>Deletes every blob under <paramref name="prefix"/> (e.g. <c>{fileId}/</c>) — the original plus its extracted output.</summary>
    public async Task DeleteByPrefixAsync(string prefix, CancellationToken cancellationToken)
    {
        var blobs = _container.GetBlobsAsync(prefix: prefix, cancellationToken: cancellationToken);
        await foreach (var blob in blobs.WithCancellation(cancellationToken))
        {
            await _container.DeleteBlobIfExistsAsync(blob.Name, cancellationToken: cancellationToken);
        }
    }

    /// <summary>Downloads the blob at <paramref name="blobPath"/> (used by the worker and the preview endpoint).</summary>
    public async Task<BinaryData> DownloadAsync(string blobPath, CancellationToken cancellationToken)
    {
        var blob = _container.GetBlobClient(blobPath);
        var response = await blob.DownloadContentAsync(cancellationToken);
        return response.Value.Content;
    }
}
