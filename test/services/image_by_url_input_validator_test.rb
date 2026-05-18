require "test_helper"

class ImageByUrlInputValidatorTest < ActiveSupport::TestCase
  def valid_params(overrides = {})
    {
      url:       "https://upload.wikimedia.org/wikipedia/commons/a/ab/Example.jpg",
      title:     "Alpine lake",
      latitude:  "47.5",
      longitude: "8.5"
    }.merge(overrides)
  end

  test "accepts valid https URL with coordinates and title" do
    result = ImageByUrlInputValidator.validate(valid_params)
    assert result.ok?
    assert_match(/\Ahttps:\/\//, result.url)
    assert_equal "Alpine lake", result.title
    assert_in_delta 47.5, result.latitude
    assert_in_delta 8.5, result.longitude
  end

  test "defaults blank title to Untitled" do
    result = ImageByUrlInputValidator.validate(valid_params(title: ""))
    assert result.ok?
    assert_equal "Untitled", result.title
  end

  test "rejects empty URL" do
    result = ImageByUrlInputValidator.validate(valid_params(url: ""))
    refute result.ok?
    assert_match(/enter an image URL/i, result.error)
  end

  test "rejects http URL" do
    result = ImageByUrlInputValidator.validate(valid_params(url: "http://example.com/x.jpg"))
    refute result.ok?
    assert_match(/https/i, result.error)
  end

  test "rejects javascript URL" do
    result = ImageByUrlInputValidator.validate(valid_params(url: "javascript:alert(1)"))
    refute result.ok?
    assert_match(/https/i, result.error)
  end

  test "rejects URL over max length" do
    result = ImageByUrlInputValidator.validate(valid_params(url: "https://example.com/#{'a' * 500}"))
    refute result.ok?
    assert_match(/500 characters/i, result.error)
  end

  test "rejects missing latitude" do
    result = ImageByUrlInputValidator.validate(valid_params(latitude: ""))
    refute result.ok?
    assert_match(/required/i, result.error)
  end

  test "rejects missing longitude" do
    result = ImageByUrlInputValidator.validate(valid_params(longitude: ""))
    refute result.ok?
    assert_match(/required/i, result.error)
  end

  test "rejects non-numeric latitude" do
    result = ImageByUrlInputValidator.validate(valid_params(latitude: "north"))
    refute result.ok?
    assert_match(/Latitude must be a number/i, result.error)
  end

  test "rejects latitude out of range" do
    result = ImageByUrlInputValidator.validate(valid_params(latitude: "95"))
    refute result.ok?
    assert_match(/between -90 and 90/i, result.error)
  end

  test "rejects longitude out of range" do
    result = ImageByUrlInputValidator.validate(valid_params(longitude: "200"))
    refute result.ok?
    assert_match(/between -180 and 180/i, result.error)
  end

  test "rejects invalid title characters" do
    result = ImageByUrlInputValidator.validate(valid_params(title: "<script>"))
    refute result.ok?
    assert_match(/Title/i, result.error)
  end
end
