require "test_helper"

class AiPromptValidatorTest < ActiveSupport::TestCase
  test "accepts a normal prompt" do
    result = AiPromptValidator.validate("  waterfalls in Norway  ")
    assert result.ok?
    assert_equal "waterfalls in Norway", result.text
  end

  test "rejects blank prompt" do
    result = AiPromptValidator.validate("   ")
    refute result.ok?
    assert_match(/Type a prompt first/i, result.error)
  end

  test "rejects prompts over 250 characters" do
    result = AiPromptValidator.validate("a" * 251)
    refute result.ok?
    assert_match(/250 characters/i, result.error)
  end

  test "accepts prompt at exactly 250 characters" do
    result = AiPromptValidator.validate("a" * 250)
    assert result.ok?
    assert_equal 250, result.text.length
  end

  test "rejects control characters" do
    result = AiPromptValidator.validate("volcanoes\x07 in Japan")
    refute result.ok?
    assert_match(/invalid characters/i, result.error)
  end

  test "rejects invisible unicode smuggling characters" do
    result = AiPromptValidator.validate("volcanoes\u200Bin Japan")
    refute result.ok?
    assert_match(/invalid characters/i, result.error)
  end

  test "rejects HTML and script markup" do
    result = AiPromptValidator.validate('<script>alert("x")</script> castles')
    refute result.ok?
    assert_match(/markup/i, result.error)
  end

  test "rejects profanity" do
    result = AiPromptValidator.validate("fucking volcanoes in Japan")
    refute result.ok?
    assert_match(/family-friendly/i, result.error)
  end

  test "rejects leetspeak profanity" do
    result = AiPromptValidator.validate("sh1t volcanoes")
    refute result.ok?
    assert_match(/family-friendly/i, result.error)
  end
end
