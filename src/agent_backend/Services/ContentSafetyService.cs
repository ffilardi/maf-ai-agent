using System.Diagnostics.Metrics;
using System.Text.Json;
using AgentBackend.Configuration;

namespace AgentBackend.Services;

/// <summary>
/// Azure AI Content Safety screening via the APIM gateway (/contentsafety, Ocp-Apim-Subscription-Key header), in two stages:
/// per-turn on the user's message (<c>text:analyze</c> severities + <c>text:shieldPrompt</c> jailbreak detection), and
/// per-document on ingested file text (<c>text:shieldPrompt</c>'s <c>documents</c> channel, for embedded instructions).
/// Fails <b>open</b> on any error (logs a warning, reports "nothing detected") so a Content Safety outage never takes chat down —
/// but says so via the <c>Evaluated</c> flag and the <c>outcome=failopen</c> counter, so the gap is visible and can be alerted on.
/// </summary>
public sealed class ContentSafetyService : IDisposable
{
    /// <summary>Meter name; must match the <c>AddMeter</c> registration in <c>Program.cs</c>.</summary>
    public const string MeterName = "AgentBackend.ContentSafety";

    // Data-plane api-version for text:analyze + text:shieldPrompt.
    private const string ApiVersion = "2024-09-01";

    // Content Safety caps a single text input at 10K chars; truncate defensively so an oversized prompt is still screened.
    private const int MaxTextChars = 10_000;

    // Documents per shieldPrompt call; kept small to stay well inside the request-size limit.
    private const int DocumentBatchSize = 5;

    // Values of the "stage" counter dimension.
    private const string TurnStage = "turn";
    private const string DocumentStage = "document";

    private readonly AgentOptions _options;
    private readonly ILogger<ContentSafetyService> _logger;
    // One long-lived client routing through the APIM gateway.
    private readonly HttpClient _http = new();
    private readonly Uri _analyzeUri;
    private readonly Uri _shieldUri;
    private readonly Meter _meter;
    private readonly Counter<long> _evaluations;

    public ContentSafetyService(AgentOptions options, ILogger<ContentSafetyService> logger)
    {
        _options = options;
        _logger = logger;
        _meter = new Meter(MeterName);
        // Two low-cardinality dimensions (2 x 3 values), so this lands in customMetrics and a metric alert can fire on it.
        _evaluations = _meter.CreateCounter<long>(
            "agent.contentsafety.evaluations",
            "screening",
            "Content Safety screenings by stage (turn | document) and outcome (clean | flagged | failopen).");
        var root = options.ApimGatewayEndpoint!.TrimEnd('/');
        _analyzeUri = new Uri($"{root}/contentsafety/text:analyze?api-version={ApiVersion}");
        _shieldUri = new Uri($"{root}/contentsafety/text:shieldPrompt?api-version={ApiVersion}");
    }

    /// <summary>A single harm category and the severity (0-7) Content Safety scored for it.</summary>
    public sealed record CategorySeverity(string Category, int Severity);

    /// <summary>
    /// The screening result for one turn. <see cref="Flagged"/> is true when a category reached the threshold or an attack
    /// was detected; <see cref="Evaluated"/> is false when a sub-call failed open, which makes "clean" and "never screened"
    /// distinguishable — without it a Content Safety outage silently disables blocking.
    /// </summary>
    public sealed record Verdict(
        bool Flagged,
        IReadOnlyList<CategorySeverity> Categories,
        bool PromptAttackDetected,
        bool Evaluated);

    /// <summary>Screens <paramref name="text"/> and returns the verdict. Never throws (fails open).</summary>
    public async Task<Verdict> EvaluateAsync(string text, CancellationToken ct)
    {
        if (text.Length > MaxTextChars)
        {
            text = text[..MaxTextChars];
        }

        // Run both checks concurrently (each fails open internally, so neither can fault the pair).
        var analyzeTask = AnalyzeAsync(text, ct);
        var shieldTask = _options.ContentSafetyShieldPrompt
            ? ShieldPromptAsync(text, ct)
            : Task.FromResult((Evaluated: true, Attack: false));
        var analysis = await analyzeTask;
        var shield = await shieldTask;

        var flagged = shield.Attack || analysis.Categories.Any(c => c.Severity >= _options.ContentSafetyThreshold);
        // Either sub-call falling open leaves the turn only partly screened, so the whole verdict counts as unevaluated.
        var evaluated = analysis.Evaluated && shield.Evaluated;

        RecordOutcome(TurnStage, evaluated ? (flagged ? "flagged" : "clean") : "failopen");
        return new Verdict(flagged, analysis.Categories, shield.Attack, evaluated);
    }

    /// <summary>
    /// The screening result for one ingested document. <see cref="Evaluated"/> has the same meaning as on
    /// <see cref="Verdict"/>: false means at least one batch failed open, so "no attack" is not a clean bill of health.
    /// </summary>
    public sealed record DocumentVerdict(bool AttackDetected, bool Evaluated);

