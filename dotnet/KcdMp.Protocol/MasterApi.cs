using System.Text.Json;
using System.Text.Json.Serialization;

namespace KcdMp.Wire;

/// <summary>
/// The master server contract: what a relay says to get itself listed, and
/// what the launcher reads back to fill the server browser.
///
/// It lives here, next to <see cref="Protocol"/>, because all three programs
/// need the same definitions -- the master server (KcdMp.MasterServer), the
/// relay that announces itself (KcdMp.Server) and the launcher that reads the
/// listing. A DTO copied into each of them is a DTO that drifts; the launcher
/// spent a release binding "ip" against a field the master called "ip_address"
/// and every server arrived with a blank address.
///
/// Three version numbers meet here and none of them is the others:
/// <list type="bullet">
/// <item><see cref="Version"/> -- this API. Bumped when the messages below
/// change shape. The master refuses an announce that does not match, and the
/// launcher refuses a listing that does not match.</item>
/// <item><see cref="Protocol.Version"/> -- the relay wire protocol, carried in
/// a listing so the launcher can tell a player their build cannot join that
/// server before the game is started rather than after.</item>
/// <item>The release version (the repo's VERSION file), carried for display
/// and compared with <see cref="ReleaseVersionCompare"/>.</item>
/// </list>
/// </summary>
public static class MasterApi
{
    /// <summary>
    /// Version of the messages in this file. Bump on any change that an older
    /// peer would misread; adding a field a peer can ignore is not one.
    /// </summary>
    public const int Version = 1;

    /// <summary>Listing endpoint the launcher GETs. Absolute path on the master.</summary>
    public const string ListPath = "/api/v1/servers";

    /// <summary>WebSocket endpoint a relay holds open for as long as it is up.</summary>
    public const string ConnectPath = "/api/v1/servers/connect";

    /// <summary>Status endpoint, for a quick "is the master alive" check.</summary>
    public const string StatusPath = "/api/v1/status";

    /// <summary>
    /// How often a relay sends something -- an update if anything changed, a
    /// bare heartbeat otherwise. The master hands this back on accept, so a
    /// relay follows the master's pace rather than its own configuration.
    /// </summary>
    public const int HeartbeatSeconds = 10;

    /// <summary>
    /// How long the master waits for that before treating the connection as
    /// dead. Generous enough to ride out a couple of missed beats: a dropped
    /// socket is normally noticed by the close itself, and this only catches
    /// the half-open case where no close ever arrives.
    /// </summary>
    public const int TimeoutSeconds = 30;

    /// <summary>Largest message either side will read, in bytes.</summary>
    public const int MaxMessageBytes = 8 * 1024;

    /// <summary>
    /// One options instance for every program on this contract, so a field
    /// cannot be written camelCase by one and read PascalCase by another.
    ///
    /// Nulls are left out: <see cref="MasterMessage"/> carries one payload out
    /// of four, and writing the other three as "null" triples the size of
    /// every message for nothing.
    /// </summary>
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary><see cref="MasterMessage.Type"/> values.</summary>
    public static class MessageType
    {
        /// <summary>Relay to master, first message on the socket.</summary>
        public const string Announce = "announce";

        /// <summary>Relay to master, whenever the mutable state changed.</summary>
        public const string Update = "update";

        /// <summary>Relay to master, when nothing changed but the socket should stay listed.</summary>
        public const string Heartbeat = "heartbeat";

        /// <summary>Master to relay, the announce was accepted and the server is listed.</summary>
        public const string Accepted = "accepted";

        /// <summary>Master to relay, the announce was refused. The socket closes after it.</summary>
        public const string Rejected = "rejected";
    }

    /// <summary><see cref="MasterRejected.Code"/> values.</summary>
    public static class RejectCode
    {
        /// <summary>The relay speaks a different <see cref="Version"/> of this API.</summary>
        public const string ApiVersion = "api_version";

        /// <summary>The announce was malformed or failed validation.</summary>
        public const string Invalid = "invalid";

        /// <summary>The master is at its configured server limit.</summary>
        public const string Full = "full";
    }
}

/// <summary>
/// Envelope for everything sent over the relay-to-master WebSocket. One type
/// with optional payloads rather than a polymorphic hierarchy: it round-trips
/// through System.Text.Json with no converter to configure, and a reader can
/// see the whole protocol in one place.
/// </summary>
public sealed record MasterMessage
{
    /// <summary>One of <see cref="MasterApi.MessageType"/>.</summary>
    public string Type { get; init; } = "";

    /// <summary>Sender's <see cref="MasterApi.Version"/>. Checked on announce.</summary>
    public int ApiVersion { get; init; }

    public ServerAnnounce? Announce { get; init; }
    public ServerUpdate? Update { get; init; }
    public MasterAccepted? Accepted { get; init; }
    public MasterRejected? Rejected { get; init; }
}

