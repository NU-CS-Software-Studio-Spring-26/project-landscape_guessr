require "test_helper"

class GuessTest < ActiveSupport::TestCase
  test "belongs to game" do
    assert_equal :belongs_to, Guess.reflect_on_association(:game).macro
  end

  test "belongs to image" do
    assert_equal :belongs_to, Guess.reflect_on_association(:image).macro
  end

  test "fixture is valid" do
    guess = guesses(:one)
    assert guess.game.present?
    assert guess.image.present?
    assert guess.latitude.present?
    assert guess.longitude.present?
  end

  test "guess references correct game and image" do
    guess = guesses(:one)
    assert_equal games(:one), guess.game
    assert_equal images(:one), guess.image
  end
end
