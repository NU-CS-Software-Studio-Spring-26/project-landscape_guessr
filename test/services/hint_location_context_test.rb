# frozen_string_literal: true

require "test_helper"

class HintLocationContextTest < ActiveSupport::TestCase
  test "to_prompt_lines formats geocoded fields" do
    location = HintLocationContext::Location.new(
      country: "Switzerland",
      country_code: "CH",
      region: "Bern",
      city: "Interlaken",
      continent: "Europe",
      latitude_band: "Northern mid-latitudes"
    )

    lines = HintLocationContext.to_prompt_lines(location)

    assert_includes lines, "Climate band: Northern mid-latitudes"
    assert_includes lines, "Continent: Europe"
    assert_includes lines, "Country: Switzerland"
    assert_includes lines, "Region: Bern"
    assert_includes lines, "City or town: Interlaken"
  end

  test "to_prompt_lines returns nil when location is blank" do
    assert_nil HintLocationContext.to_prompt_lines(nil)
  end

  test "latitude_band classifies hemispheres" do
    assert_equal "Northern mid-latitudes", HintLocationContext.latitude_band(46.8)
    assert_equal "Tropics or subtropics", HintLocationContext.latitude_band(10)
    assert_equal "Southern mid-latitudes", HintLocationContext.latitude_band(-34)
  end
end
