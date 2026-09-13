namespace KcdMp.Client;

/// <summary>
/// WO-88: the decisions the agent makes when a peer -- or this client -- dies
/// and reloads a save. Pure functions, no I/O, so the 2026-09-12 field
/// session's four post-reload defects can be pinned by tests without a game.
///
/// The field evidence each rule answers to is in docs/WO-88-findings.md; the
/// short version:
///
///   * Death tag: the vitals path cleared <c>KCD2MP.ghostDead</c> on ANY
///     vitals packet, including the <c>health=0</c> packet the dying player's
///     own emitter sends in the same tick as its 0x23. Whether the tag stuck
///     for the death screen or vanished within milliseconds depended on which
///     of the two packets the relay delivered first (2 of 6 joiner deaths
///     cleared 3 and 32 log lines after being set).
///   * Appearance: the per-ghost "what is applied" set lived for the
///     connection, but a local save load destroys and respawns the ghost
///     entity wearing its spawn preset. Nothing told the diff, so the outfit
///     never came back and every later change was a delta on top of the
///     preset (both directions, all session after the first reload).
///   * Reload convergence: one batched ExecuteString, fire-and-forget, sent
///     inside the post-load window where the REST API was still refusing
///     requests. Host reload #5 lost it and ran 4.9 game-hours behind until a
///     manual wait; nothing re-checked because the poll watcher's baseline
///     was overwritten with the reloaded value right after the request.
///   * Quiet clock sync: each side's idea of the "session clock" was its own
///     stale pre-reload value or a connect-time announce extrapolated for
///     twenty minutes, so even successful convergences landed on different
///     clocks. A periodic announce keeps the peer clock fresh; receivers must
///     then ignore announces that only differ by natural skew.
/// </summary>
public static class ReloadReconcile
{
    // ---------------------------------------------------------------------
    // Death tag (finding 1)
    // ---------------------------------------------------------------------

    /// <summary>
    /// A vitals packet clears a ghost's death tag only when it says the
    /// player is alive. <c>health &lt;= 0</c> is the dying tick's own report
    /// (or a stale heartbeat while the death screen is up) and must leave the
    /// tag alone. The unconscious bit (flags bit 0) is not a death and is not
    /// consulted -- a knocked-out player is still "alive" for this purpose,
    /// which is what WO-38 Phase 6's separate corpse rule expects.
    /// </summary>
    public static bool VitalsClearDeathTag(float health) => health > 0f;

    // ---------------------------------------------------------------------
    // Appearance after a respawn (finding 2)
    // ---------------------------------------------------------------------

    /// <summary>
    /// The <c>ghostid</c> event from <c>KCD2MP_SpawnGhost</c> is the
    /// ghost-ready edge (WO-68 already treats it as such for civic isolation).
    /// A different entity id for a ghost we have already dressed means the
    /// body we dressed is gone: the applied/known/blacklist sets describe an
    /// entity that no longer exists and must be dropped before the outfit is
    /// re-applied. The first id ever seen for a ghost is not a respawn.
    /// </summary>
    public static bool RespawnInvalidatesAppearance(uint? previousEntityId, uint newEntityId)
        => previousEntityId is uint prev && prev != newEntityId;

    // ---------------------------------------------------------------------
    // Reload convergence (finding 4, primary)
    // ---------------------------------------------------------------------

    public enum ConvergeStep
    {
        /// <summary>No convergence outstanding.</summary>
        None,
        /// <summary>The clock now reads at or past the target: done.</summary>
        Satisfied,
        /// <summary>Still behind and inside the window: send the apply again.</summary>
        Resend,
        /// <summary>Still behind but the window closed: give up, say so.</summary>
        Expired,
    }

    /// <summary>
    /// Evaluates one world-clock reading against an outstanding reload
    /// convergence. The apply is forward-only in Lua, so re-sending an
    /// already-landed target is harmless; the cost of a lost one is hours of
    /// desync, so the check errs towards re-sending until the reading proves
    /// the write landed.
    /// </summary>
    /// <param name="pendingTarget">Target the reloader was asked to converge to; null when nothing is outstanding.</param>
    /// <param name="reading">The world clock just read from the mod.</param>
    /// <param name="thresholdSeconds">Slack below the target that still counts as converged (natural advance since the target was computed).</param>
    /// <param name="nowUtc">Now.</param>
    /// <param name="deadlineUtc">When to stop trying.</param>
    public static ConvergeStep EvaluateConvergence(uint? pendingTarget, uint reading, uint thresholdSeconds,
        DateTime nowUtc, DateTime deadlineUtc)
    {
        if (pendingTarget is not uint target) return ConvergeStep.None;
        if (reading + (ulong)thresholdSeconds >= target) return ConvergeStep.Satisfied;
        return nowUtc <= deadlineUtc ? ConvergeStep.Resend : ConvergeStep.Expired;
    }

    // ---------------------------------------------------------------------
    // Quiet clock sync from a peer (finding 4, secondary)
    // ---------------------------------------------------------------------

    /// <summary>
    /// Whether a peer's quiet clock report should be written into this world.
    /// With periodic announces every peer hears every other peer's clock about
    /// once a minute; two clocks running at the same ratio differ only by
    /// poll skew and transit, so a report inside <paramref name="thresholdSeconds"/>
    /// of our own extrapolated clock is noise and applying it would nudge the
    /// sky forward for nothing. A report further ahead than that is a real
    /// gap (a reload we missed, a skip whose announce we missed) and is
    /// applied. With no local reading yet, apply -- the Lua side is
    /// forward-only regardless.
    /// </summary>
    public static bool QuietSyncWorthApplying(uint incoming, uint? lastPolled, DateTime lastPollUtc,
        DateTime nowUtc, double worldTimeRatio, uint thresholdSeconds)
    {
        if (lastPolled is not uint last) return true;
        double elapsed = (nowUtc - lastPollUtc).TotalSeconds;
        if (elapsed < 0) elapsed = 0;
        double estimatedNow = last + elapsed * worldTimeRatio;
        return incoming > estimatedNow + thresholdSeconds;
    }
}
