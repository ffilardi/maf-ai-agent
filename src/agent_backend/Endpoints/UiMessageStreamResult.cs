using System.Text.Json;
using AgentBackend.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace AgentBackend.Endpoints;

/// <summary>
/// Writes an <see cref="UiStreamPart"/> sequence as the Vercel AI SDK UI Message Stream protocol (v1): each part a bare
/// <c>data: {json}\n\n</c> SSE line (flushed immediately), terminated by a literal <c>data: [DONE]</c>. Raw SSE, not <c>TypedResults.ServerSentEvents</c>,
/// which the AI SDK parser doesn't accept; carries the <c>x-vercel-ai-ui-message-stream</c> negotiation header.
/// </summary>
public sealed class UiMessageStreamResult(IAsyncEnumerable<UiStreamPart> parts) : IResult
{
    // Names are pinned with [JsonPropertyName], so Web defaults serialize consistently.
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task ExecuteAsync(HttpContext http)
    {
        var response = http.Response;
        // Transport negotiation + streaming headers the AI SDK client requires.
        response.ContentType = "text/event-stream";
        response.Headers["Cache-Control"] = "no-cache";
        response.Headers["Connection"] = "keep-alive";
        response.Headers["x-vercel-ai-ui-message-stream"] = "v1";
        response.Headers["X-Accel-Buffering"] = "no";

        var ct = http.RequestAborted;
        try
        {
            await foreach (var part in parts.WithCancellation(ct))
            {
                var json = JsonSerializer.Serialize(part, JsonOptions);
                await response.WriteAsync($"data: {json}\n\n", ct);
                await response.Body.FlushAsync(ct);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Client disconnected mid-stream; nothing to terminate.
            return;
        }
        catch (Exception ex)
        {
            // Last-resort net: log a post-headers exception and still write [DONE] below so the client sees a clean termination (avoids ERR_CONNECTION_RESET).
            http.RequestServices.GetRequiredService<ILoggerFactory>()
                .CreateLogger<UiMessageStreamResult>()
                .LogError(ex, "Streaming failed after headers committed; terminating stream with [DONE]");
        }

        await response.WriteAsync("data: [DONE]\n\n", ct);
        await response.Body.FlushAsync(ct);
    }
}
