using System.Text.Json.Serialization;

namespace AgentBackend.Models;

// Wire contract: top-level fields camelCase, TokenUsage fields snake_case; every name pinned with [JsonPropertyName].

/// <summary>Request body for the /chat endpoint.</summary>
public sealed record ChatRequest(
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("chatInput")] string ChatInput,
    [property: JsonPropertyName("userName")] string? UserName = null,
    // Optional per-request reasoning effort (minimal|low|medium|high); null/unknown ⇒ agent default.
    [property: JsonPropertyName("reasoningEffort")] string? ReasoningEffort = null,
    // Optional per-request model, honoured only when in the AgentOptions.Models allow-list; else the default model.
    [property: JsonPropertyName("model")] string? Model = null,
    // Optional per-session system prompt; replaces the default for this turn when non-blank.
    [property: JsonPropertyName("systemPrompt")] string? SystemPrompt = null,
    // When true, ground the answer strictly in retrieved attachments (RAG only, no general model knowledge).
    [property: JsonPropertyName("ragOnly")] bool RagOnly = false
);

/// <summary>Non-secret runtime config the SPA fetches (GET /config): selectable models, default model, and default system prompt.</summary>
public sealed record ConfigResponse(
    [property: JsonPropertyName("models")] IReadOnlyList<string> Models,
    [property: JsonPropertyName("defaultModel")] string? DefaultModel,
    [property: JsonPropertyName("defaultSystemPrompt")] string DefaultSystemPrompt
);

/// <summary>One sessions-sidebar entry (GET /chat/sessions): conversation id, title from the first user message, last-message unix-seconds timestamp.</summary>
public sealed record ConversationSummary(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("updatedAt")] long UpdatedAt
);

/// <summary>Response body of GET /chat/sessions — conversations newest-first.</summary>
public sealed record ConversationListResponse(
    [property: JsonPropertyName("conversations")] IReadOnlyList<ConversationSummary> Conversations
);

/// <summary>One stored turn returned by GET /chat/{sessionId}/messages: a role and its display text.</summary>
public sealed record ConversationMessage(
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("text")] string Text
);

/// <summary>Response body of GET /chat/{sessionId}/messages — the transcript, oldest-first.</summary>
public sealed record ConversationHistoryResponse(
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("messages")] IReadOnlyList<ConversationMessage> Messages
);

/// <summary>Token usage information from the AI model.</summary>
public sealed record TokenUsage(
    [property: JsonPropertyName("prompt_tokens")] int PromptTokens,
    [property: JsonPropertyName("completion_tokens")] int CompletionTokens,
    [property: JsonPropertyName("total_tokens")] int TotalTokens,
    // Prompt-caching breakdown — tokens read back from the cache (Azure OpenAI gpt-4.1/gpt-5+).
    [property: JsonPropertyName("cached_details")] CachedTokenDetails? CachedDetails = null,
    // Reasoning/thinking tokens used internally by the model (reasoning models).
    [property: JsonPropertyName("reasoning_tokens")] int ReasoningTokens = 0
);

/// <summary>Breakdown of cached (prompt-caching) token counts.</summary>
public sealed record CachedTokenDetails(
    [property: JsonPropertyName("read_tokens")] int ReadTokens = 0
);

/// <summary>Response returned by the /chat endpoint.</summary>
public sealed record ChatResponse(
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("answer")] string Answer,
    [property: JsonPropertyName("usedTools")] IReadOnlyList<string> UsedTools,
    // Kept present-but-null when absent, matching FastAPI's Optional default (not omitted).
    [property: JsonPropertyName("tokenUsage")] TokenUsage? TokenUsage = null
);

/// <summary>
/// One part of the Vercel AI SDK UI Message Stream protocol (v1), streamed by /chat/stream as a bare <c>data: {json}\n\n</c> SSE line.
/// A single record spans every part kind (discriminated by <c>type</c>); each carries only its relevant fields (nulls omitted). Stream ends with a literal <c>[DONE]</c>.
/// </summary>
public sealed record UiStreamPart(
    [property: JsonPropertyName("type")] string Type,
    // text-*/reasoning-*: id ties the deltas to one block ("0" for text, "reasoning-0" for the thinking block).
    [property: JsonPropertyName("id"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Id = null,
    // text-delta / reasoning-delta: an incremental chunk of the answer text or the reasoning summary.
    [property: JsonPropertyName("delta"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Delta = null,
    // message-metadata: message-level info (token usage, tools used, session id) surfaced via message.metadata.
    [property: JsonPropertyName("messageMetadata"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] MessageMetadata? MessageMetadata = null,
    // tool-input-available / tool-output-available: correlates a tool's request and result (one function call).
    [property: JsonPropertyName("toolCallId"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ToolCallId = null,
    // tool-input-available: the invoked tool's name.
    [property: JsonPropertyName("toolName"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ToolName = null,
    // tool-input-available: the arguments sent to the tool (arbitrary JSON, serialized from FunctionCallContent.Arguments).
    [property: JsonPropertyName("input"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] object? Input = null,
    // tool-output-available: the result returned by the tool (arbitrary JSON, serialized from FunctionResultContent.Result).
    [property: JsonPropertyName("output"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] object? Output = null,
    // tool-*: marks the tool as client-unknown so useChat surfaces it as a `dynamic-tool` part (no static schema).
    [property: JsonPropertyName("dynamic"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Dynamic = null,
    // error: a provider/gateway failure surfaced in-band (the 200/text-event-stream headers are already committed).
    [property: JsonPropertyName("errorText"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ErrorText = null
);

/// <summary>Message-level metadata (token usage, used tools, session id) carried by a <c>message-metadata</c> part; read on the client via <c>message.metadata</c>.</summary>
public sealed record MessageMetadata(
    [property: JsonPropertyName("tokenUsage"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] TokenUsage? TokenUsage = null,
    [property: JsonPropertyName("usedTools"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? UsedTools = null,
    [property: JsonPropertyName("sessionId"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? SessionId = null
);
