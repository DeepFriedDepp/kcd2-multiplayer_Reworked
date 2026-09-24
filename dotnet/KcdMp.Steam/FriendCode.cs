namespace KcdMp.Steam;

/// <summary>
/// The short code a host reads out to a friend: "ABCD-EFG".
///
/// It is the host's Steam account id (the low 32 bits of an individual,
/// public-universe SteamID) plus a 3-bit check, in Crockford base32: 35 bits,
/// exactly seven characters. The check catches most single-character typos,
/// so a mistyped code says "that code isn't right" instead of dialling a
/// stranger. Decoding forgives case, spaces, dashes and the usual look-alikes
/// (O for 0, I/L for 1).
///
/// The code is as identifying as the account it names. It lives only on the
/// two players' screens and is never logged (<see cref="Redact"/>).
/// </summary>
public static class FriendCode
{
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// <summary>Universe 1 (public), type 1 (individual), instance 1 (desktop).</summary>
    private const ulong IndividualBase = 0x0110000100000000UL;

    public static string Encode(ulong steamId64)
    {
        if (!IsIndividual(steamId64)) throw new ArgumentException("Not an individual Steam account.", nameof(steamId64));
        uint account = (uint)steamId64;
        ulong v = ((ulong)account << 3) | Check(account);
        Span<char> c = stackalloc char[7];
        for (int i = 6; i >= 0; i--) { c[i] = Alphabet[(int)(v & 31)]; v >>= 5; }
        return $"{c[..4]}-{c[4..]}";
    }

    public static bool TryDecode(string? text, out ulong steamId64)
    {
        steamId64 = 0;
        if (string.IsNullOrWhiteSpace(text)) return false;
        ulong v = 0;
        int n = 0;
        foreach (char raw in text)
        {
            if (raw is '-' or ' ' or '\t') continue;
            char ch = char.ToUpperInvariant(raw) switch { 'O' => '0', 'I' or 'L' => '1', var x => x };
            int d = Alphabet.IndexOf(ch);
            if (d < 0 || ++n > 7) return false;
            v = (v << 5) | (uint)d;
        }
        if (n != 7) return false;
        uint account = (uint)(v >> 3);
        if ((v & 7) != Check(account) || account == 0) return false;
        steamId64 = IndividualBase | account;
        return true;
    }

    public static bool IsIndividual(ulong steamId64) => (steamId64 & 0xFFFFFFFF00000000UL) == IndividualBase && (uint)steamId64 != 0;

    /// <summary>What a log line may say about a peer: that there is one, never which.</summary>
    public static string Redact(ulong _) => "<steam-peer>";

    private static ulong Check(uint account)
    {
        uint s = 0;
        for (int i = 0; i < 32; i += 3) s += (account >> i) & 7;
        return (s * 5 + 3) & 7;
    }
}
