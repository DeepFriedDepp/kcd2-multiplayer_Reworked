namespace KCDMP_launcher.Models
{
    /// <summary>
    /// Mirrors the agent's DiceIpcSnapshotDto family (dotnet/KcdMp.Client/DiceIpcState.cs)
    /// byte for byte in JSON shape. Kept as its own small copy rather than a
    /// project reference to KcdMp.Client: this is a local IPC contract between
    /// two processes on one machine, not the relay wire protocol, and the
    /// launcher has no other reason to depend on the agent's assembly.
    /// </summary>
    public sealed class DiceIpcSnapshot
    {
        public DiceInvite? Invite { get; set; }
        public DiceSession? Session { get; set; }
    }

    public sealed class DiceInvite
    {
        public ushort SessionId { get; set; }
        public string FromName { get; set; } = "";
    }

    public sealed class DiceSession
    {
        public ushort SessionId { get; set; }
        public string Role { get; set; } = "";
        public string PeerName { get; set; } = "";
        public byte CurrentPlayerRole { get; set; }
        public int ScoreInitiator { get; set; }
        public int ScoreAcceptor { get; set; }
        public int TurnTotal { get; set; }
        public int TargetScore { get; set; }
        public string Phase { get; set; } = "";
        public byte[] FreeFaces { get; set; } = [];
        public byte[] KeptFaces { get; set; } = [];
        public string? LastError { get; set; }
        public DiceResult? Result { get; set; }

        public bool IsMyTurn => (Role == "Initiator" && CurrentPlayerRole == 0) || (Role == "Acceptor" && CurrentPlayerRole == 1);
    }

    public sealed class DiceResult
    {
        public string Outcome { get; set; } = "";
        public int ScoreInitiator { get; set; }
        public int ScoreAcceptor { get; set; }

        public bool DidIWin(string myRole) =>
            (myRole == "Initiator" && Outcome == "InitiatorWon") || (myRole == "Acceptor" && Outcome == "AcceptorWon");
    }
}
