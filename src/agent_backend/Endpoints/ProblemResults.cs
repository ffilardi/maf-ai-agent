using System.Diagnostics;
using AgentBackend.Services;

namespace AgentBackend.Endpoints;

/// <summary>
/// The single boundary where a failed agent/ingestion call becomes an HTTP response. Provider and gateway messages
/// carry backend URLs, deployment names, and raw error payloads (CWE-209), so the exception goes to the log and the
/// client gets fixed text plus a correlation id — the same id App Insights already indexes the request under.
/// </summary>
internal static class ProblemResults
{
    /// <summary>Logs <paramref name="ex"/> in full and returns an RFC 7807 problem carrying only client-safe text.</summary>
    public static IResult FromAgentFailure(AgentInvocationException ex, HttpContext http)
    {
        // Messages we authored ourselves (the Content Safety block notice) are shown verbatim — they're the point.
        if (ex.ClientSafe)
        {
            return Results.Problem(statusCode: ex.StatusCode, detail: ex.Message);
        }

        var reference = CorrelationId(http);
        http.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger(typeof(ProblemResults))
            .LogError(ex, "{Method} {Path} failed with {StatusCode} (reference={Reference}).",
                http.Request.Method, http.Request.Path.Value, ex.StatusCode, reference);

        return Results.Problem(
            statusCode: ex.StatusCode, detail: AgentInvocationException.SafeMessage(ex.StatusCode, reference));
    }

    /// <summary>The id support quotes back: the distributed-trace id when tracing is on, else Kestrel's request id.</summary>
    public static string CorrelationId(HttpContext http) => Activity.Current?.Id ?? http.TraceIdentifier;
}
