namespace AgentBackend.Configuration;

/// <summary>Strongly-typed backend configuration read from environment variables, explicitly by key (env names use literal single underscores).</summary>
public sealed class AgentOptions
{
    // APIM "AI Gateway" — all model traffic routes through here.
    public string? ApimGatewayEndpoint { get; init; }
    public string? ApimSubscriptionKey { get; init; }
    // Selectable chat model deployments (AI_MODEL_DEPLOYMENTS, comma-separated); first entry is the default, backend only honours a per-request model listed here.
    public string[] AiModelDeployments { get; init; } = Array.Empty<string>();

    // Optional system-prompt override (AGENT_INSTRUCTIONS); unset falls back to AgentFactory.DefaultAgentInstructions.
    public string? AgentInstructions { get; init; }

    // System-prompt exposure/override switches. Both default to the demo behaviour; Azure turns exposure off in app.bicep.
    //   EXPOSE_DEFAULT_PROMPT: advertise the effective base prompt on GET /config (handing a caller the tool contract).
    //   ALLOW_SYSTEM_PROMPT_OVERRIDE: honour a per-request systemPrompt (replacing the base prompt wholesale).
    public bool ExposeDefaultPrompt { get; init; } = true;
    public bool AllowSystemPromptOverride { get; init; } = true;

    // Cosmos DB conversation store.
    public string? CosmosEndpoint { get; init; }
    public string? CosmosKey { get; init; }
    public string CosmosDb { get; init; } = "agent_db";
    public string CosmosContainer { get; init; } = "conversations";

    // Conversation-history bounds. MaxHistoryMessages caps messages read from Cosmos per turn.
    // MaxContextWindowTokens − MaxOutputTokens is the input token budget for the in-context compaction pipeline (AgentFactory).
    public int MaxHistoryMessages { get; init; } = 100;
    public int MaxContextWindowTokens { get; init; } = 128_000;
    public int MaxOutputTokens { get; init; } = 16_384;

    // Per-turn input cap; the default matches ContentSafetyService's 10K screening cap, so nothing unscreened reaches the model.
    public int MaxInputChars { get; init; } = 10_000;
    // Ceiling on tool calls per turn; the RAG prompt invites repeated searching, and each call costs an embedding + a search.
    public int MaxToolCallsPerTurn { get; init; } = 8;

    // Cosmos transcript retention: 0 (default) = never expire (MessageTtlSeconds = -1); a positive value sets a TTL in days.
    public int MaxHistoryTtlDays { get; init; } = 0;

    // Azure AI Search RAG, reached through the APIM gateway. AiSearchEndpoint = APIM API base; AiSearchSubscriptionKey = api-key ingress (APIM auths to search with its MI).
    public string? AiSearchEndpoint { get; init; }
    public string? AiSearchSubscriptionKey { get; init; }
    public string? AiSearchIndex { get; init; }

    // File-attachment ingestion (upload → Document Intelligence → chunk → embed → push to AI Search).
    // Blobs + async queue + status table share the account, accessed with the App Service's managed identity (no key); endpoints derived from the account name.
    public string? StorageAccountName { get; init; }
    // Local-dev fallback only; in Azure the STORAGE_CONTAINER app setting overrides it. Keep in sync with the bicep param default.
    public const string DefaultStorageContainer = "attachments";
    public string StorageContainer { get; init; } = DefaultStorageContainer;
    // APIM gateway root fronting Document Intelligence (the DI SDK appends "/documentintelligence/..."). Empty ⇒ ingestion disabled.
    public string? DocIntelEndpoint { get; init; }
    // Embedding deployment used to vectorize chunks + the query (via APIM /openai).
    // Local-dev fallback only; in Azure the AI_EMBEDDING_DEPLOYMENT app setting overrides it. Keep in sync with the Foundry deployment name.
    public const string DefaultEmbeddingDeployment = "text-embedding-3-large";
    public string AiEmbeddingDeployment { get; init; } = DefaultEmbeddingDeployment;
    // Embed chunks in batches (specified as chunk count) so one file can't blow the deployment's TPM in a single request.
    public int EmbeddingBatchSize { get; init; } = 16;
    public int EmbeddingMaxRetries { get; init; } = 5;
    // Server-side upload size cap (MB).
    public int MaxUploadMb { get; init; } = 10;
    // Attachments per conversation: MaxUploadMb bounds one file, this bounds how many.
    public int MaxFilesPerSession { get; init; } = 20;

