require "test_helper"

class ImageTest < ActiveSupport::TestCase
  test "has many guesses" do
    assert_equal :has_many, Image.reflect_on_association(:guesses).macro
  end

  test "destroying image destroys its guesses" do
    image = images(:one)
    guess_count = image.guesses.count
    assert guess_count > 0
    assert_difference("Guess.count", -guess_count) { image.destroy }
  end

  test "fixture is valid" do
    image = images(:one)
    assert image.url.present?
    assert image.latitude.present?
    assert image.longitude.present?
    assert image.title.present?
  end
end
