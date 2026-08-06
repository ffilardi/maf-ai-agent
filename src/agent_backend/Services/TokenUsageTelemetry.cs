using System.Diagnostics.Metrics;
using Microsoft.Extensions.Logging;
using TokenUsage = AgentBackend.Models.TokenUsage;

namespace AgentBackend.Services;

/// <summary>
/// Emits per-turn token usage to Application Insights on two channels, because cost questions come in two shapes:
/// <list type="bullet">
/// <item>a low-cardinality OpenTelemetry counter set (dimensioned by <c>model</c> and <c>streaming</c>) that lands
/// in <c>customMetrics</c>, drives the per-model workbook tile, and is cheap enough to back metric alerts;</item>
/// <item>a structured log line (lands in <c>traces</c>) carrying the <c>sessionId</c>, which answers
/// "what did this conversation cost" without making a UUID a metric dimension.</item>
/// </list>
/// Registered unconditionally — the meter is inert unless <c>Program.cs</c> wires the Azure Monitor exporter,
/// and mirrors the <see cref="SearchAdapter"/> retrieval-manifest idiom for the log channel.
/// </summary>
public sealed class TokenUsageTelemetry : IDisposable
{
    /// <summary>Meter name; must match the <c>AddMeter</c> registration in <c>Program.cs</c>.</summary>
    public const string MeterName = "AgentBackend.Tokens";

    /// <summary>Marker the workbook KQL matches on to isolate the per-conversation cost rows in <c>traces</c>.</summary>
    private const string CostAuditMessage = "Token usage audit";

    private readonly Meter meter;
    private readonly Counter<long> promptTokens;
    private readonly Counter<long> completionTokens;
    private readonly Counter<long> totalTokens;
    private readonly Counter<long> cachedTokens;
    private readonly Counter<long> reasoningTokens;
    private readonly Counter<long> turns;
    private readonly ILogger<TokenUsageTelemetry> logger;

    public TokenUsageTelemetry(ILogger<TokenUsageTelemetry> logger)
    {
        this.logger = logger;
        meter = new Meter(MeterName);

        // Counter names surface verbatim as the customMetrics `name` the workbook tiles filter on; the shared
        // `agent.` prefix is what lets the gateway tiles exclude them (`name !startswith "agent."`).
        promptTokens = meter.CreateCounter<long>("agent.tokens.prompt", "token", "Prompt (input) tokens billed for a chat turn.");
        completionTokens = meter.CreateCounter<long>("agent.tokens.completion", "token", "Completion (output) tokens billed for a chat turn.");
        totalTokens = meter.CreateCounter<long>("agent.tokens.total", "token", "Total tokens billed for a chat turn.");
        cachedTokens = meter.CreateCounter<long>("agent.tokens.cached", "token", "Prompt tokens served from the provider cache (billed at the cached rate).");
        reasoningTokens = meter.CreateCounter<long>("agent.tokens.reasoning", "token", "Reasoning tokens consumed internally by the model (billed as output).");
        turns = meter.CreateCounter<long>("agent.turns", "turn", "Chat turns completed.");
    }

    /// <summary>
    /// Records one completed turn. <paramref name="usage"/> is null when the provider omitted usage — the turn is still
    /// counted so cost-per-turn averages stay honest. Never throws: telemetry must not fail a served answer.
    /// </summary>
    /// <param name="model">Deployment actually used for the turn (falls back to the agent default).</param>
    /// <param name="streaming">Distinguishes <c>/chat/stream</c> from buffered <c>/chat</c> in the metric dimensions.</param>
    public void Record(string? model, string sessionId, TokenUsage? usage, bool streaming)
    {
        try
        {
            // Two dimensions, both bounded: model is allow-listed, streaming is a boolean. sessionId is deliberately
            // NOT a dimension — it is a UUID, and one time series per conversation would blow up metric cost.
            var modelTag = new KeyValuePair<string, object?>("model", model ?? "unknown");
            var streamTag = new KeyValuePair<string, object?>("streaming", streaming);

            turns.Add(1, modelTag, streamTag);

            if (usage is null)
            {
                return;
            }

            promptTokens.Add(usage.PromptTokens, modelTag, streamTag);
            completionTokens.Add(usage.CompletionTokens, modelTag, streamTag);
            totalTokens.Add(usage.TotalTokens, modelTag, streamTag);
            reasoningTokens.Add(usage.ReasoningTokens, modelTag, streamTag);
            if (usage.CachedDetails is { ReadTokens: > 0 } cached)
            {
                cachedTokens.Add(cached.ReadTokens, modelTag, streamTag);
            }

            // High-cardinality channel: sessionId lives here, in traces, where cardinality is free.
            if (logger.IsEnabled(LogLevel.Information))
            {
                logger.LogInformation(
                    "{Marker}: session={SessionId} model={Model} streaming={Streaming} prompt={PromptTokens} "
                        + "completion={CompletionTokens} total={TotalTokens} cached={CachedTokens} reasoning={ReasoningTokens}",
                    CostAuditMessage,
                    sessionId,
                    model ?? "unknown",
                    streaming,
                    usage.PromptTokens,
                    usage.CompletionTokens,
                    usage.TotalTokens,
                    usage.CachedDetails?.ReadTokens ?? 0,
                    usage.ReasoningTokens);
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Token usage telemetry failed for session {SessionId}; turn was served normally.", sessionId);
        }
    }

    public void Dispose() => meter.Dispose();
}
