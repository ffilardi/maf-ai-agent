using System.Runtime.InteropServices;
using AgentBackend.Configuration;
using AgentBackend.Models;
using AgentBackend.Services;

namespace AgentBackend.Endpoints;

/// <summary>Meta endpoints: index route (reports the runtime), health check, and the non-secret runtime config for the SPA (GET /config).</summary>
public static class MetaEndpoints
{
    public static void MapMetaEndpoints(this IEndpointRouteBuilder app)
    {
        // Index route — reports the runtime (e.g. ".NET 10.0.10").
        app.MapGet("/", () => Results.Text($"Running on {RuntimeInformation.FrameworkDescription}"));

        // Health check endpoint.
        app.MapGet("/ping", () => Results.Json(new { status = "healthy" }));

        // Non-secret client config: selectable models, default model, and — unless EXPOSE_DEFAULT_PROMPT is off — the
        // effective default system prompt. Withheld it reads as "", which the SPA renders as a placeholder.
        app.MapGet("/config", (AgentOptions options) => Results.Json(new ConfigResponse(
            Models: options.Models,
            DefaultModel: options.DefaultModel,
            DefaultSystemPrompt: options.ExposeDefaultPrompt
                ? options.AgentInstructions ?? AgentFactory.DefaultAgentInstructions
                : string.Empty)));
    }
}