/// <summary>
/// Everything the master needs to list a relay. Sent once, when the socket
/// opens; the fields that move afterwards are repeated in
/// <see cref="ServerUpdate"/>.
/// </summary>
public sealed record ServerAnnounce
{
    /// <summary>Shown in the browser.</summary>
    public string Name { get; init; } = "";

    /// <summary>The relay's release version, from the repo's VERSION file.</summary>
    public string ReleaseVersion { get; init; } = "";

    /// <summary>The relay's <see cref="Protocol.Version"/>.</summary>
    public byte ProtocolVersion { get; init; }

    /// <summary>
    /// Address to publish, when the relay knows better than the master does --
    /// a hostname, or a public address the master cannot see because a proxy
    /// sits in front of it. Left empty normally: a relay behind NAT does not
    /// know the address peers reach it on, and the master can see it.
    /// </summary>
    public string? Address { get; init; }

    /// <summary>TCP port peers connect to. This is the address in the listing.</summary>
    public int Port { get; init; }

    /// <summary>
    /// HTTP port serving /api/information. The launcher does not need it for a
    /// listed server -- the counts below are pushed live -- but it is the only
    /// way to reach a relay's own view of itself, so it is published rather
    /// than guessed from a default that no longer holds once a second relay
    /// runs on the same host.
    /// </summary>
    public int InfoPort { get; init; }

    public string MapName { get; init; } = "";
    public int Players { get; init; }
    public int MaxPlayers { get; init; }

    /// <summary>At most three, from the master's fixed list. Others are dropped with a warning.</summary>
    public string[] Tags { get; init; } = [];

    public string? Description { get; init; }
}

/// <summary>The parts of an announce that change while a relay runs.</summary>
public sealed record ServerUpdate
{
    public string MapName { get; init; } = "";
    public int Players { get; init; }
    public int MaxPlayers { get; init; }
}

/// <summary>Master's answer to an accepted announce.</summary>
public sealed record MasterAccepted
{
    /// <summary>Identifies this listing. Also the id in <see cref="MasterApi.ListPath"/>/{id}.</summary>
    public string Id { get; init; } = "";

    /// <summary>The address the listing was published under, so the relay can log what peers will see.</summary>
    public string Address { get; init; } = "";

    /// <summary>How often the master wants to hear from this relay.</summary>
    public int HeartbeatSeconds { get; init; } = MasterApi.HeartbeatSeconds;

    /// <summary>
    /// Non-fatal complaints about the announce -- a dropped tag, a truncated
    /// field. The listing is live either way; without these the operator
    /// would have to work out on their own why a tag never appeared.
    /// </summary>
    public string[] Warnings { get; init; } = [];
}

/// <summary>Master's answer to a refused announce. The socket closes after it.</summary>
public sealed record MasterRejected
{
    /// <summary>One of <see cref="MasterApi.RejectCode"/>.</summary>
    public string Code { get; init; } = "";

    /// <summary>Human-readable, meant for the relay operator's log.</summary>
    public string Reason { get; init; } = "";

    /// <summary>The master's own <see cref="MasterApi.Version"/>.</summary>
    public int ApiVersion { get; init; } = MasterApi.Version;
}

/// <summary>One server in the browser. Response of GET <see cref="MasterApi.ListPath"/>.</summary>
public sealed record ServerListing
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";

    /// <summary>Address peers connect to, paired with <see cref="Port"/>.</summary>
    public string Address { get; init; } = "";

    public int Port { get; init; }
    public int InfoPort { get; init; }
    public string MapName { get; init; } = "";
    public int Players { get; init; }
    public int MaxPlayers { get; init; }

    /// <summary>The relay's release version, for display.</summary>
    public string ReleaseVersion { get; init; } = "";

    /// <summary>
    /// The relay's wire protocol version. A launcher whose
    /// <see cref="Protocol.Version"/> differs cannot join this server at all --
    /// the relay hard-refuses the handshake -- so it is worth saying so in the
    /// browser rather than after the game has loaded.
    /// </summary>
    public byte ProtocolVersion { get; init; }

    public string[] Tags { get; init; } = [];
    public string? Description { get; init; }

    /// <summary>When the relay's connection to the master was opened.</summary>
    public DateTimeOffset OnlineSince { get; init; }
}

/// <summary>Response of GET <see cref="MasterApi.ListPath"/>.</summary>
public sealed record ServerListResponse
{
    /// <summary>
    /// The master's <see cref="MasterApi.Version"/>. A launcher that does not
    /// recognise it should say so plainly rather than show a list it may be
    /// misreading.
    /// </summary>
    public int ApiVersion { get; init; } = MasterApi.Version;

    public ServerListing[] Servers { get; init; } = [];
}

/// <summary>Response of GET <see cref="MasterApi.StatusPath"/>.</summary>
public sealed record MasterStatus
{
    public int ApiVersion { get; init; } = MasterApi.Version;
    public int Servers { get; init; }
    public int Players { get; init; }
}