    // Async ingestion (POST /files enqueues; a BackgroundService consumes). Poison queue is "{IngestionQueue}-poison".
    public string IngestionQueue { get; init; } = "ingestion";
    public string IngestionStatusTable { get; init; } = "ingestionstatus";

    // Azure AI Content Safety per-turn pre-check on the user message, via the APIM gateway (/contentsafety, Ocp-Apim-Subscription-Key ingress).
    //   CONTENT_SAFETY_MODE: off (default, no calls) | log (analyze + log, never block) | block (reject flagged).
    //   CONTENT_SAFETY_THRESHOLD: severity (0-7, EightSeverityLevels) at/above which a harm category is flagged.
    //   CONTENT_SAFETY_SHIELD_PROMPT: also run Prompt Shields (jailbreak / prompt-injection detection).
    //   CONTENT_SAFETY_FAIL_CLOSED: in block mode, also reject turns Content Safety could not evaluate (default false, availability-first).
    public string ContentSafetyMode { get; init; } = "off";
    public int ContentSafetyThreshold { get; init; } = 4;
    public bool ContentSafetyShieldPrompt { get; init; } = true;
    public bool ContentSafetyFailClosed { get; init; } = false;

    // CORS allow-list for the SPA (comma-separated origins). Empty = no cross-origin access; use http://localhost:5173 for local Vite dev.
    public string[] AllowedOrigins { get; init; } = Array.Empty<string>();

    private IReadOnlyList<string>? _models;

    /// <summary>Selectable chat model deployments, de-duplicated case-insensitively in configured order (computed once; read per request).</summary>
    public IReadOnlyList<string> Models => _models ??= AiModelDeployments
        .Where(m => !string.IsNullOrWhiteSpace(m))
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToArray();

    /// <summary>The default chat model baked into the agent: the first configured deployment.</summary>
    public string? DefaultModel => Models.Count > 0 ? Models[0] : null;

    /// <summary>True when the three APIM settings required to build the agent are present.</summary>
    public bool HasApimConfig =>
        !string.IsNullOrWhiteSpace(ApimGatewayEndpoint)
        && !string.IsNullOrWhiteSpace(ApimSubscriptionKey)
        && DefaultModel is not null;

    /// <summary>True when both Cosmos settings required to attach the store are present.</summary>
    public bool HasCosmosConfig =>
        !string.IsNullOrWhiteSpace(CosmosEndpoint) && !string.IsNullOrWhiteSpace(CosmosKey);

    /// <summary>True when all three Azure AI Search settings are present; gates the RAG search tool.</summary>
    public bool HasAiSearchConfig =>
        !string.IsNullOrWhiteSpace(AiSearchEndpoint)
        && !string.IsNullOrWhiteSpace(AiSearchSubscriptionKey)
        && !string.IsNullOrWhiteSpace(AiSearchIndex);

    /// <summary>True when the ingestion pipeline's requirements are all present (APIM, Storage, Document Intelligence, AI Search); gates <c>POST /files</c>.</summary>
    public bool HasIngestionConfig =>
        HasApimConfig
        && HasAiSearchConfig
        && !string.IsNullOrWhiteSpace(StorageAccountName)
        && !string.IsNullOrWhiteSpace(DocIntelEndpoint);

    /// <summary>True when Content Safety is enabled (mode log or block) and APIM is configured; gates the per-turn pre-check.</summary>
    public bool HasContentSafetyConfig =>
        HasApimConfig && ContentSafetyMode is "log" or "block";

    /// <summary>True when a flagged request should be rejected (block mode) rather than only logged (log mode).</summary>
    public bool IsContentSafetyBlocking => ContentSafetyMode == "block";

    /// <summary>True when a turn Content Safety could not evaluate should be rejected too, rather than allowed through.</summary>
    public bool IsContentSafetyFailClosed => IsContentSafetyBlocking && ContentSafetyFailClosed;

    /// <summary>Blob/Queue/Table service endpoints for the configured storage account (public-cloud suffix).</summary>
    public Uri BlobEndpoint => new($"https://{StorageAccountName}.blob.core.windows.net");
    public Uri QueueEndpoint => new($"https://{StorageAccountName}.queue.core.windows.net");
    public Uri TableEndpoint => new($"https://{StorageAccountName}.table.core.windows.net");

