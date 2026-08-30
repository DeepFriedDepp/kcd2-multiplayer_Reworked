using System.Collections.Concurrent;
using System.Globalization;
using System.Threading.Channels;

namespace KcdMp.Client;

/// <summary>
/// Lazily starts one asynchronous output worker. Ordinary messages are queued;
/// noisy event streams can be grouped by key and emitted as periodic summaries.
/// </summary>
internal sealed class AsyncLogger : IAsyncDisposable
{
    private sealed class Summary
    {
        public int Count;
        public string Latest = "";
        public double MetricTotal;
        public int MetricCount;
        public string? MetricName;
        public string MetricUnit = "";
    }

    private readonly TimeSpan _summaryInterval;
    private readonly Action<string> _output;
    private readonly CancellationTokenSource _cts;
    private readonly Channel<string> _messages = Channel.CreateBounded<string>(
        new BoundedChannelOptions(1024)
        {
            SingleReader = true,
            FullMode = BoundedChannelFullMode.DropOldest,
        });
    private readonly ConcurrentDictionary<string, Summary> _summaries = new();
    private readonly object _workerGate = new();
    private Task? _worker;

    public AsyncLogger(CancellationToken sessionToken, TimeSpan? summaryInterval = null,
        Action<string>? output = null)
    {
        _summaryInterval = summaryInterval ?? TimeSpan.FromSeconds(2);
        _output = output ?? Console.WriteLine;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(sessionToken);
    }

    /// <summary>Queues a normal log line without blocking its caller on console I/O.</summary>
    public void Log(string message)
    {
        EnsureWorker();
        _messages.Writer.TryWrite(message);
    }

    /// <summary>
    /// Adds one event to a keyed periodic summary. The latest detail is kept;
    /// an optional numeric metric is averaged across the interval.
    /// </summary>
    public void Summarize(string key, string latest, double? metric = null,
        string? metricName = null, string metricUnit = "")
    {
        Summary summary = _summaries.GetOrAdd(key, _ => new Summary());
        lock (summary)
        {
            summary.Count++;
            summary.Latest = latest;
            if (metric.HasValue)
            {
                summary.MetricTotal += metric.Value;
                summary.MetricCount++;
                summary.MetricName = metricName;
                summary.MetricUnit = metricUnit;
            }
        }
        EnsureWorker();
    }

    private void EnsureWorker()
    {
        if (_worker is not null) return;
        lock (_workerGate)
            _worker ??= Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        using var timer = new PeriodicTimer(_summaryInterval);
        Task<bool> messageReady = _messages.Reader.WaitToReadAsync(_cts.Token).AsTask();
        Task<bool> summaryReady = timer.WaitForNextTickAsync(_cts.Token).AsTask();

        try
        {
            while (!_cts.IsCancellationRequested)
            {
                Task completed = await Task.WhenAny(messageReady, summaryReady);
                if (completed == messageReady)
                {
                    if (!await messageReady) break;
                    DrainMessages();
                    messageReady = _messages.Reader.WaitToReadAsync(_cts.Token).AsTask();
                }
                if (completed == summaryReady)
                {
                    if (!await summaryReady) break;
                    FlushSummaries();
                    summaryReady = timer.WaitForNextTickAsync(_cts.Token).AsTask();
                }
            }
        }
        catch (OperationCanceledException) when (_cts.IsCancellationRequested) { }
        finally
        {
            DrainMessages();
            FlushSummaries();
        }
    }

    private void DrainMessages()
    {
        while (_messages.Reader.TryRead(out string? message))
            _output(message);
    }

    private void FlushSummaries()
    {
        foreach (var pair in _summaries)
        {
            int count;
            string latest;
            double metricTotal;
            int metricCount;
            string? metricName;
            string metricUnit;
            lock (pair.Value)
            {
                count = pair.Value.Count;
                if (count == 0) continue;
                latest = pair.Value.Latest;
                metricTotal = pair.Value.MetricTotal;
                metricCount = pair.Value.MetricCount;
                metricName = pair.Value.MetricName;
                metricUnit = pair.Value.MetricUnit;
                pair.Value.Count = 0;
                pair.Value.MetricTotal = 0;
                pair.Value.MetricCount = 0;
            }

            string average = metricCount > 0 && metricName is not null
                ? string.Create(CultureInfo.InvariantCulture,
                    $", avg-{metricName}={metricTotal / metricCount:F1}{metricUnit}")
                : "";
            _output(string.Create(CultureInfo.InvariantCulture,
                $"[{pair.Key}] {count} events/{_summaryInterval.TotalSeconds:F0}s, latest={latest}{average}"));
        }
    }

    public async ValueTask DisposeAsync()
    {
        _messages.Writer.TryComplete();
        _cts.Cancel();
        Task? worker;
        lock (_workerGate) worker = _worker;
        if (worker is not null)
            await worker.ConfigureAwait(false);
        _cts.Dispose();
    }
}
