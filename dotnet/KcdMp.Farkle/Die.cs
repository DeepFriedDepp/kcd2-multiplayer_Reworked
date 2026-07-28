namespace KcdMp.Farkle;

/// <summary>
/// A die's identity, distinct from its face value. v1 has only
/// <see cref="Standard"/> -- badges, weighted dice, and the Devil's Head are
/// out of scope here, but scoring and the wire format both key off this
/// rather than assuming every die is plain, so they can be added later
/// without changing either.
/// </summary>
public enum DieKind : byte
{
    Standard = 0,
}

/// <summary>One die as it currently sits on the table: a face value 1-6 and a kind.</summary>
public readonly record struct Die(byte Face, DieKind Kind = DieKind.Standard);