    /// <summary>Read options from configuration (environment variables + appsettings).</summary>
    public static AgentOptions FromConfiguration(IConfiguration config) => new()
    {
        ApimGatewayEndpoint = config["APIM_GATEWAY_ENDPOINT"],
        ApimSubscriptionKey = config["APIM_SUBSCRIPTION_KEY"],
        AiModelDeployments = (config["AI_MODEL_DEPLOYMENTS"] ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
        AgentInstructions = config["AGENT_INSTRUCTIONS"],
        ExposeDefaultPrompt = !string.Equals(config["EXPOSE_DEFAULT_PROMPT"], "false", StringComparison.OrdinalIgnoreCase),
        AllowSystemPromptOverride = !string.Equals(config["ALLOW_SYSTEM_PROMPT_OVERRIDE"], "false", StringComparison.OrdinalIgnoreCase),
        CosmosEndpoint = config["COSMOS_ENDPOINT"],
        CosmosKey = config["COSMOS_KEY"],
        CosmosDb = config["COSMOS_DB"] ?? "agent_db",
        CosmosContainer = config["COSMOS_CONTAINER"] ?? "conversations",
        MaxHistoryMessages = int.TryParse(config["MAX_HISTORY_MESSAGES"], out var mhm) && mhm > 0 ? mhm : 100,
        MaxContextWindowTokens = int.TryParse(config["MAX_CONTEXT_WINDOW_TOKENS"], out var mcw) && mcw > 0 ? mcw : 128_000,
        MaxOutputTokens = int.TryParse(config["MAX_OUTPUT_TOKENS"], out var mot) && mot > 0 ? mot : 16_384,
        MaxInputChars = int.TryParse(config["MAX_INPUT_CHARS"], out var mic) && mic > 0 ? mic : 10_000,
        MaxToolCallsPerTurn = int.TryParse(config["MAX_TOOL_CALLS_PER_TURN"], out var mtc) && mtc > 0 ? mtc : 8,
        MaxHistoryTtlDays = int.TryParse(config["MAX_HISTORY_TTL_DAYS"], out var mht) && mht > 0 ? mht : 0,
        AiSearchEndpoint = config["AI_SEARCH_ENDPOINT"],
        AiSearchSubscriptionKey = config["AI_SEARCH_SUBSCRIPTION_KEY"],
        AiSearchIndex = config["AI_SEARCH_INDEX"],
        StorageAccountName = config["STORAGE_ACCOUNT_NAME"],
        StorageContainer = config["STORAGE_CONTAINER"] ?? DefaultStorageContainer,
        DocIntelEndpoint = config["DOCINTEL_ENDPOINT"],
        AiEmbeddingDeployment = config["AI_EMBEDDING_DEPLOYMENT"] ?? DefaultEmbeddingDeployment,
        EmbeddingBatchSize = int.TryParse(config["AI_EMBEDDING_BATCH_SIZE"], out var ebs) && ebs > 0 ? ebs : 16,
        EmbeddingMaxRetries = int.TryParse(config["AI_EMBEDDING_MAX_RETRIES"], out var emr) && emr >= 0 ? emr : 5,
        MaxUploadMb = int.TryParse(config["MAX_UPLOAD_MB"], out var mb) && mb > 0 ? mb : 10,
        MaxFilesPerSession = int.TryParse(config["MAX_FILES_PER_SESSION"], out var mfs) && mfs > 0 ? mfs : 20,
        IngestionQueue = config["INGESTION_QUEUE"] ?? "ingestion",
        IngestionStatusTable = config["INGESTION_STATUS_TABLE"] ?? "ingestionstatus",
        ContentSafetyMode = (config["CONTENT_SAFETY_MODE"] ?? "off").Trim().ToLowerInvariant(),
        ContentSafetyThreshold = int.TryParse(config["CONTENT_SAFETY_THRESHOLD"], out var cst) && cst is >= 0 and <= 7 ? cst : 4,
        ContentSafetyShieldPrompt = !string.Equals(config["CONTENT_SAFETY_SHIELD_PROMPT"], "false", StringComparison.OrdinalIgnoreCase),
        ContentSafetyFailClosed = string.Equals(config["CONTENT_SAFETY_FAIL_CLOSED"], "true", StringComparison.OrdinalIgnoreCase),
        AllowedOrigins = (config["ALLOWED_ORIGINS"] ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
    };
}
