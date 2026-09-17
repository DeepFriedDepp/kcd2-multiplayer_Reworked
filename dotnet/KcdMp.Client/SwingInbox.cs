using System.Threading.Channels;

namespace KcdMp.Client;

/// <summary>
/// WO-100 Phase 4, items 1–4, for the inbound swing path.
///
/// Before this, an inbound swing was applied like so:
///
/// <code>
///   if (_ghostEntityIds.TryGetValue(source, out uint id))
///       _ = _combat.GhostSwingAsync(id, spec, ct).ContinueWith(t =&gt; log(ok));
///   // else: silently downgrade to the Lua cue, forever
/// </code>
///
/// Four problems, all of which this class exists to fix:
///
/// 1. <b>No validity counters.</b> The entity id is looked up at apply time, so
///    a swing that crossed a ghost respawn was applied to whatever body now
///    holds that slot. WO-88 already established that a changed entity id means
///    a new body; nothing used that for events in flight.
/// 2. <b>No bounded wait for the precondition.</b> A swing that arrived in the
///    window between a ghost spawning and its <c>ghostid</c> event was
///    downgraded to the Lua cue permanently, because "we do not know the entity
///    id" was treated as final rather than as "not yet".
/// 3. <b>One generic failure.</b> <c>ok=0</c> covered a despawned target, a
///    fragment missing from this build, a body with no combat actor, and a
///    wedged game thread.
/// 4. <b>No bound on pending work.</b> Fire-and-forget tasks piled up against a
///    single pipe gate with a 5 s wait each.
///
/// Everything is injected, so this is testable without a game, a pipe or a
/// clock: see <c>SwingInboxTests</c>.
/// </summary>
public sealed class SwingInbox : IAsyncDisposable
{
    /// <summary>One inbound swing, with everything needed to decide it is still valid.</summary>
    public readonly record struct Entry(
        string GhostId,
        ushort Sid,
        long   Rsid,
        int    BodyGeneration,
        string FragSpec,
        DateTime EnqueuedAt);

    /// <summary>What happened to one entry. Mirrors <see cref="PipeReason"/>'s vocabulary.</summary>
    public readonly record struct Outcome(Entry Entry, bool Ok, PipeReason Reason, double WaitedMs);

    private readonly Channel<Entry> _queue;
    private readonly Func<string, uint?> _resolveEntityId;
    private readonly Func<string, int> _currentGeneration;
    private readonly Func<uint, string, CancellationToken, Task<PipeResult>> _apply;
    private readonly Action<string> _log;
    private readonly Func<DateTime> _now;
    private readonly Func<CancellationToken, Task> _pollDelay;
    private readonly TimeSpan _preconditionDeadline;
    private readonly int _capacity;

    private Task? _worker;
    private readonly CancellationTokenSource _stop = new();

    // Counters. Public so MP-SUMMARY can print them and a test can assert them.
    public long Accepted   { get; private set; }
    public long Dropped    { get; private set; }   // inbox full
    public long Expired    { get; private set; }   // crossed a respawn/reload
    public long Waited     { get; private set; }   // needed the precondition wait at all
    public long GaveUp     { get; private set; }   // precondition never became true
    public long Applied    { get; private set; }
    public long Refused    { get; private set; }
    public long PeakDepth  { get; private set; }

    /// <summary>Raised for every entry that leaves the queue, whatever the outcome.</summary>
    public Action<Outcome>? OnOutcome { get; set; }

