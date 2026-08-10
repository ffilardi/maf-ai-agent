using System.Net;
using System.Text;
using AgentBackend.Configuration;
using AgentBackend.Models;
using Microsoft.Azure.Cosmos;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace AgentBackend.Services;

/// <summary>
/// Read/list/delete access to the transcripts MAF's <c>CosmosChatHistoryProvider</c> stores (which exposes no list/read API),
/// querying the container directly on its schema (partitioned on <c>/conversationId</c>). Display text is pulled from each
/// serialized <see cref="Microsoft.Extensions.AI.ChatMessage"/>'s <c>contents[*].text</c> nodes.
/// NOTE: no auth/user scoping today, so <see cref="ListAsync"/> enumerates every conversation — scope by user/tenant id under real auth.
/// </summary>
public sealed class ConversationStore(CosmosClient cosmosClient, AgentOptions options)
{
    // Sidebar title length cap (first user message is truncated to this).
    private const int MaxTitleChars = 48;
    // Ceiling on concurrent per-conversation title lookups in ListAsync.
    private const int TitleConcurrency = 8;

    private Container Container => cosmosClient.GetContainer(options.CosmosDb, options.CosmosContainer);

    /// <summary>Lists conversations newest-first (by last-message timestamp), capped at <paramref name="limit"/>, each titled from its first user message.</summary>
    public async Task<IReadOnlyList<ConversationSummary>> ListAsync(int limit, CancellationToken ct)
    {
        var container = Container;

        // Ordering + limiting server-side (rather than materializing every group and sorting client-side) keeps the
        // response — and the client-side memory/CPU to build it — bounded by `limit` instead of total conversation
        // count. The GROUP BY still scans every message document to compute each group's MAX(timestamp); that scan
        // cost only goes away with a per-conversation summary doc or user/tenant scoping (see the class note above).
        var top = new List<(string Id, long UpdatedAt)>();
        var listQuery = new QueryDefinition(
            "SELECT c.conversationId AS id, MAX(c.timestamp) AS updatedAt FROM c " +
            "GROUP BY c.conversationId ORDER BY MAX(c.timestamp) DESC OFFSET 0 LIMIT @limit")
            .WithParameter("@limit", limit);
        using (var iter = container.GetItemQueryIterator<JObject>(listQuery))
        {
            while (iter.HasMoreResults)
            {
                foreach (var row in await iter.ReadNextAsync(ct))
                {
                    var id = row["id"]?.Value<string>();
                    if (string.IsNullOrEmpty(id))
                    {
                        continue;
                    }
                    top.Add((id, ReadTimestamp(row["updatedAt"])));
                }
            }
        }

        // Gated parallel title lookups to bound RU.
        using var gate = new SemaphoreSlim(TitleConcurrency);
        var titles = await Task.WhenAll(top.Select(async c =>
        {
            await gate.WaitAsync(ct);
            try
            {
                return await GetTitleAsync(container, c.Id, ct);
            }
            finally
            {
                gate.Release();
            }
        }));

        return top.Select((c, i) => new ConversationSummary(c.Id, titles[i], c.UpdatedAt)).ToList();
    }

    /// <summary>Returns a conversation's user/assistant text turns oldest-first; rows without text and non-user/assistant roles are dropped. Unknown id ⇒ empty.</summary>
    public async Task<IReadOnlyList<ConversationMessage>> GetMessagesAsync(string sessionId, CancellationToken ct)
    {
        var messages = new List<ConversationMessage>();
        var query = new QueryDefinition(
            "SELECT c.role, c.message FROM c WHERE c.conversationId = @cid ORDER BY c.timestamp ASC")
            .WithParameter("@cid", sessionId);
        using var iter = Container.GetItemQueryIterator<JObject>(
            query, requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(sessionId) });

