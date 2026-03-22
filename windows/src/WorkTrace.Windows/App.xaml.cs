using Microsoft.UI.Xaml;
using WorkTrace.Windows.Services;

namespace WorkTrace.Windows;

public partial class App : Application
{
    private Window? _window;
    private LocalIngestServer? _ingestServer;

    public static IngestEventStore IngestStore { get; } = new();

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();

        _ingestServer = new LocalIngestServer(IngestStore, port: 17600);
        _ = _ingestServer.StartAsync(CancellationToken.None);
    }
}

