using System.Runtime.InteropServices;

namespace KcdMp.Steam;

/// <summary>
/// The Steamworks flat API, only the calls WO-120 needs.
///
/// Export names and interface versions were read from the game's own
/// steam_api64.dll (1070 exports; SteamUser v023, SteamNetworkingSockets v012,
/// SteamNetworkingMessages v002, SteamNetworkingUtils v004, SteamFriends v017,
/// SteamNetworking v006, SteamAPI_InitFlat present: an SDK 1.58/1.59 build).
/// Nothing here is guessed from a newer SDK: a missing export fails at the
/// first call with EntryPointNotFoundException rather than misbehaving.
///
/// C++ bool is one byte, so every bool crosses as I1. Strings are UTF-8.
/// Struct layouts are Steam's Windows packing (8); the ones read as raw
/// bytes carry their offsets in <see cref="ConnInfo"/>.
/// </summary>
internal static class SteamNative
{
    public const string Lib = "steam_api64";
    private const CallingConvention Cc = CallingConvention.Cdecl;

    // --- lifecycle -----------------------------------------------------------

    /// <summary>ESteamAPIInitResult: 0 OK, 1 generic failure, 2 no Steam client, 3 version mismatch.</summary>
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_InitFlat(byte[] errMsg1024);
    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_Shutdown();
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_IsSteamRunning();
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_GetHSteamPipe();

    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_ManualDispatch_Init();
    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_ManualDispatch_RunFrame(int hSteamPipe);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ManualDispatch_GetNextCallback(int hSteamPipe, out CallbackMsg msg);
    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_ManualDispatch_FreeLastCallback(int hSteamPipe);

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct CallbackMsg
    {
        public int HSteamUser;
        public int ICallback;
        public IntPtr PubParam;
        public int CubParam;
    }

    // Callback ids: k_i*Callbacks base + offset (steam_api_common.h / steamnetworkingtypes.h).
    public const int CbConnectionStatusChanged = 1221; // SteamNetConnectionStatusChangedCallback_t
    public const int CbAuthenticationStatus = 1222;    // SteamNetAuthenticationStatus_t
    public const int CbMessagesSessionRequest = 1251;  // SteamNetworkingMessagesSessionRequest_t
    public const int CbMessagesSessionFailed = 1252;   // SteamNetworkingMessagesSessionFailed_t
    public const int CbP2PSessionRequest = 1202;       // P2PSessionRequest_t (ISteamNetworking, legacy)
    public const int CbP2PSessionConnectFail = 1203;   // P2PSessionConnectFail_t
    public const int CbRelayNetworkStatus = 1281;      // SteamRelayNetworkStatus_t
    public const int CbFriendRichPresenceUpdate = 336; // FriendRichPresenceUpdate_t
    public const int CbGameRichPresenceJoinRequested = 337;

