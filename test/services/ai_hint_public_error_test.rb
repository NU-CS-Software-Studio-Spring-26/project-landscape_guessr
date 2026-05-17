# frozen_string_literal: true

require "test_helper"

class AiHintPublicErrorTest < ActiveSupport::TestCase
  test "quota message for HTTP 429" do
    message = AiHintPublicError.message("Gemini HTTP 429: rate limited")
    assert_includes message, "credits"
    assert_includes message, "Gemini"
    assert_not_includes message, AiHintPublicError::CREDITS_NOTE
  end

  test "generic failure includes credits note" do
    message = AiHintPublicError.message("API timeout")
    assert_includes message, "Try again"
    assert_includes message, "credits"
  end

  test "blank failure includes credits note" do
    message = AiHintPublicError.message(nil)
    assert_includes message, "credits"
  end

  test "geocode failure omits credits note" do
    message = AiHintPublicError.message("Could not geocode coordinates for hint")
    assert_includes message, "location data"
    assert_not_includes message, "credits"
  end
end
