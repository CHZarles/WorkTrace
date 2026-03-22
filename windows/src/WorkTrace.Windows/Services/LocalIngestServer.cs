using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using WorkTrace.Windows.Models;
using System.Text.Json;

namespace WorkTrace.Windows.Services;

public sealed class LocalIngestServer : IAsyncDisposable
{
    private readonly IngestEventStore _store;
    private readonly int _port;
    private WebApplication? _app;
    private Task? _runTask;

    public LocalIngestServer(IngestEventStore store, int port)
    {
        _store = store;
        _port = port;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (_app is not null)
        {
            return;
        }

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            Args = Array.Empty<string>()
        });

        builder.WebHost.UseUrls($"http://127.0.0.1:{_port}");
        builder.Services.AddCors(options =>
        {
            options.AddDefaultPolicy(new CorsPolicyBuilder()
                .AllowAnyOrigin()
                .AllowAnyHeader()
                .AllowAnyMethod()
                .Build());
        });

        var app = builder.Build();
        app.UseCors();

        app.MapGet("/health", () => Results.Ok(new { ok = true }));

        app.MapPost("/event", async (HttpRequest request, CancellationToken ct) =>
        {
            IngestEvent? e;
            try
            {
                e = await JsonSerializer.DeserializeAsync<IngestEvent>(request.Body, cancellationToken: ct);
            }
            catch
            {
                return Results.BadRequest(new { error = "invalid_json" });
            }

            if (e is null || string.IsNullOrWhiteSpace(e.Domain))
            {
                return Results.BadRequest(new { error = "invalid_event" });
            }

            _store.Add(e);
            return Results.Ok(new { ok = true });
        });

        app.MapMethods("/event", new[] { "OPTIONS" }, () => Results.Ok());

        _app = app;
        _runTask = app.RunAsync(cancellationToken);

        // Best-effort: wait briefly so extension can start sending immediately.
        await Task.Delay(50, cancellationToken);
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_app is null)
        {
            return;
        }

        await _app.StopAsync(cancellationToken);
        _app.Dispose();
        _app = null;

        if (_runTask is not null)
        {
            await _runTask;
            _runTask = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync(CancellationToken.None);
    }
}

