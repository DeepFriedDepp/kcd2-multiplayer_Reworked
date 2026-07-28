using System.Security.Cryptography;

namespace KcdMp.Farkle;

/// <summary>
/// The only source of randomness a <see cref="FarkleGame"/> touches --
/// picking the first player and every die face. Injected so tests can pin it
/// down and the relay can hand each session its own CSPRNG instance.
/// </summary>
public interface IDiceRng
{
    /// <summary>Returns a value in [minInclusive, maxExclusive).</summary>
    int Next(int minInclusive, int maxExclusive);
}

/// <summary>
/// Production RNG: a cryptographically secure, uniform, unbiased source.
/// One instance per session -- it carries no state worth sharing.
/// </summary>
public sealed class CryptoDiceRng : IDiceRng
{
    public int Next(int minInclusive, int maxExclusive) => RandomNumberGenerator.GetInt32(minInclusive, maxExclusive);
}

/// <summary>
/// Deterministic RNG for tests and the debug-only scripted-match override.
/// Same seed, same sequence, always -- that determinism is the entire point.
/// </summary>
public sealed class SeededDiceRng(int seed) : IDiceRng
{
    private readonly Random _random = new(seed);

    public int Next(int minInclusive, int maxExclusive) => _random.Next(minInclusive, maxExclusive);
}
