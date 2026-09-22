namespace KcdMp.Client;

/// <summary>
/// WO-100 Phase 4 item 3 — a specific failure vocabulary for the KCDMP.dll pipe.
///
/// Every native failure path already logged a precise reason into the native
/// log, but the pipe collapsed them all into one bool, so the agent log showed
/// only <c>ok=0</c>. Field diagnosis has stalled on exactly that more than once
/// (WO-46, WO-47, WO-98): "the swing did not apply" could mean the ghost had
/// despawned, the fragment is not in this build's database, the body had no
/// combat actor yet, or the game thread never ran the task — four different
/// problems with four different fixes.
///
/// These numbers mirror <c>kcdmp::rttr::SwingResult</c> in
/// <c>native/KCDMP/combat_swing.h</c> and are APPEND-ONLY: renumbering one
/// would make a mismatched agent/DLL pair misreport rather than say "unknown".
/// </summary>
public enum PipeReason : byte
{
    /// <summary>Applied.</summary>
    Ok = 0,
    /// <summary>The fragment spec was empty or oversized — a sender-side bug.</summary>
    BadSpec = 1,
    /// <summary>A game module the native path needs is not loaded.</summary>
    ModuleMissing = 2,
    /// <summary>The DLL's hard-coded RVAs do not match this game build; native swings are off.</summary>
    BuildMismatch = 3,
    /// <summary>EntityModule exposed no export table.</summary>
    NoExports = 4,
    /// <summary>TARGET MISSING: the entity id resolves to nothing — despawned, or stale after a respawn.</summary>
    TargetMissing = 5,
    /// <summary>BODY IN THE WRONG STATE: the actor has no combat actor and one could not be created.</summary>
    BodyWrongState = 6,
    /// <summary>The actor's animation-action manager is null.</summary>
    ManagerMissing = 7,
    AllocatorMissing = 8,
    GameIfaceMissing = 9,
    AnimDbChainBroke = 10,
    ParseFaulted = 11,
    /// <summary>ROW NOT PRESENT ON THIS BUILD: the fragment is unknown to this actor's animation database.</summary>
    RowNotOnThisBuild = 12,
    AllocFailed = 13,
    CtorFailed = 14,
    /// <summary>ENGINE REFUSED THE ACTION: the queue call itself faulted.</summary>
    EngineRefused = 15,
    /// <summary>The game thread never took the task inside the DLL's own bound.</summary>
    Timeout = 16,
    /// <summary>WO-110 R12: the task ran on the game thread and FAULTED (SEH or C++ exception); its result is not to be trusted.</summary>
    TaskFaulted = 17,
    /// <summary>WO-110 R12: the DLL does not know this command type (an agent newer than the DLL).</summary>
    UnknownCommand = 18,

    // ---- agent-side reasons. Deliberately above the native range so the two
    // vocabularies can never collide as either side grows. ----

    /// <summary>The DLL is not injected, or the pipe dropped.</summary>
    NotConnected = 200,
    /// <summary>No reply arrived inside the agent's deadline. NOT a refusal.</summary>
    NoAnswer = 201,
    /// <summary>A precondition the receiver waited for never became true. See the waited ms in the log.</summary>
    PreconditionTimeout = 202,
    /// <summary>Dropped because the pending queue was at its bound.</summary>
    InboxFull = 203,
    /// <summary>Discarded: the body it names has died, respawned or reloaded since the event was sent.</summary>
    Expired = 204,
    /// <summary>Discarded: out of order, or already applied.</summary>
    StaleOrDuplicate = 205,
    /// <summary>A pre-WO-100 DLL: it applied or refused, but did not say which kind.</summary>
    Unknown = 255,
}

/// <summary>Outcome of one pipe exchange: did it apply, and if not, which kind of not.</summary>
public readonly record struct PipeResult(bool Ok, PipeReason Reason)
{
    public static PipeResult Fail(PipeReason reason) => new(false, reason);

    /// <summary>Lower-case, hyphenated, stable — for <c>reason=</c> in a log line.</summary>
    public string ReasonTag => Reason switch
    {
        PipeReason.Ok                  => "ok",
        PipeReason.BadSpec             => "bad-spec",
        PipeReason.ModuleMissing       => "module-missing",
        PipeReason.BuildMismatch       => "build-mismatch",
        PipeReason.NoExports           => "no-exports",
        PipeReason.TaskFaulted         => "task-faulted",
        PipeReason.UnknownCommand      => "unknown-command",
        PipeReason.TargetMissing       => "target-missing",
        PipeReason.BodyWrongState      => "body-wrong-state",
        PipeReason.ManagerMissing      => "manager-missing",
        PipeReason.AllocatorMissing    => "allocator-missing",
        PipeReason.GameIfaceMissing    => "gameiface-missing",
        PipeReason.AnimDbChainBroke    => "animdb-chain-broke",
        PipeReason.ParseFaulted        => "parse-faulted",
        PipeReason.RowNotOnThisBuild   => "row-not-on-this-build",
        PipeReason.AllocFailed         => "alloc-failed",
        PipeReason.CtorFailed          => "ctor-failed",
        PipeReason.EngineRefused       => "engine-refused",
        PipeReason.Timeout             => "dll-timeout",
        PipeReason.NotConnected        => "not-connected",
        PipeReason.NoAnswer            => "no-answer",
        PipeReason.PreconditionTimeout => "precondition-timeout",
        PipeReason.InboxFull           => "inbox-full",
        PipeReason.Expired             => "expired",
        PipeReason.StaleOrDuplicate    => "stale-or-duplicate",
        PipeReason.Unknown             => "unknown",
        _                              => $"reason-{(byte)Reason}",
    };
}
