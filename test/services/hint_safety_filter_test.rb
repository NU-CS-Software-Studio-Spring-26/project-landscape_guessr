# frozen_string_literal: true

require "test_helper"

class HintSafetyFilterTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @image = Image.create!(
      url: "https://example.com/hint-filter.jpg",
      latitude: 47.2692,
      longitude: 11.4041,
      title: "Golden Roof Landmark"
    )
    @location = HintLocationContext::Location.new(
      country: "Austria",
      country_code: "AT",
      region: "Tyrol",
      city: "Innsbruck",
      continent: "Europe",
      latitude_band: "Northern mid-latitudes"
    )
  end

  test "returns hint when blocklist terms are absent" do
    assert_equal "Steep alpine meadows and timber chalets.",
      HintSafetyFilter.call("Steep alpine meadows and timber chalets.", @image, tier: 2, location: @location)
  end

  test "rejects hint containing country name for all tiers" do
    assert_nil HintSafetyFilter.call("Snowy peaks typical of Austria.", @image, tier: 2, location: @location)
    assert_nil HintSafetyFilter.call("Snowy peaks typical of Austria.", @image, tier: 3, location: @location)
  end

  test "rejects hint containing continent or region for all tiers" do
    assert_nil HintSafetyFilter.call("Classic European alpine scenery.", @image, tier: 1, location: @location)
    assert_nil HintSafetyFilter.call("Think of the Tyrol valleys.", @image, tier: 3, location: @location)
  end

  test "rejection reports geographic leaks for model feedback" do
    rejection = HintSafetyFilter.rejection("Snowy peaks typical of Austria.", @image, tier: 2, location: @location)

    assert rejection.geographic?
    assert_includes rejection.matched_terms, "Austria"
    assert_includes rejection.feedback_message, "continent, country, region"
  end

  test "rejects hint containing city name for all tiers" do
    assert_nil HintSafetyFilter.call("Historic center streets near Innsbruck.", @image, tier: 3, location: @location)
  end

  test "rejects hint containing significant title tokens" do
    assert_nil HintSafetyFilter.call("Tiles like the Golden Roof style.", @image, tier: 2, location: @location)
  end

  test "significant_tokens ignores short words" do
    tokens = HintSafetyFilter.significant_tokens("The North Red Fox")
    assert_includes tokens, "north"
    assert_not_includes tokens, "the"
    assert_not_includes tokens, "red"
    assert_not_includes tokens, "fox"
  end
end
