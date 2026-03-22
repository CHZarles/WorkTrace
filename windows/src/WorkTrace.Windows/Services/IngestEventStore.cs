using WorkTrace.Windows.Models;

namespace WorkTrace.Windows.Services;

public sealed class IngestEventStore
{
    public event EventHandler<IngestEvent>? EventReceived;

    public void Add(IngestEvent e)
    {
        EventReceived?.Invoke(this, e);
    }
}

