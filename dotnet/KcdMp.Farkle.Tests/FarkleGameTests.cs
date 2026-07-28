namespace KcdMp.Farkle.Tests;

public class FarkleGameTests
{
    private static FarkleGame NewGame(int firstPlayer, params int[] rolls) =>
        new(new FakeDiceRng(rolls), targetScore: 4000, firstPlayer: firstPlayer);

    [Fact]
    public void First_Player_Comes_From_The_Injected_Rng()
    {
        var rng = new FakeDiceRng(1); // Next(0,2) call for first-player pick
        var game = new FarkleGame(rng);
        Assert.Equal(1, game.CurrentPlayer);
    }

    [Fact]
    public void Roll_With_No_Scoring_Die_Busts_And_Passes_Turn()
    {
        var game = NewGame(firstPlayer: 0, rolls: [2, 2, 3, 3, 4, 6]);

        var result = game.Roll(0);

        Assert.True(result.Accepted);
        Assert.True(result.Busted);
        Assert.Equal(0, game.TurnTotal);
        Assert.Equal(1, game.CurrentPlayer);
        Assert.Equal(TurnPhase.AwaitingRoll, game.Phase);
    }

    [Fact]
    public void Roll_With_A_Scoring_Die_Moves_To_AwaitingKeep()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);

        var result = game.Roll(0);

        Assert.True(result.Accepted);
        Assert.False(result.Busted);
        Assert.Equal(TurnPhase.AwaitingKeep, game.Phase);
        Assert.Equal(6, game.FreeDice.Count);
    }

    [Fact]
    public void Keep_Accumulates_TurnTotal_And_Returns_To_AwaitingRoll()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Keep(0, mask: 0b000001); // the single 1

        Assert.True(result.Accepted);
        Assert.Equal(100, game.TurnTotal);
        Assert.Equal(TurnPhase.AwaitingRoll, game.Phase);
        Assert.Single(game.KeptDiceThisTurn);
    }

    [Fact]
    public void Keep_Selecting_A_NonScoring_Die_Is_Rejected_And_State_Is_Unchanged()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Keep(0, mask: 0b000011); // the 1 plus a lone 2

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.InvalidKeepSelection, result.RejectReason);
        Assert.Equal(0, game.TurnTotal);
        Assert.Equal(TurnPhase.AwaitingKeep, game.Phase); // still waiting on a valid Keep
    }

    [Fact]
    public void Keep_With_Empty_Mask_Is_Rejected()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Keep(0, mask: 0);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.EmptyKeep, result.RejectReason);
    }

    [Fact]
    public void Keep_With_A_Mask_Bit_Beyond_The_Rolled_Dice_Is_Rejected()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Keep(0, mask: 1 << 6); // only 6 dice (bits 0-5) were rolled

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.KeepIndexOutOfRange, result.RejectReason);
    }

    [Fact]
    public void Hot_Dice_Returns_All_Six_And_Turn_Continues()
    {
        // Roll six 1s (all scoring), keep all six -> hot dice.
        var game = NewGame(firstPlayer: 0, rolls: [1, 1, 1, 1, 1, 1]);
        game.Roll(0);

        var result = game.Keep(0, mask: 0b111111);

        Assert.True(result.Accepted);
        Assert.True(result.HotDice);
        Assert.Equal(8000, game.TurnTotal); // six of a kind on 1s
        Assert.Empty(game.KeptDiceThisTurn); // reset by the hot-dice roll-over
        Assert.Equal(TurnPhase.AwaitingRoll, game.Phase);
        Assert.Equal(0, game.CurrentPlayer); // still this player's turn
    }

    [Fact]
    public void Hot_Dice_Can_Span_Multiple_Keeps_In_One_Turn()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 3, 4, 6, 6, /* remainder roll */ 5, 5, 5, 5, 5]);
        game.Roll(0); // 1,2,3,4,6,6 -- only the lone 1 scores

        var firstKeep = game.Keep(0, mask: 0b000001);
        Assert.False(firstKeep.HotDice);
        Assert.Equal(100, game.TurnTotal);

        game.Roll(0); // remaining 5 dice come back as five 5s
        var secondKeep = game.Keep(0, mask: 0b11111);

        Assert.True(secondKeep.HotDice); // 1 + 5 = 6 dice kept across two Keep calls
        Assert.Equal(100 + 2000, game.TurnTotal); // single 1, then five-of-a-kind 5s
        Assert.Empty(game.KeptDiceThisTurn);
        Assert.Equal(TurnPhase.AwaitingRoll, game.Phase);
    }

    [Fact]
    public void Roll_Out_Of_Turn_Is_Rejected()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 3, 4, 5, 6]);

        var result = game.Roll(1);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.NotYourTurn, result.RejectReason);
    }

    [Fact]
    public void Keep_Out_Of_Turn_Is_Rejected()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Keep(1, mask: 0b1);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.NotYourTurn, result.RejectReason);
    }

    [Fact]
    public void Bank_Out_Of_Turn_Is_Rejected()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);
        game.Keep(0, mask: 0b1);

        var result = game.Bank(1);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.NotYourTurn, result.RejectReason);
    }

    [Fact]
    public void Keep_Before_Rolling_Is_Rejected_As_Wrong_Phase()
    {
        var game = NewGame(firstPlayer: 0);

        var result = game.Keep(0, mask: 0b1);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.WrongPhase, result.RejectReason);
    }

    [Fact]
    public void Roll_While_AwaitingKeep_Is_Rejected_As_Wrong_Phase()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Roll(0);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.WrongPhase, result.RejectReason);
    }

    [Fact]
    public void Bank_While_AwaitingKeep_Is_Rejected_As_Wrong_Phase()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);

        var result = game.Bank(0);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.WrongPhase, result.RejectReason);
    }

    [Fact]
    public void Bank_With_Zero_TurnTotal_Is_Rejected()
    {
        var game = NewGame(firstPlayer: 0);

        var result = game.Bank(0);

        Assert.False(result.Accepted);
        Assert.Equal(IntentRejectReason.NothingToBank, result.RejectReason);
    }

    [Fact]
    public void Bank_Adds_TurnTotal_To_Score_And_Passes_The_Turn()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0);
        game.Keep(0, mask: 0b1);

        var result = game.Bank(0);

        Assert.True(result.Accepted);
        Assert.False(result.GameEnded);
        Assert.Equal(100, game.Scores[0]);
        Assert.Equal(0, game.TurnTotal);
        Assert.Equal(1, game.CurrentPlayer);
    }

    [Fact]
    public void Reaching_The_Target_On_Bank_Ends_The_Game_Immediately()
    {
        var game = new FarkleGame(new FakeDiceRng([1, 1, 1, 1, 1, 1]), targetScore: 500, firstPlayer: 0);
        game.Roll(0);

        var bankResult = game.Bank(0); // still AwaitingKeep, must Keep first
        Assert.False(bankResult.Accepted);

        var keep = game.Keep(0, mask: 0b111111); // six 1s = 8000, plus hot dice
        Assert.True(keep.HotDice);

        var result = game.Bank(0);

        Assert.True(result.Accepted);
        Assert.True(result.GameEnded);
        Assert.Equal(FarkleOutcome.Player0Won, game.Outcome);
        Assert.Equal(8000, game.Scores[0]);
    }

    [Fact]
    public void Actions_After_Game_Over_Are_Rejected()
    {
        var game = new FarkleGame(new FakeDiceRng([1, 1, 1, 1, 1, 1]), targetScore: 100, firstPlayer: 0);
        game.Roll(0);
        game.Keep(0, mask: 0b111111);
        game.Bank(0);
        Assert.Equal(FarkleOutcome.Player0Won, game.Outcome);

        Assert.Equal(IntentRejectReason.GameAlreadyOver, game.Roll(1).RejectReason);
        Assert.Equal(IntentRejectReason.GameAlreadyOver, game.Bank(0).RejectReason);
        Assert.Equal(IntentRejectReason.GameAlreadyOver, game.Forfeit(0).RejectReason);
    }

    [Fact]
    public void Forfeit_Ends_The_Game_In_The_Other_Players_Favour_Regardless_Of_Turn()
    {
        var game = NewGame(firstPlayer: 0);

        var result = game.Forfeit(0);

        Assert.True(result.Accepted);
        Assert.True(result.GameEnded);
        Assert.Equal(FarkleOutcome.Player1Won, game.Outcome);
    }

    [Fact]
    public void Forfeit_Works_Mid_Turn_Without_Needing_To_Be_The_Actors_Turn()
    {
        var game = NewGame(firstPlayer: 0, rolls: [1, 2, 2, 3, 4, 6]);
        game.Roll(0); // player 0's turn, AwaitingKeep

        var result = game.Forfeit(1); // player 1 concedes even though it's not their turn

        Assert.True(result.Accepted);
        Assert.Equal(FarkleOutcome.Player0Won, game.Outcome);
    }
}
