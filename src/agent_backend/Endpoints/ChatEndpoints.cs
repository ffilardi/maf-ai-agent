using AgentBackend.Configuration;
using AgentBackend.Models;
using AgentBackend.Services;

namespace AgentBackend.Endpoints;

/// <summary>
/// The chat endpoints — buffered <c>POST /chat</c> (JSON), streaming <c>POST /chat/stream</c> (AI SDK UI Message Stream over SSE),
/// and the sessions-sidebar trio. <c>ChatService</c> is resolved lazily so its <c>AIAgent</c> singleton is only built after the config guards pass (503, not 500).
/// </summary>
public static class ChatEndpoints
{
    // Cap on how many conversations the sidebar lists (newest-first).
    private const int MaxSessions = 50;

    public static void MapChatEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/chat", PostChatAsync);
        app.MapPost("/chat/stream", PostChatStream);
        app.MapGet("/chat/sessions", GetSessionsAsync);
        app.MapGet("/chat/{sessionId}/messages", GetSessionMessagesAsync);
        app.MapDelete("/chat/{sessionId}", DeleteSessionAsync);
    }

    // Shared 503 guards for both chat handlers; returns the problem result when the pipeline can't serve the request, else null.
    private static IResult? ValidateChatConfig(AgentOptions options, ChatRequest req)
    {
        if (!options.HasApimConfig)
        {
            return Results.Problem(statusCode: 503, detail: "Agent not configured (APIM settings missing).");
        }
        if (RequireConversationStore(options) is { } problem)
        {
            return problem;
        }
        if (req.RagOnly && !options.HasAiSearchConfig)
        {
            return Results.Problem(statusCode: 503, detail: "RAG-only mode requires Azure AI Search, which is not configured.");
        }
        return null;
    }

    // 503 guard shared by the sessions trio (and folded into ValidateChatConfig); null when Cosmos is configured.
    private static IResult? RequireConversationStore(AgentOptions options) =>
        options.HasCosmosConfig
            ? null
            : Results.Problem(statusCode: 503, detail: "Conversation store not configured.");

    // Buffered chat endpoint — runs one MAF agent turn through the APIM gateway.
    private static async Task<IResult> PostChatAsync(
        ChatRequest req, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        // Short-circuit empty/whitespace input to avoid an unnecessary agent call.
        if (string.IsNullOrWhiteSpace(req.ChatInput))
        {
            return Results.Json(new ChatResponse(req.SessionId, Answer: "", UsedTools: Array.Empty<string>()));
        }

        if (ValidateChatConfig(options, req) is { } problem)
        {
            return problem;
        }

        var chat = services.GetRequiredService<ChatService>();
        try
        {
            var response = await chat.AskAsync(req, ct);
            return Results.Json(response);
        }
        catch (AgentInvocationException ex)
        {
            // Provider/gateway errors were already mapped to an HTTP status in ChatService.
            return Results.Problem(statusCode: ex.StatusCode, detail: ex.Message);
        }
    }

    // Streaming chat endpoint — same turn as /chat, delivered as the AI SDK UI Message Stream protocol.
    // Guards run before streaming starts (real HTTP status); after that a provider error is an in-band `error` part.
    private static IResult PostChatStream(
        ChatRequest req, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        // Short-circuit empty/whitespace input to a minimal empty assistant message.
        if (string.IsNullOrWhiteSpace(req.ChatInput))
        {
            static async IAsyncEnumerable<UiStreamPart> Empty(string sessionId)
            {
                yield return new UiStreamPart("start");
                yield return new UiStreamPart("message-metadata", MessageMetadata: new MessageMetadata(
                    UsedTools: Array.Empty<string>(), SessionId: sessionId));
                yield return new UiStreamPart("finish");
                await Task.CompletedTask;
            }
            return new UiMessageStreamResult(Empty(req.SessionId));
        }

        // Report 503 before any streaming begins (after that a failure is an in-band `error` part).
        if (ValidateChatConfig(options, req) is { } problem)
        {
            return problem;
        }

        var chat = services.GetRequiredService<ChatService>();
        return new UiMessageStreamResult(chat.StreamAsync(req, ct));
    }

    // Lists past conversations for the sidebar, newest-first (ConversationStore); 503 when Cosmos isn't configured.
    private static async Task<IResult> GetSessionsAsync(
        AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        if (RequireConversationStore(options) is { } problem)
        {
            return problem;
        }

        var store = services.GetRequiredService<ConversationStore>();
        var conversations = await store.ListAsync(MaxSessions, ct);
        return Results.Json(new ConversationListResponse(conversations));
    }

    // Returns a conversation's transcript (oldest-first); unknown id ⇒ 200 empty list; 503 when Cosmos isn't configured.
    private static async Task<IResult> GetSessionMessagesAsync(
        string sessionId, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        if (RequireConversationStore(options) is { } problem)
        {
            return problem;
        }

        var store = services.GetRequiredService<ConversationStore>();
        var messages = await store.GetMessagesAsync(sessionId, ct);
        return Results.Json(new ConversationHistoryResponse(sessionId, messages));
    }

    // Deletes a conversation's transcript; unless ?keepFiles=true, also best-effort purges the session's ingestion artifacts.
    // keepFiles=true clears the chat but leaves attachments indexed under the same sessionId (RAG stays scoped to them). Idempotent; 503 when Cosmos isn't configured.
    private static async Task<IResult> DeleteSessionAsync(
        string sessionId, bool? keepFiles, AgentOptions options, IServiceProvider services, CancellationToken ct)
    {
        if (RequireConversationStore(options) is { } problem)
        {
            return problem;
        }

        var store = services.GetRequiredService<ConversationStore>();
        await store.DeleteAsync(sessionId, ct);

        // GetService returns null when ingestion isn't configured; the transcript delete still stands.
        if (keepFiles != true && services.GetService<IngestionService>() is { } ingestion)
        {
            await ingestion.PurgeSessionAsync(sessionId, ct);
        }

        return Results.NoContent();
    }
}
