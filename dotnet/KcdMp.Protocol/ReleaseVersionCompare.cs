namespace KcdMp.Wire;

/// <summary>Result of comparing two release version strings. See <see cref="ReleaseVersionCompare"/>.</summary>
public enum ReleaseVersionComparison
{
    Equal,
    LocalIsOlder,
    LocalIsNewer,
    /// <summary>Either string didn't parse. WO-19: fall back to a neutral
    /// "versions don't match" rather than guessing a direction.</summary>
    Ambiguous,
}

/// <summary>
/// Compares two release version strings (VERSION's own "Major.Minor.Patch",
/// optionally with a fourth build component -- see docs/VERSIONING.md) so a
/// mismatch notification can say who is behind instead of just "different."
///
/// This is release versioning (the human-chosen VERSION file, WO-19), a
/// separate concern from <see cref="Protocol.Version"/>, the wire protocol
/// byte the relay hard-refuses on mismatch. Two builds can carry the same
/// protocol byte and still be different release versions.
/// </summary>
public static class ReleaseVersionCompare
{
    public static ReleaseVersionComparison Compare(string local, string remote)
    {
        if (!TryParse(local, out var l) || !TryParse(remote, out var r))
            return ReleaseVersionComparison.Ambiguous;

        for (int i = 0; i < 4; i++)
        {
            if (l[i] != r[i])
                return l[i] < r[i] ? ReleaseVersionComparison.LocalIsOlder : ReleaseVersionComparison.LocalIsNewer;
        }
        return ReleaseVersionComparison.Equal;
    }

    private static bool TryParse(string s, out int[] parts)
    {
        parts = [0, 0, 0, 0];
        if (string.IsNullOrWhiteSpace(s)) return false;

        var segments = s.Trim().Split('.');
        if (segments.Length < 2 || segments.Length > 4) return false;

        for (int i = 0; i < segments.Length; i++)
        {
            if (!int.TryParse(segments[i], out parts[i])) return false;
        }
        return true;
    }
}