        while (iter.HasMoreResults)
        {
            foreach (var row in await iter.ReadNextAsync(ct))
            {
                var role = row["role"]?.Value<string>()?.ToLowerInvariant();
                if (role is not ("user" or "assistant"))
                {
                    continue;
                }
                var text = ExtractText(row["message"]).Trim();
                if (text.Length == 0)
                {
                    continue;
                }
                messages.Add(new ConversationMessage(role, text));
            }
        }

        return messages;
    }

    /// <summary>Deletes every message document in a conversation (the whole partition).</summary>
    public async Task DeleteAsync(string sessionId, CancellationToken ct)
    {
        var container = Container;
        var partition = new PartitionKey(sessionId);

        var ids = new List<string>();
        var query = new QueryDefinition("SELECT c.id FROM c WHERE c.conversationId = @cid")
            .WithParameter("@cid", sessionId);
        using (var iter = container.GetItemQueryIterator<JObject>(
            query, requestOptions: new QueryRequestOptions { PartitionKey = partition }))
        {
            while (iter.HasMoreResults)
            {
                foreach (var row in await iter.ReadNextAsync(ct))
                {
                    var id = row["id"]?.Value<string>();
                    if (!string.IsNullOrEmpty(id))
                    {
                        ids.Add(id);
                    }
                }
            }
        }

        foreach (var id in ids)
        {
            try
            {
                await container.DeleteItemAsync<JObject>(id, partition, cancellationToken: ct);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
            {
                // Already gone (concurrent delete / TTL) — nothing to do.
            }
        }
    }

    // First user message → sidebar title; falls back to "New chat" when there's no user turn yet.
    private static async Task<string> GetTitleAsync(Container container, string conversationId, CancellationToken ct)
    {
        var query = new QueryDefinition(
            "SELECT TOP 1 c.message FROM c WHERE c.conversationId = @cid AND LOWER(c.role) = 'user' ORDER BY c.timestamp ASC")
            .WithParameter("@cid", conversationId);
        using var iter = container.GetItemQueryIterator<JObject>(
            query,
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(conversationId), MaxItemCount = 1 });

        while (iter.HasMoreResults)
        {
            foreach (var row in await iter.ReadNextAsync(ct))
            {
                var text = ExtractText(row["message"]).Trim();
                if (text.Length > 0)
                {
                    return Truncate(text, MaxTitleChars);
                }
            }
        }

        return "New chat";
    }

    // Pulls display text from a stored ChatMessage by concatenating each content part's text (top-level text as fallback).
    // MAF persists `message` as an STJ-serialized JSON string (PascalCase, `$type` per part), so it is parsed first with case-insensitive lookups.
    private static string ExtractText(JToken? message)
    {
        if (message is null)
        {
            return string.Empty;
        }

        JToken node = message;
        if (message.Type == JTokenType.String)
        {
            var raw = message.Value<string>();
            if (string.IsNullOrEmpty(raw))
            {
                return string.Empty;
            }
            try
            {
                node = JToken.Parse(raw);
            }
            catch (JsonReaderException)
            {
                // Not JSON — treat the raw string as the text itself.
                return raw;
            }
        }

        if (node is not JObject obj)
        {
            return node.Type == JTokenType.String ? node.Value<string>() ?? string.Empty : string.Empty;
        }

        if (obj.GetValue("Contents", StringComparison.OrdinalIgnoreCase) is JArray contents)
        {
            var sb = new StringBuilder();
            foreach (var content in contents)
            {
                if (content is JObject part &&
                    part.GetValue("Text", StringComparison.OrdinalIgnoreCase) is { Type: JTokenType.String } text)
                {
                    sb.Append(text.Value<string>());
                }
            }
            return sb.ToString();
        }

        return obj.GetValue("Text", StringComparison.OrdinalIgnoreCase) is { Type: JTokenType.String } topLevel
            ? topLevel.Value<string>() ?? string.Empty
            : string.Empty;
    }

    // The provider stores `timestamp` as unix seconds (a JSON number); read it defensively.
    private static long ReadTimestamp(JToken? token) =>
        token?.Type is JTokenType.Integer or JTokenType.Float ? token.Value<long>() : 0L;

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max].TrimEnd() + "…";
}