    public SwingInbox(
        Func<string, uint?> resolveEntityId,
        Func<string, int> currentGeneration,
        Func<uint, string, CancellationToken, Task<PipeResult>> apply,
        Action<string> log,
        int capacity = 16,
        TimeSpan? preconditionDeadline = null,
        Func<DateTime>? now = null,
        Func<CancellationToken, Task>? pollDelay = null)
    {
        _resolveEntityId   = resolveEntityId;
        _currentGeneration = currentGeneration;
        _apply             = apply;
        _log               = log;
        _capacity          = capacity;
        _now               = now ?? (() => DateTime.UtcNow);
        _pollDelay         = pollDelay ?? (ct => Task.Delay(25, ct));
        // 750 ms: a ghost's `ghostid` event follows its spawn within a couple
        // of Lua ticks, and a swing older than this is not worth showing --
        // the animation would land after the moment it depicts. A GUESS, not a
        // measurement; the give-up line prints the real waited time so a field
        // session can tune it with evidence.
        _preconditionDeadline = preconditionDeadline ?? TimeSpan.FromMilliseconds(750);

        // FullMode.Wait with a NON-blocking TryWrite, deliberately. The two
        // Drop modes both make TryWrite return true while discarding an item,
        // which is precisely the silent loss this class exists to remove --
        // the caller could not tell a queued swing from a dropped one. Wait
        // makes TryWrite return false when the queue is at its bound, so the
        // refusal is a fact the caller counts and logs. Nothing ever blocks on
        // the writer: TryWrite is the only write path.
        _queue = Channel.CreateBounded<Entry>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false,
        });
    }

    public void Start() => _worker ??= Task.Run(() => RunAsync(_stop.Token));

    /// <summary>
    /// Offer one inbound swing. Returns false when the queue is at its bound --
    /// the caller logs it as <c>reason=inbox-full</c> rather than pretending it
    /// was sent.
    /// </summary>
    public bool TryEnqueue(Entry e)
    {
        if (!_queue.Writer.TryWrite(e))
        {
            Dropped++;
            _log($"MP-SWING hop=dropped rsid={e.Rsid} sid={e.Sid} ghost={e.GhostId} " +
                 $"reason=inbox-full bound={_capacity} dropped_total={Dropped}");
            return false;
        }
        Accepted++;
        // Reader.Count is a snapshot, which is all a pressure report needs.
        int depth = _queue.Reader.Count;
        if (depth > PeakDepth)
        {
            PeakDepth = depth;
            if (depth * 2 >= _capacity)
                _log($"MP-SWING hop=pressure depth={depth} bound={_capacity} " +
                     $"-- the inbound swing queue is over half full");
        }
        return true;
    }

    private async Task RunAsync(CancellationToken ct)
    {
        try
        {
            await foreach (var e in _queue.Reader.ReadAllAsync(ct))
            {
                Outcome outcome;
                try { outcome = await ProcessAsync(e, ct); }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    // An unobserved exception here would stop the worker and
                    // the whole channel would go quiet -- indistinguishable
                    // from "no swings arrived".
                    outcome = new Outcome(e, false, PipeReason.Unknown, 0);
                    _log($"MP-SWING hop=error rsid={e.Rsid} sid={e.Sid} ghost={e.GhostId} " +
                         $"reason=handler-threw detail=\"{ex.GetType().Name}: {ex.Message}\"");
                }
                OnOutcome?.Invoke(outcome);
            }
        }
        catch (OperationCanceledException) { }
        _log("MP-SWING hop=worker-exit");
    }

    private async Task<Outcome> ProcessAsync(Entry e, CancellationToken ct)
    {
        // Validity counter first, before anything is waited on: an event from a
        // body that has since died, respawned or reloaded is discarded, not
        // replayed. This is the cheapest correctness win in the WO.
        int gen = _currentGeneration(e.GhostId);
        if (gen != e.BodyGeneration)
        {
            Expired++;
            _log($"MP-SWING hop=expired rsid={e.Rsid} sid={e.Sid} ghost={e.GhostId} " +
                 $"reason=expired gen_sent={e.BodyGeneration} gen_now={gen}");
            return new Outcome(e, false, PipeReason.Expired, 0);
        }

        var start = _now();
        uint? id = _resolveEntityId(e.GhostId);
        if (id is null)
        {
            Waited++;
            while (id is null)
            {
                if ((_now() - start) >= _preconditionDeadline)
                {
                    GaveUp++;
                    double ms = (_now() - start).TotalMilliseconds;
                    _log($"MP-SWING hop=gaveup rsid={e.Rsid} sid={e.Sid} ghost={e.GhostId} " +
                         $"reason=precondition-timeout waited_ms={ms:F0} " +
                         $"deadline_ms={_preconditionDeadline.TotalMilliseconds:F0} gaveup_total={GaveUp}");
                    return new Outcome(e, false, PipeReason.PreconditionTimeout, ms);
                }
                await _pollDelay(ct);
                // The body can be replaced while we wait, which invalidates the
                // event just as surely as if it had arrived late.
                if (_currentGeneration(e.GhostId) != e.BodyGeneration)
                {
                    Expired++;
                    double ms0 = (_now() - start).TotalMilliseconds;
                    _log($"MP-SWING hop=expired rsid={e.Rsid} sid={e.Sid} ghost={e.GhostId} " +
                         $"reason=expired-while-waiting waited_ms={ms0:F0}");
                    return new Outcome(e, false, PipeReason.Expired, ms0);
                }
                id = _resolveEntityId(e.GhostId);
            }
        }

        double waited = (_now() - start).TotalMilliseconds;
        PipeResult r = await _apply(id.Value, e.FragSpec, ct);
        if (r.Ok) Applied++; else Refused++;
        _log($"MP-SWING hop=queued rsid={e.Rsid} sid={e.Sid} ghost={e.GhostId} " +
             $"entity=0x{id.Value:X} ok={(r.Ok ? 1 : 0)} reason={r.ReasonTag} waited_ms={waited:F0}");
        return new Outcome(e, r.Ok, r.Reason, waited);
    }

    /// <summary>One line for MP-SUMMARY.</summary>
    public string SummaryLine() =>
        $"MP-SUMMARY section=swinginbox accepted={Accepted} applied={Applied} refused={Refused} " +
        $"expired={Expired} waited={Waited} gaveup={GaveUp} dropped={Dropped} " +
        $"peak_depth={PeakDepth} bound={_capacity}";

    public async ValueTask DisposeAsync()
    {
        _queue.Writer.TryComplete();
        _stop.Cancel();
        if (_worker is not null)
        {
            try { await _worker; } catch (OperationCanceledException) { }
        }
        _stop.Dispose();
    }
}
