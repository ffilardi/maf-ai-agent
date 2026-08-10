using System.Text.Json;
using AgentBackend.Configuration;

namespace AgentBackend.Services;

/// <summary>
/// Per-turn Azure AI Content Safety pre-check on the user's message, via the APIM gateway (/contentsafety, Ocp-Apim-Subscription-Key header).
/// Calls <c>text:analyze</c> (harm-category severities) and, when enabled, <c>text:shieldPrompt</c> (jailbreak detection).
/// Fails <b>open</b> on any error (logs a warning, reports "nothing detected") so a Content Safety outage never takes chat down.
/// </summary>
public sealed class ContentSafetyService
{
    // Data-plane api-version for text:analyze + text:shieldPrompt.
    private const string ApiVersion = "2024-09-01";

    // Content Safety caps a single text input at 10K chars; truncate defensively so an oversized prompt is still screened.
    private const int MaxTextChars = 10_000;

    private readonly AgentOptions _options;
    private readonly ILogger<ContentSafetyService> _logger;
    // One long-lived client routing through the APIM gateway.
    private readonly HttpClient _http = new();
    private readonly Uri _analyzeUri;
    private readonly Uri _shieldUri;

    public ContentSafetyService(AgentOptions options, ILogger<ContentSafetyService> logger)
    {
        _options = options;
        _logger = logger;
        var root = options.ApimGatewayEndpoint!.TrimEnd('/');
        _analyzeUri = new Uri($"{root}/contentsafety/text:analyze?api-version={ApiVersion}");
        _shieldUri = new Uri($"{root}/contentsafety/text:shieldPrompt?api-version={ApiVersion}");
    }

    /// <summary>A single harm category and the severity (0-7) Content Safety scored for it.</summary>
    public sealed record CategorySeverity(string Category, int Severity);

    /// <summary>The screening result for one turn; <see cref="Flagged"/> is true when a category reached the threshold or an attack was detected.</summary>
    public sealed record Verdict(
        bool Flagged,
        IReadOnlyList<CategorySeverity> Categories,
        bool PromptAttackDetected);

    /// <summary>Screens <paramref name="text"/> and returns the verdict. Never throws (fails open).</summary>
    public async Task<Verdict> EvaluateAsync(string text, CancellationToken ct)
    {
        if (text.Length > MaxTextChars)
        {
            text = text[..MaxTextChars];
        }

        // Run both checks concurrently (each fails open internally, so neither can fault the pair).
        var analyzeTask = AnalyzeAsync(text, ct);
        var shieldTask = _options.ContentSafetyShieldPrompt ? ShieldPromptAsync(text, ct) : Task.FromResult(false);
        var categories = await analyzeTask;
        var attack = await shieldTask;

        var flagged = attack || categories.Any(c => c.Severity >= _options.ContentSafetyThreshold);
        return new Verdict(flagged, categories, attack);
    }

    // text:analyze — harm-category severities (Hate, SelfHarm, Sexual, Violence) on the 0-7 scale.
    private async Task<IReadOnlyList<CategorySeverity>> AnalyzeAsync(string text, CancellationToken ct)
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
            return results;
        }
        catch (Exception ex)
        {
            // Fail open: a content-safety outage must not take down chat (mirrors SearchAdapter).
            _logger.LogWarning(ex, "Content Safety text:analyze failed; allowing request (fail-open).");
            return Array.Empty<CategorySeverity>();
        }
    }

    // text:shieldPrompt — Prompt Shields user-prompt attack (jailbreak / prompt-injection) detection.
    private async Task<bool> ShieldPromptAsync(string text, CancellationToken ct)
    {
        try
        {
            using var doc = await PostAsync(_shieldUri, new { userPrompt = text, documents = Array.Empty<string>() }, ct);

            return doc.RootElement.TryGetProperty("userPromptAnalysis", out var analysis)
                && analysis.TryGetProperty("attackDetected", out var detected)
                && detected.GetBoolean();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Content Safety text:shieldPrompt failed; treating as no attack (fail-open).");
            return false;
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
}
