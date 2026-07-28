namespace KcdMp.Farkle.Tests;

/// <summary>
/// Returns a pre-scripted sequence of values, one per call, in order.
/// Throws if a test asks for more than it scripted -- an under-scripted
/// fake is a bug in the test, not something to paper over with a default.
/// </summary>
public sealed class FakeDiceRng(params int[] values) : IDiceRng
{
    private readonly Queue<int> _values = new(values);

    public int Next(int minInclusive, int maxExclusive)
    {
        if (_values.Count == 0)
            throw new InvalidOperationException("FakeDiceRng ran out of scripted values.");
        return _values.Dequeue();
    }
}