    // --- user / utils / friends ------------------------------------------------

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamUser_v023();
    [DllImport(Lib, CallingConvention = Cc)] public static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamUser_BLoggedOn(IntPtr self);

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamUtils_v010();
    [DllImport(Lib, CallingConvention = Cc)] public static extern uint SteamAPI_ISteamUtils_GetAppID(IntPtr self);

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamFriends_v017();
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr self, int flags);
    [DllImport(Lib, CallingConvention = Cc)] public static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr self, int index, int flags);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr self, ulong friend, out FriendGameInfo info);
    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr self, ulong friend, [MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_ISteamFriends_RequestFriendRichPresence(IntPtr self, ulong friend);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr self, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string? value);
    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_ISteamFriends_ClearRichPresence(IntPtr self);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_InviteUserToGame(IntPtr self, ulong friend, [MarshalAs(UnmanagedType.LPUTF8Str)] string connectString);

    /// <summary>k_EFriendFlagImmediate: real friends, not blocked/requested/clan members.</summary>
    public const int FriendFlagImmediate = 0x04;

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct FriendGameInfo
    {
        public ulong GameId;        // CGameID; low 24 bits are the app id
        public uint GameIp;
        public ushort GamePort;
        public ushort QueryPort;
        public ulong SteamIdLobby;
    }

    // --- networking sockets (v012) ----------------------------------------------

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamNetworkingSockets_SteamAPI_v012();
    [DllImport(Lib, CallingConvention = Cc)] public static extern uint SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(IntPtr self, int localVirtualPort, int nOptions, IntPtr options);
    [DllImport(Lib, CallingConvention = Cc)] public static extern uint SteamAPI_ISteamNetworkingSockets_ConnectP2P(IntPtr self, ref Identity remote, int remoteVirtualPort, int nOptions, IntPtr options);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingSockets_AcceptConnection(IntPtr self, uint conn);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworkingSockets_CloseConnection(IntPtr self, uint conn, int reason, [MarshalAs(UnmanagedType.LPUTF8Str)] string? debug, [MarshalAs(UnmanagedType.I1)] bool linger);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworkingSockets_CloseListenSocket(IntPtr self, uint socket);
    [DllImport(Lib, CallingConvention = Cc)] public static extern unsafe int SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(IntPtr self, uint conn, byte* data, uint cb, int flags, out long msgNum);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(IntPtr self, uint conn, [Out] IntPtr[] msgs, int max);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(IntPtr self, uint conn, [Out] byte[] info);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus(IntPtr self, uint conn, out RealTimeStatus status, int nLanes, IntPtr lanes);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingSockets_InitAuthentication(IntPtr self);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingSockets_GetAuthenticationStatus(IntPtr self, IntPtr details);

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamNetworkingUtils_SteamAPI_v004();
    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(IntPtr self);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(IntPtr self, [Out] byte[] details);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32(IntPtr self, int value, int val);

    [DllImport(Lib, CallingConvention = Cc)] public static extern void SteamAPI_SteamNetworkingMessage_t_Release(IntPtr msg);

    // --- networking messages (v002) ---------------------------------------------

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamNetworkingMessages_SteamAPI_v002();
    [DllImport(Lib, CallingConvention = Cc)] public static extern unsafe int SteamAPI_ISteamNetworkingMessages_SendMessageToUser(IntPtr self, ref Identity remote, byte* data, uint cb, int flags, int remoteChannel);
    [DllImport(Lib, CallingConvention = Cc)] public static extern int SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(IntPtr self, int localChannel, [Out] IntPtr[] msgs, int max);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(IntPtr self, ref Identity remote);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser(IntPtr self, ref Identity remote);

    // --- legacy networking (v006) -----------------------------------------------

    [DllImport(Lib, CallingConvention = Cc)] public static extern IntPtr SteamAPI_SteamNetworking_v006();
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern unsafe bool SteamAPI_ISteamNetworking_SendP2PPacket(IntPtr self, ulong remote, byte* data, uint cb, int sendType, int channel);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworking_IsP2PPacketAvailable(IntPtr self, out uint size, int channel);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworking_ReadP2PPacket(IntPtr self, [Out] byte[] dest, uint cb, out uint size, out ulong remote, int channel);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(IntPtr self, ulong remote);
    [DllImport(Lib, CallingConvention = Cc)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(IntPtr self, ulong remote);

    // --- structs ------------------------------------------------------------------

    /// <summary>SteamNetworkingIdentity: type, size, 128-byte union. 136 bytes.</summary>
    [StructLayout(LayoutKind.Sequential, Pack = 8, Size = 136)]
    public struct Identity
    {
        public int Type;      // k_ESteamNetworkingIdentityType_SteamID = 16
        public int CbSize;    // 8 for a SteamID
        public ulong SteamId64;

        public static Identity FromSteamId(ulong id) => new() { Type = 16, CbSize = 8, SteamId64 = id };
    }

    /// <summary>SteamNetConnectionRealTimeStatus_t, 120 bytes.</summary>
    [StructLayout(LayoutKind.Sequential, Pack = 8, Size = 120)]
    public struct RealTimeStatus
    {
        public int State;
        public int Ping;
        public float QualityLocal;
        public float QualityRemote;
        public float OutPacketsPerSec;
        public float OutBytesPerSec;
        public float InPacketsPerSec;
        public float InBytesPerSec;
        public int SendRateBytesPerSecond;
        public int PendingUnreliable;
        public int PendingReliable;
        public int SentUnackedReliable;
        public long QueueTimeUsec;
    }

    /// <summary>
    /// Offsets into SteamNetConnectionInfo_t (696 bytes), read as raw bytes
    /// so a layout mistake shows up as a wrong number in a log line rather
    /// than as a marshalling crash. Derived from steamnetworkingtypes.h:
    /// identity(136) userData(8) listenSocket(4) addrRemote(18, pack 1)
    /// pad(2) popRemote(4) popRelay(4) state endReason endDebug[128]
    /// description[128] flags reserved[63].
    /// </summary>
    public static class ConnInfo
    {
        public const int Size = 696;
        public const int ListenSocket = 144;
        public const int State = 176;
        public const int EndReason = 180;
        public const int EndDebug = 184;
        public const int Flags = 440;
    }

    /// <summary>SteamNetConnectionStatusChangedCallback_t: hConn(4) pad(4) info(696) oldState(4) pad(4).</summary>
    public const int StatusChangedSize = 712;
    public const int StatusChangedInfoOffset = 8;

    /// <summary>SteamNetworkingMessage_t field offsets.</summary>
    public static class Msg
    {
        public const int Data = 0;       // void*
        public const int Size = 8;       // int
        public const int Conn = 12;      // HSteamNetConnection
        public const int PeerIdentity = 16; // SteamNetworkingIdentity (136)
        public const int Channel = 192;  // int
    }

    // ESteamNetworkingConnectionState
    public const int StateNone = 0, StateConnecting = 1, StateFindingRoute = 2, StateConnected = 3,
                     StateClosedByPeer = 4, StateProblemDetectedLocally = 5;

    // k_nSteamNetworkConnectionInfoFlags_*
    public const int InfoFlagUnauthenticated = 1, InfoFlagUnencrypted = 2, InfoFlagLoopbackBuffers = 4,
                     InfoFlagFast = 8, InfoFlagRelayed = 16, InfoFlagDualWifi = 32;

    // k_nSteamNetworkingSend_*
    public const int SendUnreliable = 0, SendNoNagle = 1, SendReliable = 8, SendReliableNoNagle = 9;

    /// <summary>k_cbMaxSteamNetworkingSocketsMessageSizeSend.</summary>
    public const int MaxMessageSize = 512 * 1024;

    // EResult values we branch on.
    public const int ResultOk = 1, ResultNoConnection = 3, ResultInvalidParam = 8, ResultInvalidState = 11,
                     ResultLimitExceeded = 25, ResultIgnored = 43;

    // EP2PSend (legacy)
    public const int P2PReliable = 2;

    // ESteamNetworkingConfigValue
    public const int ConfigSendBufferSize = 9;
}
