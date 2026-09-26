namespace KcdMp.Client;

/// <summary>
/// WO-127: the HOST CLAIM bit on this agent's Position packets
/// (Protocol.PositionFlagHostClaim, ProtocolWo127.cs). The relay makes a
/// claimant the authority whatever order people connected in, which closes
/// WO-124's carry-forward (a remote relay used to hand authority to the first
/// agent to connect) and keeps it with the host when joiners arrive over Steam.
///
/// This agent claims when:
///   * the launcher started the relay for it (--hosting), or
///   * mp_shared_world is on and this game is in a world of its own -- latched
///     from that moment so a load (the host reloading, _where = Loading) never
///     drops the claim mid-session; cleared when the toggle goes off or this
///     machine becomes a joiner (a join running, or in the host's world).
/// A joiner waits for the host at the MAIN MENU (WO-124), so it never claims.
/// </summary>
public partial class GameBridge
{
    private bool _hostClaimLatched;
    private bool? _hostClaimLogged;

    private bool Wo127ClaimsHost()
    {
        bool claim;
        if (config.IsHosting) claim = true;
        else if (!_sharedWorld || _joinedWorld || _jj is not null) { _hostClaimLatched = false; claim = false; }
        else
        {
            bool inOwnWorld = _where == GameWhere.World || (_where == GameWhere.Unknown && !_startedAtMenu);
            if (inOwnWorld) _hostClaimLatched = true;
            claim = _hostClaimLatched;
        }
        if (_hostClaimLogged != claim)
        {
            _hostClaimLogged = claim;
            Console.WriteLine($"MP-HOST-CLAIM {(claim ? "on" : "off")} (hosting={(config.IsHosting ? 1 : 0)} shared_world={(_sharedWorld ? 1 : 0)} joined={(_joinedWorld ? 1 : 0)} where={_where})");
        }
        return claim;
    }
}