    /// <summary>
    /// Screens extracted document text through Prompt Shields' <c>documents</c> channel — the indirect-attack detector,
    /// which catches instructions embedded in an uploaded file that the per-turn user-prompt check never looks at.
    /// Batched to <see cref="DocumentBatchSize"/> and short-circuits on the first detection. Never throws (fails open).
    /// </summary>
    public async Task<DocumentVerdict> EvaluateDocumentsAsync(IReadOnlyList<string> documents, CancellationToken ct)
    {
        var evaluated = true;

        for (var offset = 0; offset < documents.Count; offset += DocumentBatchSize)
        {
            var batch = documents
                .Skip(offset)
                .Take(DocumentBatchSize)
                .Select(d => d.Length > MaxTextChars ? d[..MaxTextChars] : d)
                .ToArray();

            var (batchEvaluated, attack) = await ShieldDocumentsAsync(batch, ct);
            evaluated &= batchEvaluated;

            // One hostile passage condemns the whole file, so stop screening the rest.
            if (attack)
            {
                RecordOutcome(DocumentStage, "flagged");
                return new DocumentVerdict(true, true);
            }
        }

        RecordOutcome(DocumentStage, evaluated ? "clean" : "failopen");
        return new DocumentVerdict(false, evaluated);
    }

    // Telemetry must never fail a served turn (mirrors TokenUsageTelemetry).
    private void RecordOutcome(string stage, string outcome)
    {
        try
        {
            _evaluations.Add(
                1,
                new KeyValuePair<string, object?>("stage", stage),
                new KeyValuePair<string, object?>("outcome", outcome));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Content Safety telemetry failed; the pre-check itself completed normally.");
        }
    }

    // text:analyze — harm-category severities (Hate, SelfHarm, Sexual, Violence) on the 0-7 scale.
    private async Task<(bool Evaluated, IReadOnlyList<CategorySeverity> Categories)> AnalyzeAsync(string text, CancellationToken ct)
    {
        try
        {
            using var doc = await PostAsync(_analyzeUri, new { text, outputType = "EightSeverityLevels" }, ct);

            var results = new List<CategorySeverity>();
            if (doc.RootElement.TryGetProperty("categoriesAnalysis", out var analysis))
            {
                foreach (var entry in analysis.EnumerateArray())
                {
                    var category = entry.TryGetProperty("category", out var c) ? c.GetString() : null;
                    var severity = entry.TryGetProperty("severity", out var s) ? s.GetInt32() : 0;
                    if (!string.IsNullOrEmpty(category))
                    {
                        results.Add(new CategorySeverity(category, severity));
                    }
                }
            }
            return (true, results);
        }
        catch (Exception ex)
        {
            // Fail open: a content-safety outage must not take down chat (mirrors SearchAdapter).
            _logger.LogWarning(ex, "Content Safety text:analyze failed; allowing request (fail-open).");
            return (false, Array.Empty<CategorySeverity>());
        }
    }

    // text:shieldPrompt — Prompt Shields user-prompt attack (jailbreak / prompt-injection) detection.
    private async Task<(bool Evaluated, bool Attack)> ShieldPromptAsync(string text, CancellationToken ct)
    {
        try
        {
            using var doc = await PostAsync(_shieldUri, new { userPrompt = text, documents = Array.Empty<string>() }, ct);

            return (true, doc.RootElement.TryGetProperty("userPromptAnalysis", out var analysis)
                && analysis.TryGetProperty("attackDetected", out var detected)
                && detected.GetBoolean());
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Content Safety text:shieldPrompt failed; treating as no attack (fail-open).");
            return (false, false);
        }
    }

    // text:shieldPrompt with an empty userPrompt: documentsAnalysis carries one attackDetected verdict per document.
    private async Task<(bool Evaluated, bool Attack)> ShieldDocumentsAsync(string[] documents, CancellationToken ct)
    {
        try
        {
            using var doc = await PostAsync(_shieldUri, new { userPrompt = "", documents }, ct);

            return (true, doc.RootElement.TryGetProperty("documentsAnalysis", out var analysis)
                && analysis.EnumerateArray().Any(
                    e => e.TryGetProperty("attackDetected", out var detected) && detected.GetBoolean()));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Content Safety document screening failed; treating as no attack (fail-open).");
            return (false, false);
        }
    }

    // Posts one Content Safety operation through the gateway and returns the parsed response body.
    // Throws on transport/status failure; each caller wraps the whole call-and-parse in its own fail-open handler.
    private async Task<JsonDocument> PostAsync<TPayload>(Uri uri, TPayload payload, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, uri);
        request.Headers.Add("Ocp-Apim-Subscription-Key", _options.ApimSubscriptionKey);
        request.Content = JsonContent.Create(payload);

        using var response = await _http.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();

        return JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
    }

    public void Dispose()
    {
        _meter.Dispose();
        _http.Dispose();
    }
}
