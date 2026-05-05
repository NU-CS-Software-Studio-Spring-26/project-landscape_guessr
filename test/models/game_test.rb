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
    game = users(:alice).games.create!(status: "in_progress")
    assert_equal "in_progress", game.status
    assert_nil game.score
    assert_nil game.completed_at
  end

  test "belongs to a user" do
    assert_equal :belongs_to, Game.reflect_on_association(:user).macro
  end

  test "leaderboard scope filters to a single image_set" do
    set_a = ImageSet.create!(name: "Set A", visibility: "public")
    set_b = ImageSet.create!(name: "Set B", visibility: "public")
    game_a = users(:alice).games.create!(status: "completed", score: 1000, completed_at: Time.current, image_set: set_a)
    users(:bob).games.create!(status: "completed", score: 9999, completed_at: Time.current, image_set: set_b)

    results = Game.leaderboard(image_set: set_a).to_a
    assert_includes results, game_a
    assert_equal 1, results.size, "leaderboard for set A should only include games on set A"
  end

  test "leaderboard excludes incomplete games" do
    set = ImageSet.create!(name: "Set", visibility: "public")
    users(:alice).games.create!(status: "in_progress", image_set: set)
    completed = users(:bob).games.create!(status: "completed", score: 100, completed_at: Time.current, image_set: set)

    assert_equal [ completed ], Game.leaderboard(image_set: set).to_a
  end
end
