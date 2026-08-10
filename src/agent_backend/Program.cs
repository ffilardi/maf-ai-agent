using System.Diagnostics;
using AgentBackend.Configuration;
using AgentBackend.Endpoints;
using AgentBackend.Services;
using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.Agents.AI;
using Microsoft.Azure.Cosmos;

var builder = WebApplication.CreateBuilder(args);

// Listen-URL bind order: ASPNETCORE_URLS → PORT → :8000.
var listenUrls = Environment.GetEnvironmentVariable("ASPNETCORE_URLS");
if (string.IsNullOrWhiteSpace(listenUrls))
{
    var port = Environment.GetEnvironmentVariable("PORT");
    listenUrls = string.IsNullOrWhiteSpace(port) ? "http://0.0.0.0:8000" : $"http://0.0.0.0:{port}";
}
builder.WebHost.UseUrls(listenUrls);

// Backend configuration, read from environment variables / appsettings.
var agentOptions = AgentOptions.FromConfiguration(builder.Configuration);
builder.Services.AddSingleton(agentOptions);

// App Insights via the Azure Monitor OpenTelemetry distro; wired only when APPLICATIONINSIGHTS_CONNECTION_STRING is present.
// AddSource/AddMeter pull in MAF's GenAI agent spans (AgentFactory.TelemetrySourceName) plus the FinOps token counters
// (TokenUsageTelemetry.MeterName), which land in customMetrics and drive the "Token & Cost Insights" workbook.
if (!string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
{
    builder.Services.AddOpenTelemetry()
        .UseAzureMonitor()
        .WithTracing(tracing => tracing.AddSource(AgentFactory.TelemetrySourceName))
        .WithMetrics(metrics => metrics
            .AddMeter(AgentFactory.TelemetrySourceName)
            .AddMeter(TokenUsageTelemetry.MeterName));
}

// CORS for the SPA (browser → backend directly); origins from ALLOWED_ORIGINS, empty list = no cross-origin access.
const string FrontendCorsPolicy = "frontend";
builder.Services.AddCors(options => options.AddPolicy(FrontendCorsPolicy, policy =>
{
    if (agentOptions.AllowedOrigins.Length > 0)
    {
        policy.WithOrigins(agentOptions.AllowedOrigins).AllowAnyHeader().WithMethods("GET", "POST", "DELETE");
    }
}));

// Shared Cosmos client for the chat-history provider; registered only when configured (else /chat returns 503).
if (agentOptions.HasCosmosConfig)
{
    builder.Services.AddSingleton(_ => new CosmosClient(agentOptions.CosmosEndpoint, agentOptions.CosmosKey));
    // Read/list/delete access backing the sessions sidebar; shares the CosmosClient singleton.
    builder.Services.AddSingleton<ConversationStore>();
}

// Shared embedding client (query-time RAG + ingestion), routed through the APIM gateway.
if (agentOptions.HasApimConfig)
{
    builder.Services.AddSingleton<EmbeddingService>();
}

// Build the shared agent once at startup; resolved lazily on first /chat (missing APIM config ⇒ 503, app still starts).
builder.Services.AddSingleton<AIAgent>(sp => AgentFactory.Create(
    agentOptions,
    agentOptions.HasCosmosConfig ? sp.GetRequiredService<CosmosClient>() : null,
    sp.GetRequiredService<ILoggerFactory>(),
    sp.GetService<EmbeddingService>()));

// Azure AI Content Safety pre-check; registered only when enabled (CONTENT_SAFETY_MODE=log|block), resolved optionally in ChatService.
if (agentOptions.HasContentSafetyConfig)
{
    builder.Services.AddSingleton<ContentSafetyService>();
}

// Per-turn token/cost telemetry; registered unconditionally (the meter is inert without the Azure Monitor exporter).
builder.Services.AddSingleton<TokenUsageTelemetry>();

// File-attachment ingestion pipeline; registered only when fully configured (else POST /files returns 503).
if (agentOptions.HasIngestionConfig)
{
    // Shared managed-identity credential for blob/queue/table (no account key); resolves a developer login locally.
    builder.Services.AddSingleton<TokenCredential>(_ => new DefaultAzureCredential());
    builder.Services.AddSingleton<StorageService>();
    builder.Services.AddSingleton<QueueService>();
    builder.Services.AddSingleton<IngestionStatusStore>();
    builder.Services.AddSingleton<DocumentIntelligenceService>();
    builder.Services.AddSingleton<SearchIndexer>();
    builder.Services.AddSingleton<IngestionService>();
    // Create the container/queues/table/index once at startup, before the worker polls (StartAsync runs in registration order).
    builder.Services.AddHostedService<IngestionInitializer>();
    // Consumes the queue and runs the pipeline off the request path.
    builder.Services.AddHostedService<QueueIngestionWorker>();
}

// The main chat endpoint; resolves the agent, telemetry, and optional content-safety service.
builder.Services.AddSingleton<ChatService>(sp => new ChatService(
    sp.GetRequiredService<AIAgent>(),
    agentOptions,
    sp.GetService<ContentSafetyService>(),
    sp.GetService<IngestionStatusStore>(),
    sp.GetRequiredService<TokenUsageTelemetry>(),
    sp.GetRequiredService<ILogger<ChatService>>()));

var app = builder.Build();

// Emit the X-Process-Time header; queued via OnStarting so it is written before the body flushes.
app.Use(async (context, next) =>
{
    var stopwatch = Stopwatch.StartNew();
    context.Response.OnStarting(() =>
    {
        stopwatch.Stop();
        context.Response.Headers["X-Process-Time"] = $"{stopwatch.Elapsed.TotalSeconds:0.0000} sec";
        return Task.CompletedTask;
    });
    await next();
});

app.UseCors(FrontendCorsPolicy);

// Route definitions live in Endpoints/*.cs; Program.cs stays a composition root.
app.MapMetaEndpoints();
app.MapChatEndpoints();
app.MapFilesEndpoints();

app.Run();
