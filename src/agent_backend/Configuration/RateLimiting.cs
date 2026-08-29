using System.Globalization;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Mvc;

namespace AgentBackend.Configuration;

/// <summary>
/// Backend request limits — the per-caller half of the unbounded-consumption guardrails. APIM's own policies key on
/// <c>context.Subscription.Key</c>, the one shared backend key, so every caller lands in the same bucket there.
/// <para>
/// Partitions on the conversation id, which is client-chosen (no auth) and so trivially rotated — hence the global
/// backstop, the only limit an anonymous caller cannot re-key. Client IP is deliberately not used: App Service
/// terminates TLS at the front end, so the real address is only in a spoofable <c>X-Forwarded-For</c>.
/// </para>
/// </summary>
public static class RateLimiting
{
    /// <summary>Policy on the two chat POSTs — one agent turn (and its token spend) per permit.</summary>
    public const string ChatPolicy = "chat";

    /// <summary>Policy on <c>POST /files</c> — one Document Intelligence + embedding pipeline per permit.</summary>
    public const string UploadPolicy = "upload";

    /// <summary>Header the SPA mirrors its conversation id into: a partitioner is synchronous and cannot read the POST body.</summary>
    public const string SessionHeader = "X-Session-Id";

    // "20 turns/min with a burst of 5": a 5-token bucket refilled by 5 every 15s.
    private const int ChatBurst = 5;
    private static readonly TimeSpan ChatReplenishment = TimeSpan.FromSeconds(15);

    // 10 uploads per 5 minutes.
    private const int UploadPermits = 10;
    private static readonly TimeSpan UploadWindow = TimeSpan.FromMinutes(5);

    // Global backstop: concurrency protects the instance, the paired request rate bounds sequential abuse.
    private const int GlobalConcurrency = 100;
    private const int GlobalConcurrencyQueue = 50;
    private const int GlobalRequestsPerMinute = 600;

    // Callers that send no conversation id share one bucket (curl, probes). Deliberately strict.
    private const string AnonymousPartition = "anonymous";

    // Bound the partition key so a hostile header can't inflate the limiter's per-partition state.
    private const int MaxPartitionKeyLength = 128;

    // Health and banner routes are exempt: a global 429 on /ping would mark the App Service unhealthy.
    private static readonly HashSet<string> ExemptPaths =
        new(StringComparer.OrdinalIgnoreCase) { "/", "/ping" };

    /// <summary>Registers the chat/upload policies and the global backstop; endpoints opt in with <c>RequireRateLimiting</c>.</summary>
    public static IServiceCollection AddAgentRateLimiter(this IServiceCollection services) =>
        services.AddRateLimiter(limiter =>
        {
            limiter.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
            limiter.OnRejected = OnRejectedAsync;

            // Token bucket: smooths a sustained rate while still allowing a short burst.
            limiter.AddPolicy(ChatPolicy, context => RateLimitPartition.GetTokenBucketLimiter(
                PartitionKey(context),
                _ => new TokenBucketRateLimiterOptions
                {
                    TokenLimit = ChatBurst,
                    TokensPerPeriod = ChatBurst,
                    ReplenishmentPeriod = ChatReplenishment,
                    QueueLimit = 0,
                    AutoReplenishment = true,
                }));

            // Fixed window: uploads are chunky and infrequent, so a hard count per window is the clearer contract.
            limiter.AddPolicy(UploadPolicy, context => RateLimitPartition.GetFixedWindowLimiter(
                PartitionKey(context),
                _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = UploadPermits,
                    Window = UploadWindow,
                    QueueLimit = 0,
                }));

            // Chained so a request must satisfy both; applies to every endpoint, policy or not.
            limiter.GlobalLimiter = PartitionedRateLimiter.CreateChained(
                PartitionedRateLimiter.Create<HttpContext, string>(context => IsExempt(context)
                    ? RateLimitPartition.GetNoLimiter(AnonymousPartition)
                    : RateLimitPartition.GetConcurrencyLimiter("global", _ => new ConcurrencyLimiterOptions
                    {
                        PermitLimit = GlobalConcurrency,
                        QueueLimit = GlobalConcurrencyQueue,
                        QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                    })),
                PartitionedRateLimiter.Create<HttpContext, string>(context => IsExempt(context)
                    ? RateLimitPartition.GetNoLimiter(AnonymousPartition)
                    : RateLimitPartition.GetFixedWindowLimiter("global", _ => new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = GlobalRequestsPerMinute,
                        Window = TimeSpan.FromMinutes(1),
                        QueueLimit = 0,
                    })));
        });

    // Conversation id from the cheapest place it appears: route (sessions trio) → query (files) → header (chat POSTs).
    private static string PartitionKey(HttpContext context)
    {
        if (context.GetRouteValue("sessionId") is string route && !string.IsNullOrWhiteSpace(route))
        {
            return Truncate(route);
        }
        if (context.Request.Query.TryGetValue("sessionId", out var query) && !string.IsNullOrWhiteSpace(query))
        {
            return Truncate(query.ToString());
        }

        var header = context.Request.Headers[SessionHeader].ToString();
        return string.IsNullOrWhiteSpace(header) ? AnonymousPartition : Truncate(header);
    }

    private static string Truncate(string key) =>
        key.Length > MaxPartitionKeyLength ? key[..MaxPartitionKeyLength] : key;

    private static bool IsExempt(HttpContext context) =>
        context.Request.Path.HasValue && ExemptPaths.Contains(context.Request.Path.Value);

    // 429 as RFC 7807, matching every other failure the SPA parses.
    private static ValueTask OnRejectedAsync(OnRejectedContext context, CancellationToken cancellationToken)
    {
        var response = context.HttpContext.Response;

        // Replenishing limiters know when the next permit frees up; the concurrency one doesn't, hence TryGetMetadata.
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            response.Headers.RetryAfter =
                ((int)Math.Ceiling(retryAfter.TotalSeconds)).ToString(CultureInfo.InvariantCulture);
        }

        response.StatusCode = StatusCodes.Status429TooManyRequests;
        return new ValueTask(response.WriteAsJsonAsync(
            new ProblemDetails
            {
                Status = StatusCodes.Status429TooManyRequests,
                Title = "Too Many Requests",
                Detail = "Too many requests — please wait a moment and try again.",
            },
            options: null,
            // Match the content type Results.Problem uses everywhere else in the API.
            contentType: "application/problem+json",
            cancellationToken));
    }
}
