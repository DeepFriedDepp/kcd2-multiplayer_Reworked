namespace KcdMp.Farkle.Tests;

public class ScoringTests
{
    private static List<Die> Dice(params byte[] faces) => faces.Select(f => new Die(f)).ToList();

    [Fact]
    public void Single_One_Scores_100()
    {
        Assert.True(Scoring.TryScore(Dice(1), out int score));
        Assert.Equal(100, score);
    }

    [Fact]
    public void Two_Ones_Score_200()
    {
        Assert.True(Scoring.TryScore(Dice(1, 1), out int score));
        Assert.Equal(200, score);
    }

    [Fact]
    public void Single_Five_Scores_50()
    {
        Assert.True(Scoring.TryScore(Dice(5), out int score));
        Assert.Equal(50, score);
    }

    [Fact]
    public void Two_Fives_Score_100()
    {
        Assert.True(Scoring.TryScore(Dice(5, 5), out int score));
        Assert.Equal(100, score);
    }

    [Fact]
    public void Triple_Ones_Score_1000()
    {
        Assert.True(Scoring.TryScore(Dice(1, 1, 1), out int score));
        Assert.Equal(1000, score);
    }

    [Theory]
    [InlineData((byte)2, 200)]
    [InlineData((byte)3, 300)]
    [InlineData((byte)4, 400)]
    [InlineData((byte)5, 500)]
    [InlineData((byte)6, 600)]
    public void Triple_N_Scores_N_Times_100(byte face, int expected)
    {
        Assert.True(Scoring.TryScore(Dice(face, face, face), out int score));
        Assert.Equal(expected, score);
    }

    [Theory]
    [InlineData((byte)1, 4, 2000)]
    [InlineData((byte)1, 5, 4000)]
    [InlineData((byte)1, 6, 8000)]
    [InlineData((byte)2, 4, 400)]
    [InlineData((byte)2, 5, 800)]
    [InlineData((byte)2, 6, 1600)]
    [InlineData((byte)5, 4, 1000)]
    [InlineData((byte)5, 5, 2000)]
    [InlineData((byte)5, 6, 4000)]
    public void Four_Five_Six_Of_A_Kind_Double_Quadruple_Octuple_The_Triple(byte face, int count, int expected)
    {
        var faces = Enumerable.Repeat(face, count).ToArray();
        Assert.True(Scoring.TryScore(Dice(faces), out int score));
        Assert.Equal(expected, score);
    }

    [Fact]
    public void Straight_One_To_Five_Scores_500()
    {
        Assert.True(Scoring.TryScore(Dice(1, 2, 3, 4, 5), out int score));
        Assert.Equal(500, score);
    }

    [Fact]
    public void Straight_Two_To_Six_Scores_750()
    {
        Assert.True(Scoring.TryScore(Dice(2, 3, 4, 5, 6), out int score));
        Assert.Equal(750, score);
    }

    [Fact]
    public void Straight_One_To_Six_Scores_1500()
    {
        Assert.True(Scoring.TryScore(Dice(1, 2, 3, 4, 5, 6), out int score));
        Assert.Equal(1500, score);
    }

    [Fact]
    public void Triple_Plus_Singles_From_A_Single_Roll_Combine()
    {
        // Triple 3s (300) + single 1 (100) + single 5 (50) = 450, all from one selection.
        Assert.True(Scoring.TryScore(Dice(3, 3, 3, 1, 5), out int score));
        Assert.Equal(450, score);
    }

    [Fact]
    public void Two_Triples_In_One_Selection_Combine_And_Is_Not_Mistaken_For_A_Straight()
    {
        // {1,1,1,5,5,5} is not the 1-5 straight multiset (which needs one of each of 1..5).
        Assert.True(Scoring.TryScore(Dice(1, 1, 1, 5, 5, 5), out int score));
        Assert.Equal(1500, score); // triple 1s (1000) + triple 5s (500)
    }

    [Theory]
    [InlineData((byte)2)]
    [InlineData((byte)3)]
    [InlineData((byte)4)]
    [InlineData((byte)6)]
    public void Lone_Non_Scoring_Die_Is_Invalid(byte face)
    {
        Assert.False(Scoring.TryScore(Dice(face), out _));
    }

    [Fact]
    public void Pair_Of_A_Non_Scoring_Face_Is_Invalid()
    {
        Assert.False(Scoring.TryScore(Dice(2, 2), out _));
    }

    [Fact]
    public void Almost_Straight_With_A_Stray_Extra_Die_Is_Invalid()
    {
        // Four of the five 1-5 straight dice plus an unrelated 2 -- not a straight,
        // and the extra 2 has no other grouping to belong to.
        Assert.False(Scoring.TryScore(Dice(1, 2, 3, 4, 2), out _));
    }

    [Fact]
    public void Scoring_Group_Plus_A_Stray_Die_Is_Invalid_Even_Though_Part_Scores()
    {
        // Triple 1s scores, but the trailing lone 2 does not -- the whole selection is rejected.
        Assert.False(Scoring.TryScore(Dice(1, 1, 1, 2), out _));
    }

    [Fact]
    public void Empty_Selection_Is_Invalid()
    {
        Assert.False(Scoring.TryScore(Dice(), out _));
    }

    [Theory]
    [InlineData(new byte[] { 1 }, true)]
    [InlineData(new byte[] { 5 }, true)]
    [InlineData(new byte[] { 3, 3, 3 }, true)]
    [InlineData(new byte[] { 2, 2, 3, 3, 4, 6 }, false)]
    [InlineData(new byte[] { 2, 3, 4, 6 }, false)]
    public void HasAnyScoringDie_Matches_Whether_Any_Group_Exists(byte[] faces, bool expected)
    {
        Assert.Equal(expected, Scoring.HasAnyScoringDie(Dice(faces)));
    }
}
