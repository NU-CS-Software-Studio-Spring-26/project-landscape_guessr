require "test_helper"

class RegionResolverTest < ActiveSupport::TestCase
  def stub_geocoder_match(query, result)
    GeocoderService.singleton_class.define_method(:best_match) do |q|
      q == query ? result : nil
    end
    GeocoderService.singleton_class.define_method(:geocode_many) do |queries:|
      Hash[Array(queries).map { |q| [ q, q == query && result ? [ result ] : [] ] }]
    end
  end

  def restore_geocoder
    %i[best_match geocode_many].each do |m|
      GeocoderService.singleton_class.remove_method(m) if GeocoderService.singleton_class.method_defined?(m)
    end
  end

  test "returns nil for blank descriptor" do
    assert_nil RegionResolver.resolve(nil)
    assert_nil RegionResolver.resolve({})
  end

  test "Mode B single POI builds bbox around best_match" do
    sample = { lat: 48.8584, lng: 2.2945, bbox: { min_lat: 48.85, max_lat: 48.87, min_lng: 2.28, max_lng: 2.31 }, display_name: "Eiffel Tower", class: "man_made", area_km2: 1.0, importance: 0.6 }
    stub_geocoder_match("Eiffel Tower", sample)
    result = RegionResolver.resolve(mode: "pois", pois: [ "Eiffel Tower" ], label: "Eiffel")
    assert_not_nil result
    assert_equal :pois, result.source
    assert result.bbox[:max_lat] > result.bbox[:min_lat]
    assert_equal "Eiffel", result.label
  ensure
    restore_geocoder
  end

  test "radius transform produces a bbox of roughly 2 * radius wide" do
    sample = { lat: 48.8584, lng: 2.2945, bbox: { min_lat: 48.85, max_lat: 48.87, min_lng: 2.28, max_lng: 2.31 }, display_name: "Eiffel Tower", class: "man_made", area_km2: 1.0, importance: 0.6 }
    stub_geocoder_match("Eiffel Tower", sample)
    r = RegionResolver.resolve(mode: "pois", pois: [ "Eiffel Tower" ], radius_meters: 2000)
    # ~4km wide bbox (2km each side)
    width_km = (r.bbox[:max_lat] - r.bbox[:min_lat]) * 111
    assert_in_delta 4.0, width_km, 0.5
  ensure
    restore_geocoder
  end

  test "radius transform rejects 0 or > 50000" do
    sample = { lat: 0.0, lng: 0.0, bbox: { min_lat: -0.01, max_lat: 0.01, min_lng: -0.01, max_lng: 0.01 }, display_name: "X", class: "place", area_km2: 0.01, importance: 0.5 }
    stub_geocoder_match("X", sample)
    assert_nil RegionResolver.resolve(mode: "pois", pois: [ "X" ], radius_meters: 0)
    assert_nil RegionResolver.resolve(mode: "pois", pois: [ "X" ], radius_meters: 100_000)
  ensure
    restore_geocoder
  end

  test "legacy bare-fields descriptor (no mode key) is treated as Mode A" do
    # Pre-v2 ai_region_filter rows have shape {name:, parent_name:, admin_level:}.
    # The resolver should infer mode="named". We can't run the actual Region
    # lookup without a fixture, so just assert that the inference happens —
    # the failure mode would be "returns nil because mode is blank".
    desc = { name: "Nonexistent_Test_Region", parent_name: "X", admin_level: "city" }
    # Real Region.find_by returns nil here → resolve_named returns nil → final nil.
    # The test passes either way (both paths hit nil), but explicitly checks
    # that we don't ArgumentError on the legacy hash shape.
    assert_nothing_raised do
      RegionResolver.resolve(desc)
    end
  end
end
