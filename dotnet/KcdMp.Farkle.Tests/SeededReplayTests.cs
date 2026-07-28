namespace KcdMp.Farkle.Tests;

/// <summary>
/// Drives a full match with a fixed, simple bot policy and proves that the
/// same seed always reproduces the same match -- the property Test-Dice.ps1
/// (Phase 2) relies on for its scripted-seed scenarios.
/// </summary>
public class SeededReplayTests
{
    private const int BankThreshold = 300;

    [Fact]
    public void Seeded_Full_Match_Replay_Is_Deterministic()
    {
        var (outcomeA, scoresA) = PlayFullMatch(seed: 12345);
        var (outcomeB, scoresB) = PlayFullMatch(seed: 12345);

        Assert.Equal(outcomeA, outcomeB);
        Assert.Equal(scoresA, scoresB);
        Assert.NotEqual(FarkleOutcome.InProgress, outcomeA);
        Assert.True(scoresA[0] >= 4000 || scoresA[1] >= 4000);
    }

    private static (FarkleOutcome outcome, int[] scores) PlayFullMatch(int seed)
    {
        var game = new FarkleGame(new SeededDiceRng(seed), targetScore: 4000);

        int safetyLimit = 100_000; // guards against an infinite loop being a test hang instead of a failure
        while (game.Outcome == FarkleOutcome.InProgress)
        {
            Assert.True(safetyLimit-- > 0, "match did not terminate");

            if (game.Phase == TurnPhase.AwaitingRoll)
            {
                var result = game.TurnTotal >= BankThreshold
                    ? game.Bank(game.CurrentPlayer)
                    : game.Roll(game.CurrentPlayer);
                Assert.True(result.Accepted);
            }
            else
            {
                var result = game.Keep(game.CurrentPlayer, GreedyKeepMask(game.FreeDice));
                Assert.True(result.Accepted);
            }
        }

        return (game.Outcome, (int[])game.Scores.Clone());
    }

    /// <summary>
    /// A deterministic (not necessarily optimal) keep: take the straight if
    /// the roll is exactly one, otherwise take every 1, every 5, and every
    /// face that appears three or more times. Always produces a valid,
    /// non-empty mask when called in AwaitingKeep, since Roll only reaches
    /// that phase when at least one such group exists.
    /// </summary>
    private static int GreedyKeepMask(IReadOnlyList<Die> dice)
    {
        if (dice.Count is 5 or 6)
        {
            var faces = dice.Select(d => d.Face).OrderBy(f => f).ToArray();
            bool isStraight =
                (dice.Count == 6 && faces.SequenceEqual(new byte[] { 1, 2, 3, 4, 5, 6 })) ||
                (dice.Count == 5 && faces.SequenceEqual(new byte[] { 1, 2, 3, 4, 5 })) ||
                (dice.Count == 5 && faces.SequenceEqual(new byte[] { 2, 3, 4, 5, 6 }));
            if (isStraight) return (1 << dice.Count) - 1;
        }

        var counts = new int[7];
        foreach (var die in dice) counts[die.Face]++;

        int mask = 0;
        for (int i = 0; i < dice.Count; i++)
        {
            byte face = dice[i].Face;
            bool partOfGroup = counts[face] >= 3 || face is 1 or 5;
            if (partOfGroup) mask |= 1 << i;
        }
        return mask;
    }
}
