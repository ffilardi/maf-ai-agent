namespace AgentBackend.Services;

/// <summary>
/// The one escaping rule shared by every OData filter we build by hand — Azure AI Search scope filters
/// (<see cref="SearchAdapter"/>, <see cref="SearchIndexer"/>) and the Table Storage queries in <see cref="IngestionStatusStore"/>.
/// </summary>
public static class OData
{
    /// <summary>Quotes <paramref name="value"/> as an OData string literal (single quotes doubled).</summary>
    public static string Literal(string value) => $"'{value.Replace("'", "''")}'";
}
