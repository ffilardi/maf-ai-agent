using System.ClientModel;
using System.Runtime.CompilerServices;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;
// Alias DTOs to avoid the name clash with Microsoft.Extensions.AI.ChatResponse / ChatMessage.
using ChatRequest = AgentBackend.Models.ChatRequest;
using ChatResponse = AgentBackend.Models.ChatResponse;
using UiStreamPart = AgentBackend.Models.UiStreamPart;
using MessageMetadata = AgentBackend.Models.MessageMetadata;
using TokenUsage = AgentBackend.Models.TokenUsage;
using CachedTokenDetails = AgentBackend.Models.CachedTokenDetails;

namespace AgentBackend.Services;

/// <summary>Runs the shared agent for a single chat turn and shapes the result into the wire contract.</summary>
public sealed class ChatService(
    AIAgent agent,
    AgentBackend.Configuration.AgentOptions options,
    // contentSafety is null when Content Safety is disabled (CONTENT_SAFETY_MODE=off); the pre-check is then skipped.
    ContentSafetyService? contentSafety,
    ILogger<ChatService> logger)
{
    // Length cap on the per-session system prompt.
    private const int MaxSystemPromptChars = 8_000;

    // User-facing message when a turn is blocked by Content Safety.
    private const string ContentSafetyBlockMessage =
        "Your message was blocked by our content-safety filter. Please rephrase and try again.";

    /// <summary>
    /// Invokes the agent and returns the answer, tools used, and token usage.
    /// </summary>
    /// <exception cref="AgentInvocationException">
    /// Thrown when the model/gateway call fails; carries the mapped HTTP status code.
    /// </exception>
    public async Task<ChatResponse> AskAsync(ChatRequest request, CancellationToken ct)
    {
        var block = await CheckContentSafetyAsync(request.ChatInput, request.SessionId, ct);
        if (block is not null)
        {
            throw new AgentInvocationException(403, block);
        }

        var (message, session) = await BuildTurnAsync(request, ct);

        AgentResponse response;
        try
        {
            response = await agent.RunAsync(message, session, BuildRunOptions(request), cancellationToken: ct);
        }
        catch (ClientResultException ex)
        {
            // The APIM pipeline surfaces HTTP failures as ClientResultException with the status already parsed.
            throw new AgentInvocationException(AgentInvocationException.MapProviderStatus(ex.Status), ex.Message, ex);
        }

        var usedTools = ExtractUsedTools(response);
        var tokenUsage = ExtractTokenUsage(response);

        return new ChatResponse(request.SessionId, response.Text, usedTools, tokenUsage);
    }

    /// <summary>
    /// Streams the turn as the Vercel AI SDK UI Message Stream protocol (v1): <c>start</c>/<c>start-step</c>, the
    /// reasoning/tool/text parts, a terminal <c>message-metadata</c> (same usedTools/tokenUsage as <see cref="AskAsync"/>),
    /// then <c>finish-step</c>/<c>finish</c>. A provider failure is surfaced as an in-band <c>error</c> part since headers commit on first flush.
    /// </summary>
    public async IAsyncEnumerable<UiStreamPart> StreamAsync(
        ChatRequest request, [EnumeratorCancellation] CancellationToken ct)
    {
        // Content Safety pre-check before streaming begins; a block is surfaced as an in-band `error` part.
        var block = await CheckContentSafetyAsync(request.ChatInput, request.SessionId, ct);
        if (block is not null)
        {
            yield return new UiStreamPart("start");
            yield return new UiStreamPart("start-step");
            yield return new UiStreamPart("error", ErrorText: block);
            yield break;
        }

        var (message, session) = await BuildTurnAsync(request, ct);

        // Accumulate every update so the terminal metadata part reuses the same extraction as AskAsync.
        var updates = new List<AgentResponseUpdate>();

        yield return new UiStreamPart("start");
        yield return new UiStreamPart("start-step");

        // One block per kind per turn; the protocol requires a *-start before any *-delta for a given id.
        const string TextId = "0";
        const string ReasoningId = "reasoning-0";
        var textStarted = false;
        var reasoningStarted = false;
        var reasoningEnded = false;
        // Dedupe function calls/results by call id so each tool invocation yields one input part and one output part.
        var seenToolInputs = new HashSet<string>();

        // Enumerate manually so an exception from MoveNextAsync can be turned into a terminal error part (can't yield from a catch).
        // Catch broadly: a model/gateway ClientResultException or an end-of-turn Cosmos persist failure, discriminated on whether content already streamed.
        await using var enumerator =
            agent.RunStreamingAsync(message, session, BuildRunOptions(request), cancellationToken: ct).GetAsyncEnumerator(ct);

        while (true)
        {
            AgentResponseUpdate? update = null;
            UiStreamPart? error = null;
            try
            {
                if (!await enumerator.MoveNextAsync())
                {
                    break;
                }
                update = enumerator.Current;
            }
            catch (OperationCanceledException)
            {
                // Client disconnect — let it unwind.
                throw;
            }
            catch (Exception ex)
            {
                error = new UiStreamPart("error", ErrorText: ex.Message);
            }

            if (error is not null)
            {
                // Updates already present ⇒ the answer succeeded and this is the end-of-turn Cosmos persist failing:
                // log it and complete the stream normally (the post-loop closers finish any open blocks) so the client
                // still gets its answer, footer, and a clean `finish`.
                if (updates.Count > 0)
                {
                    // Log the persist payload (roles/content-types/sizes only, never text) so a batch-size rejection is self-diagnosing.
                    logger.LogError(
                        "Model responded but history persist failed (session={SessionId}): {Error}; "
                            + "completing stream — this turn was NOT saved to Cosmos. Persist payload: {Payload}",
                        request.SessionId,
                        error.ErrorText,
                        DescribePersistPayload(updates.ToAgentResponse()));
                    break;
                }

                // No streamed content ⇒ a model/gateway failure; no blocks are open yet, so the error part is terminal.
                yield return error;
                yield break;
            }

            updates.Add(update!);

            // Surface each content item as its own stream part, in the order the model produced them.
            foreach (var content in update!.Contents)
            {
                switch (content)
                {
                    // Reasoning summary chunks → one lazily-opened `reasoning` block.
                    case TextReasoningContent reasoning when !string.IsNullOrEmpty(reasoning.Text):
                        if (!reasoningStarted)
                        {
                            yield return new UiStreamPart("reasoning-start", Id: ReasoningId);
                            reasoningStarted = true;
                        }
                        yield return new UiStreamPart("reasoning-delta", Id: ReasoningId, Delta: reasoning.Text);
                        break;

                    // Answer text chunks → the `text` block; close reasoning first.
                    case TextContent text when !string.IsNullOrEmpty(text.Text):
                        if (reasoningStarted && !reasoningEnded)
                        {
                            yield return new UiStreamPart("reasoning-end", Id: ReasoningId);
                            reasoningEnded = true;
                        }
                        if (!textStarted)
                        {
                            yield return new UiStreamPart("text-start", Id: TextId);
                            textStarted = true;
                        }
                        yield return new UiStreamPart("text-delta", Id: TextId, Delta: text.Text);
                        break;

                    // Tool request → a `dynamic-tool` part in the `input-available` state.
                    case FunctionCallContent call when call.CallId is { Length: > 0 } && seenToolInputs.Add(call.CallId):
                        yield return new UiStreamPart(
                            "tool-input-available", ToolCallId: call.CallId, ToolName: call.Name,
                            Input: call.Arguments, Dynamic: true);
                        break;

                    // Tool result → the same `dynamic-tool` part transitions to `output-available`.
                    case FunctionResultContent result when result.CallId is { Length: > 0 }:
                        yield return new UiStreamPart(
                            "tool-output-available", ToolCallId: result.CallId, Output: result.Result, Dynamic: true);
                        break;
                }
            }
        }

        if (reasoningStarted && !reasoningEnded)
        {
            yield return new UiStreamPart("reasoning-end", Id: ReasoningId);
        }
        if (textStarted)
        {
            yield return new UiStreamPart("text-end", Id: TextId);
        }

        var response = updates.ToAgentResponse();
        yield return new UiStreamPart("message-metadata", MessageMetadata: new MessageMetadata(
            TokenUsage: ExtractTokenUsage(response),
            UsedTools: ExtractUsedTools(response),
            SessionId: request.SessionId));
        yield return new UiStreamPart("finish-step");
        yield return new UiStreamPart("finish");
    }

    // Per-request agent options (never null). Carries the request sessionId in ChatOptions.AdditionalProperties so the RAG
    // SearchAdapter can scope retrieval — a data channel, since an AsyncLocal wouldn't survive the pipeline's execution-context re-rooting.
    // Reasoning effort and model ride the same options; MAF merges them over the agent defaults (a null ModelId keeps the default).
    // Instructions are materialised in full by BuildInstructions (never null) so the always-appended SafetyDirective can't be dropped.
    // RawRepresentationFactory is always re-set so the Responses request keeps StoredOutputEnabled=false.
    private ChatClientAgentRunOptions BuildRunOptions(ChatRequest request)
    {
        var model = ResolveModel(request.Model);
        var instructions = BuildInstructions(request);

        return new ChatClientAgentRunOptions
        {
            ChatOptions = new Microsoft.Extensions.AI.ChatOptions
            {
                // Null leaves the agent default in place; a value replaces it for this turn.
                ModelId = model,
                Instructions = instructions,
                RawRepresentationFactory = _ => AgentFactory.BuildResponseOptions(request.ReasoningEffort),
                AdditionalProperties = new Microsoft.Extensions.AI.AdditionalPropertiesDictionary
                {
                    [AgentFactory.SessionIdPropertyKey] = request.SessionId,
                },
            },
        };
    }

    // Honour a per-request model only when in the configured allow-list (case-insensitive); else fall back to the agent default.
    private string? ResolveModel(string? model)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            return null;
        }
        return options.Models.Contains(model, StringComparer.OrdinalIgnoreCase) ? model : null;
    }

    // Assembles the effective per-turn instructions: the per-request/env base prompt (or the built-in default), plus the
    // RAG-only grounding directive when requested, then always the non-overridable SafetyDirective last. Materialised in
    // full (rather than left null to fall back on the agent default) so Layer-0 safety survives a custom prompt replacing the base.
    private string BuildInstructions(ChatRequest request)
    {
        var systemPrompt = ResolveSystemPrompt(request.SystemPrompt);
        var baseInstructions = systemPrompt
            ?? options.AgentInstructions
            ?? (request.RagOnly ? AgentFactory.GroundedOnlyInstructions : AgentFactory.DefaultAgentInstructions);

        // RAG-only appends the grounding directive so it holds regardless of prompt overrides.
        var instructions = request.RagOnly
            ? $"{baseInstructions}\n\n{AgentFactory.GroundedOnlyDirective}"
            : baseInstructions;

        // SafetyDirective is always last so it survives — and outranks — any per-request/env prompt.
        return $"{instructions}\n\n{AgentFactory.SafetyDirective}";
    }

    // Accept a non-blank per-session prompt, trimmed and length-capped; blank ⇒ null (agent default applies).
    private static string? ResolveSystemPrompt(string? prompt)
    {
        if (string.IsNullOrWhiteSpace(prompt))
        {
            return null;
        }
        var trimmed = prompt.Trim();
        return trimmed.Length > MaxSystemPromptChars ? trimmed[..MaxSystemPromptChars] : trimmed;
    }

    // Content Safety pre-check for a turn: returns a block message when rejected (block mode + flagged verdict), else null. Detections are logged in every mode.
    private async Task<string?> CheckContentSafetyAsync(string input, string sessionId, CancellationToken ct)
    {
        if (contentSafety is null || string.IsNullOrWhiteSpace(input))
        {
            return null;
        }

        var verdict = await contentSafety.EvaluateAsync(input, ct);
        if (!verdict.Flagged)
        {
            return null;
        }

        var categories = string.Join(", ", verdict.Categories
            .Where(c => c.Severity >= options.ContentSafetyThreshold)
            .Select(c => $"{c.Category}={c.Severity}"));
        logger.LogWarning(
            "Content safety flagged session {SessionId}: categories=[{Categories}] promptAttack={Attack} mode={Mode}",
            sessionId, categories, verdict.PromptAttackDetected, options.ContentSafetyMode);

        return options.IsContentSafetyBlocking ? ContentSafetyBlockMessage : null;
    }

    // Builds the per-request user message and a fresh session tagged with the conversation id (= sessionId) the
    // Cosmos history provider reads back to load/persist turns. Shared by AskAsync and StreamAsync.
    private async Task<(ChatMessage Message, AgentSession Session)> BuildTurnAsync(
        ChatRequest request, CancellationToken ct)
    {
        // Preserve the asking user's name on the message.
        var message = new ChatMessage(ChatRole.User, request.ChatInput);
        if (!string.IsNullOrWhiteSpace(request.UserName))
        {
            message.AuthorName = request.UserName;
        }

        var session = await agent.CreateSessionAsync(ct);
        session.StateBag.SetValue(AgentFactory.ConversationIdStateKey, request.SessionId, null);

        // RAG retrieval scope (sessionId) is threaded via ChatOptions.AdditionalProperties in BuildRunOptions, not an AsyncLocal
        // (which wouldn't survive the pipeline's execution-context re-rooting). See AgentFactory.SessionIdPropertyKey and SearchAdapter.
        return (message, session);
    }

    // Describes the Cosmos persist payload for the failure branch: message count + per-message role/content-type/byte breakdown,
    // plus the total after StripToolPlumbing. Sizes and types only, never content text.
    private static string DescribePersistPayload(AgentResponse response)
    {
        var messages = response.Messages;
        long total = 0;
        long afterStrip = 0;
        var parts = new List<string>(messages.Count);

        foreach (var msg in messages)
        {
            var hasToolPlumbing = msg.Contents.Any(c => c is FunctionCallContent or FunctionResultContent);
            var types = new List<string>(msg.Contents.Count);
            long msgBytes = 0;
            foreach (var content in msg.Contents)
            {
                var bytes = EstimateContentBytes(content);
                msgBytes += bytes;
                types.Add($"{content.GetType().Name}={bytes}");
            }

            total += msgBytes;
            if (!hasToolPlumbing)
            {
                afterStrip += msgBytes;
            }

            parts.Add($"{msg.Role}[{(hasToolPlumbing ? "stripped" : "kept")}]:{{{string.Join(",", types)}}}");
        }

        return $"msgs={messages.Count} totalBytes={total} afterStripBytes={afterStrip} "
            + $"[{string.Join("; ", parts)}]";
    }

    // Rough serialized size of one content item for the persist diagnostic; best-effort, degrades to 0 on failure.
    private static long EstimateContentBytes(AIContent content)
    {
        try
        {
            return content switch
            {
                TextReasoningContent reasoning => reasoning.Text?.Length ?? 0,
                TextContent text => text.Text?.Length ?? 0,
                FunctionCallContent call => System.Text.Json.JsonSerializer.Serialize(call.Arguments).Length,
                FunctionResultContent result => System.Text.Json.JsonSerializer.Serialize(result.Result).Length,
                _ => 0,
            };
        }
        catch
        {
            return 0;
        }
    }

    // Collect the distinct tool names in call order from the response's FunctionCallContent.
    private static IReadOnlyList<string> ExtractUsedTools(AgentResponse response) =>
        response.Messages
            .SelectMany(m => m.Contents)
            .OfType<FunctionCallContent>()
            .Select(c => c.Name)
            .Distinct()
            .ToList();

    // Token usage is optional (present-but-null in the contract when the provider omits it).
    private static TokenUsage? ExtractTokenUsage(AgentResponse response)
    {
        var usage = response.Usage;
        if (usage is null)
        {
            return null;
        }

        var prompt = (int)(usage.InputTokenCount ?? 0);
        var completion = (int)(usage.OutputTokenCount ?? 0);
        // Prefer the provider total; fall back to prompt+completion (matches the Python summation).
        var total = (int)(usage.TotalTokenCount ?? (prompt + completion));

        // Prompt-caching details — tokens read back from the cache (Azure OpenAI gpt-4.1/gpt-5+).
        var cached = usage.CachedInputTokenCount;
        CachedTokenDetails? cachedDetails = cached.HasValue && cached.Value > 0
            ? new CachedTokenDetails(ReadTokens: (int)cached.Value)
            : null;

        // Reasoning/thinking tokens used internally by the model (reasoning models, o-series).
        var reasoning = usage.ReasoningTokenCount ?? 0;

        return new TokenUsage(prompt, completion, total, cachedDetails, (int)reasoning);
    }

}

/// <summary>
/// Raised when an agent invocation fails; <see cref="StatusCode"/> is the HTTP status to return.
/// </summary>
public sealed class AgentInvocationException(int statusCode, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public int StatusCode { get; } = statusCode;

    /// <summary>Provider/gateway error codes → HTTP status: pass through the known ones, default the rest to 500.</summary>
    public static int MapProviderStatus(int providerStatus) => providerStatus switch
    {
        429 => 429, // RateLimited / Throttled
        401 => 401, // Unauthorized
        403 => 403, // Forbidden
        400 => 400, // BadRequest / InvalidRequest
        503 => 503, // ServiceUnavailable
        _ => 500,
    };
}
