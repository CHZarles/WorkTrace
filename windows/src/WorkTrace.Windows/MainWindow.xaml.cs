using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using WorkTrace.Windows.Services;
using System.Collections.ObjectModel;

namespace WorkTrace.Windows;

public sealed partial class MainWindow : Window
{
    public MainViewModel ViewModel { get; } = new(App.IngestStore);

    public MainWindow()
    {
        InitializeComponent();
    }
}

public sealed class MainViewModel
{
    private readonly IngestEventStore _store;
    private readonly DispatcherQueue _dispatcherQueue;

    public string ServerStatus { get; private set; } = "Local ingest: starting… (127.0.0.1:17600)";
    public ObservableCollection<IngestEventLine> RecentEvents { get; } = new();

    public MainViewModel(IngestEventStore store)
    {
        _store = store;
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        _store.EventReceived += OnEventReceived;
        ServerStatus = "Local ingest: listening on http://127.0.0.1:17600 (POST /event)";
    }

    private void OnEventReceived(object? sender, Models.IngestEvent e)
    {
        _ = _dispatcherQueue.TryEnqueue(() =>
        {
            RecentEvents.Insert(0, IngestEventLine.From(e));
            while (RecentEvents.Count > 50)
            {
                RecentEvents.RemoveAt(RecentEvents.Count - 1);
            }
        });
    }
}

public sealed record IngestEventLine(string Title, string Subtitle)
{
    public static IngestEventLine From(Models.IngestEvent e)
    {
        var time = e.Ts.ToLocalTime().ToString("HH:mm:ss");
        var title = string.IsNullOrWhiteSpace(e.Title) ? e.Domain : $"{e.Domain} — {e.Title}";
        return new IngestEventLine(title, $"{time}  |  {e.Browser ?? "unknown"}");
    }
}

