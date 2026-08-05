using AgentBackend.Configuration;
using AgentBackend.Models;
using AgentBackend.Services;

namespace AgentBackend.Endpoints;

/// <summary>
/// The file-attachment ingestion endpoints. <c>POST /files</c> (multipart) validates + persists + enqueues, returning <b>202</b> <c>processing</c>;
/// <c>GET /files/{fileId}</c> returns the poll status; plus the list/content/delete endpoints. Services resolved lazily so they aren't force-built before the 503 guard.
/// </summary>
public static class FilesEndpoints
{
    public static void MapFilesEndpoints(this IEndpointRouteBuilder app)
    {
        // Form is read manually (no [FromForm]/IFormFile), so antiforgery doesn't apply; the SPA calls cross-origin.
        app.MapPost("/files", PostFileAsync).DisableAntiforgery();
        app.MapGet("/files", GetSessionFilesAsync);
        app.MapGet("/files/{fileId}", GetFileStatusAsync);
        app.MapGet("/files/{fileId}/content", GetFileContentAsync);
        app.MapDelete("/files/{fileId}", DeleteFileAsync);
    }

    // Shared guards for the session-scoped handlers: 503 when ingestion isn't configured, 400 when sessionId is missing; null when OK.
    private static IResult? ValidateFilesRequest(AgentOptions options, string? sessionId)
    {
        if (!options.HasIngestionConfig)
        {
            return Results.Problem(statusCode: 503, detail: "File ingestion not configured.");
        }
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            return Results.Problem(statusCode: 400, detail: "sessionId query parameter is required.");
        }
        return null;
    }

    private static async Task<IResult> PostFileAsync(
        HttpRequest request, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        // Ingestion can't run without storage/DI/search + APIM.
        if (!options.HasIngestionConfig)
        {
            return Results.Problem(statusCode: 503, detail: "File ingestion not configured.");
        }

        if (!request.HasFormContentType)
        {
            return Results.Problem(statusCode: 400, detail: "Expected multipart/form-data.");
        }

        var form = await request.ReadFormAsync(ct);
        var file = form.Files["file"];
        var sessionId = form["sessionId"].ToString();

        if (file is null || file.Length == 0)
        {
            return Results.Problem(statusCode: 400, detail: "No file provided.");
        }
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            return Results.Problem(statusCode: 400, detail: "sessionId is required.");
        }

        var extension = Path.GetExtension(file.FileName).TrimStart('.').ToLowerInvariant();
        if (!SupportedFileTypes.IsSupported(extension))
        {
            return Results.Problem(statusCode: 415, detail: $"Unsupported file type: .{extension}");
        }

        var maxBytes = options.MaxUploadMb * 1024L * 1024L;
        if (file.Length > maxBytes)
        {
            return Results.Problem(statusCode: 413, detail: $"File exceeds the {options.MaxUploadMb} MB limit.");
        }

        await using var stream = file.OpenReadStream();
        var content = await BinaryData.FromStreamAsync(stream, ct);

        var ingestion = services.GetRequiredService<IngestionService>();
        try
        {
            // Persist + enqueue, then return 202; the pipeline runs in the background and the SPA polls GET /files/{fileId}.
            var fileId = await ingestion.EnqueueAsync(
                file.FileName, string.IsNullOrWhiteSpace(file.ContentType) ? "application/octet-stream" : file.ContentType,
                content, sessionId, ct);
            return Results.Json(
                new FileStatusResponse(fileId, file.FileName, IngestionStatuses.Processing), statusCode: 202);
        }
        catch (AgentInvocationException ex)
        {
            // Storage/queue failures were mapped to an HTTP status in IngestionService.
            return Results.Problem(statusCode: ex.StatusCode, detail: ex.Message);
        }
    }

    // Lists the conversation's attachments for the files panel; 503 when unconfigured, 400 when sessionId is missing.
    private static async Task<IResult> GetSessionFilesAsync(
        string? sessionId, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        if (ValidateFilesRequest(options, sessionId) is { } problem)
        {
            return problem;
        }

        var statusStore = services.GetRequiredService<IngestionStatusStore>();
        var files = await statusStore.ListAsync(sessionId!, ct);
        return Results.Json(new FileListResponse(files));
    }

    // Deletes a single attachment (blobs, chunks, status row), best-effort. Idempotent; returns 204.
    private static async Task<IResult> DeleteFileAsync(
        string fileId, string? sessionId, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        if (ValidateFilesRequest(options, sessionId) is { } problem)
        {
            return problem;
        }

        var ingestion = services.GetRequiredService<IngestionService>();
        await ingestion.PurgeFileAsync(sessionId!, fileId, ct);
        return Results.NoContent();
    }

    private static async Task<IResult> GetFileStatusAsync(
        string fileId, string? sessionId, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        if (ValidateFilesRequest(options, sessionId) is { } problem)
        {
            return problem;
        }

        var statusStore = services.GetRequiredService<IngestionStatusStore>();
        var status = await statusStore.GetAsync(sessionId!, fileId, ct);
        return status is null
            ? Results.Problem(statusCode: 404, detail: "Unknown file.")
            : Results.Json(status);
    }

    // Serves the original uploaded file for the citation preview popup. The status row (partitioned by sessionId) scopes
    // the lookup to this conversation and supplies the file name that keys the blob path. Inline by default; ?download=1 forces an attachment disposition.
    private static async Task<IResult> GetFileContentAsync(
        string fileId, string? sessionId, bool? download, HttpResponse response, AgentOptions options,
        IServiceProvider services, CancellationToken ct)
    {
        if (ValidateFilesRequest(options, sessionId) is { } problem)
        {
            return problem;
        }

        var statusStore = services.GetRequiredService<IngestionStatusStore>();
        var status = await statusStore.GetAsync(sessionId!, fileId, ct);
        if (status is null)
        {
            return Results.Problem(statusCode: 404, detail: "Unknown file.");
        }

        var storage = services.GetRequiredService<StorageService>();
        var content = await storage.DownloadAsync($"{fileId}/{status.FileName}", ct);

        // Stored-XSS defense: derive the content type from the validated extension (never the uploader's), serve only an
        // inline allowlist, and force everything else to application/octet-stream + attachment. `nosniff` blocks body re-sniffing.
        var extension = Path.GetExtension(status.FileName).TrimStart('.').ToLowerInvariant();
        var (contentType, inline) = InlineContentTypes.TryGetValue(extension, out var mapped)
            ? mapped
            : ("application/octet-stream", false);
        var asAttachment = download == true || !inline;

        response.Headers["X-Content-Type-Options"] = "nosniff";
        return Results.File(
            content.ToArray(),
            contentType,
            fileDownloadName: asAttachment ? status.FileName : null,
            enableRangeProcessing: true);
    }

    // Extension → (content type, render-inline?) for the preview endpoint; only script-inert, browser-renderable types are inline.
    private static readonly IReadOnlyDictionary<string, (string ContentType, bool Inline)> InlineContentTypes =
        new Dictionary<string, (string, bool)>(StringComparer.OrdinalIgnoreCase)
        {
            ["pdf"] = ("application/pdf", true),
            ["png"] = ("image/png", true),
            ["jpg"] = ("image/jpeg", true),
            ["jpeg"] = ("image/jpeg", true),
            ["bmp"] = ("image/bmp", true),
            ["tiff"] = ("image/tiff", false),
            ["tif"] = ("image/tiff", false),
            ["heif"] = ("image/heic", false),
            ["heic"] = ("image/heic", false),
            ["txt"] = ("text/plain; charset=utf-8", true),
            ["md"] = ("text/plain; charset=utf-8", true),
            ["csv"] = ("text/csv; charset=utf-8", true),
            ["tsv"] = ("text/tab-separated-values; charset=utf-8", true),
            ["json"] = ("application/json; charset=utf-8", true),
        };
}
