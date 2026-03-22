using System.Text.Json.Serialization;

namespace WorkTrace.Windows.Models;

public sealed record IngestEvent
{
    [JsonPropertyName("v")]
    public int V { get; init; } = 1;

    [JsonPropertyName("ts")]
    public DateTimeOffset Ts { get; init; }

    [JsonPropertyName("source")]
    public string Source { get; init; } = "browser_extension";

    [JsonPropertyName("event")]
    public string EventName { get; init; } = "tab_active";

    [JsonPropertyName("browser")]
    public string? Browser { get; init; }

    [JsonPropertyName("domain")]
    public string Domain { get; init; } = "";

    [JsonPropertyName("title")]
    public string? Title { get; init; }

    [JsonPropertyName("windowId")]
    public int? WindowId { get; init; }

    [JsonPropertyName("tabId")]
    public int? TabId { get; init; }
}

