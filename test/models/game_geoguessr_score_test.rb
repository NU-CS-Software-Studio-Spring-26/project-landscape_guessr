# Scoring unit tests without test_helper to avoid loading DB fixtures (see test_helper `fixtures :all`
# and PostgreSQL FK insert order when RI cannot be disabled).
require_relative "../../config/environment"
require "minitest/autorun"

class GameGeoguessrScoreTest < Minitest::Test
  def test_perfect_guess_scores_max_points
    assert_equal 5000, Game.geoguessr_round_score(0)
  end

  def test_one_decay_length_in_metres_gives_exp_neg_one_times_max_rounded
    km = Game::GEOGUESSR_DECAY_METERS / 1000.0
    assert_equal 1839, Game.geoguessr_round_score(km)
  end

  def test_score_decreases_with_distance_and_stays_bounded
    near = Game.geoguessr_round_score(10)
    far = Game.geoguessr_round_score(5000)
    assert_operator near, :>, far
    assert_operator far, :>=, 0
    assert_operator near, :<=, Game::GEOGUESSR_MAX_ROUND_SCORE
  end

  def test_extreme_distance_rounds_to_zero
    assert_equal 0, Game.geoguessr_round_score(20_000)
  end
end
