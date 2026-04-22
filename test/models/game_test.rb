require "test_helper"

class GameTest < ActiveSupport::TestCase
  test "has many guesses" do
    assert_equal :has_many, Game.reflect_on_association(:guesses).macro
  end

  test "has many images through guesses" do
    assert_equal :has_many, Game.reflect_on_association(:images).macro
  end

  test "destroying game destroys its guesses" do
    game = games(:one)
    guess_count = game.guesses.count
    assert guess_count > 0
    assert_difference("Guess.count", -guess_count) { game.destroy }
  end

  test "new game can be created with in_progress status" do
    game = Game.create!(status: "in_progress")
    assert_equal "in_progress", game.status
    assert_nil game.score
    assert_nil game.completed_at
  end
end
