using System.Text.Json.Serialization;

namespace AgentBackend.Models;

/// <summary>Ingestion status values shared by the wire contract and the status store.</summary>
public static class IngestionStatuses
{
    public const string Processing = "processing";
    public const string Indexed = "indexed";
    public const string Failed = "failed";
}

/// <summary>Per-file ingestion status, returned by <c>POST /files</c> and polled via <c>GET /files/{fileId}</c> until <c>indexed</c>/<c>failed</c>. camelCase on the wire.</summary>
public sealed record FileStatusResponse(
    [property: JsonPropertyName("fileId")] string FileId,
    [property: JsonPropertyName("fileName")] string FileName,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("chunkCount"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? ChunkCount = null,
    [property: JsonPropertyName("error"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Error = null
);

/// <summary>The session's attachments, returned by <c>GET /files?sessionId=…</c> for the files panel.</summary>
public sealed record FileListResponse(
    [property: JsonPropertyName("files")] IReadOnlyList<FileStatusResponse> Files
);

/// <summary>The queue message the enqueue step writes and <c>QueueIngestionWorker</c> consumes: the persisted original's blob path plus scope tags. JSON on the queue.</summary>
public sealed record IngestionMessage(
    [property: JsonPropertyName("fileId")] string FileId,
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("fileName")] string FileName,
    [property: JsonPropertyName("contentType")] string ContentType,
    [property: JsonPropertyName("blobPath")] string BlobPath,
    [property: JsonPropertyName("sourceUrl")] string SourceUrl
);

/// <summary>Accepted attachment file types, split by text path (<see cref="TextExtensions"/>, skip DI) vs. binary/office/HTML (<see cref="DocumentExtensions"/>, via DI). The frontend's <c>accept</c> list mirrors this.</summary>
public static class SupportedFileTypes
{
    // Already-textual formats — used verbatim (persisted as output.{ext}), no Document Intelligence call.
    public static readonly IReadOnlySet<string> TextExtensions =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "txt", "csv", "md", "json", "tsv" };

    // Formats Document Intelligence prebuilt-layout converts to markdown (output.md).
    public static readonly IReadOnlySet<string> DocumentExtensions =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "pdf", "jpg", "jpeg", "png", "bmp", "tiff", "tif", "heif", "heic", "docx", "xlsx", "pptx", "html", "htm",
        };

    public static bool IsText(string extension) => TextExtensions.Contains(extension);

    public static bool IsSupported(string extension) =>
        TextExtensions.Contains(extension) || DocumentExtensions.Contains(extension);
}
