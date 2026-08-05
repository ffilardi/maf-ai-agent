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
        // Index route — reports the runtime.
        app.MapGet("/", () =>
        {
            var version = RuntimeInformation.FrameworkDescription; // e.g. ".NET 10.0.10"
            return Results.Text($"Running on {version}");
        });

        // Health check endpoint.
        app.MapGet("/ping", () => Results.Json(new { status = "healthy" }));

        // Non-secret client config: selectable models, default model, and the effective default system prompt.
        app.MapGet("/config", (AgentOptions options) => Results.Json(new ConfigResponse(
            Models: options.Models,
            DefaultModel: options.DefaultModel,
            DefaultSystemPrompt: options.AgentInstructions ?? AgentFactory.DefaultAgentInstructions)));
    }
}
