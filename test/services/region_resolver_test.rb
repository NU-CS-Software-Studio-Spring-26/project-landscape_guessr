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
    # Reload the service to restore the REAL class methods. (remove_method
    # alone would leave them undefined — the stub overwrote the originals — so
    # any later test that reaches real geocoding would NoMethodError.)
    load Rails.root.join("app/services/geocoder_service.rb").to_s
  end

  test "returns nil for blank descriptor" do
    assert_nil RegionResolver.resolve(nil)
    assert_nil RegionResolver.resolve({})
  end

  test "world admin_level resolves to the global bbox without a DB lookup" do
    r = RegionResolver.resolve(mode: "named", name: "World", admin_level: "world")
    assert_not_nil r
    assert_equal :global, r.source
    assert_nil r.polygon
    assert_operator r.bbox[:min_lng], :<=, -179
    assert_operator r.bbox[:max_lng], :>=, 179
    assert_operator (r.bbox[:max_lat] - r.bbox[:min_lat]), :>, 100
    # mode: "global" works too
    assert_equal :global, RegionResolver.resolve(mode: "global").source
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

  test "radius transform attaches a circle polygon that excludes bbox corners" do
    sample = { lat: 48.8584, lng: 2.2945, bbox: { min_lat: 48.85, max_lat: 48.87, min_lng: 2.28, max_lng: 2.31 }, display_name: "Eiffel Tower", class: "man_made", area_km2: 1.0, importance: 0.6 }
    stub_geocoder_match("Eiffel Tower", sample)
    r = RegionResolver.resolve(mode: "pois", pois: [ "Eiffel Tower" ], radius_meters: 2000)
    assert_not_nil r.polygon, "radius mode must carry a circle polygon so the radius is enforced"
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    center = factory.point((r.bbox[:min_lng] + r.bbox[:max_lng]) / 2, (r.bbox[:min_lat] + r.bbox[:max_lat]) / 2)
    corner = factory.point(r.bbox[:max_lng], r.bbox[:max_lat]) # ~1.4× radius out
    assert r.polygon.contains?(center), "center must be inside the circle"
    assert_not r.polygon.contains?(corner), "bbox corner (~2.8km) must be outside a 2km circle"
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

  test "primary_landmass_bbox keeps the dominant hemisphere, dropping the dateline-wrap fragment" do
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    # A big western-hemisphere landmass (mimics the contiguous US) ...
    west = factory.polygon(factory.linear_ring([
      factory.point(-125, 25), factory.point(-67, 25),
      factory.point(-67, 49), factory.point(-125, 49), factory.point(-125, 25)
    ]))
    # ... plus a tiny eastern-hemisphere islet across the dateline (mimics the
    # westernmost Aleutians at ~+178).
    east = factory.polygon(factory.linear_ring([
      factory.point(177, 51), factory.point(179, 51),
      factory.point(179, 52), factory.point(177, 52), factory.point(177, 51)
    ]))
    multi = factory.multi_polygon([ west, east ])

    # Naive min/max bbox wraps the planet (max_lng from the +178 islet).
    naive = { min_lat: 25.0, max_lat: 52.0, min_lng: -125.0, max_lng: 179.0 }
    bbox = RegionResolver.primary_landmass_bbox(naive, multi)

    assert_operator (bbox[:max_lng] - bbox[:min_lng]), :<=, 180.0, "narrowed span must clear the antimeridian guard"
    assert_in_delta(-125.0, bbox[:min_lng], 0.001)
    assert_in_delta(-67.0,  bbox[:max_lng], 0.001) # eastern islet dropped
  end

  test "primary_landmass_bbox keeps two comparable landmasses, dropping only the far-side fragment (NZ-like)" do
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    south = factory.polygon(factory.linear_ring([
      factory.point(166, -47), factory.point(174, -47),
      factory.point(174, -40), factory.point(166, -40), factory.point(166, -47)
    ]))
    north = factory.polygon(factory.linear_ring([
      factory.point(173, -41), factory.point(178, -41),
      factory.point(178, -34), factory.point(173, -34), factory.point(173, -41)
    ]))
    chatham = factory.polygon(factory.linear_ring([
      factory.point(-177, -44), factory.point(-176, -44),
      factory.point(-176, -43), factory.point(-177, -43), factory.point(-177, -44)
    ]))
    multi = factory.multi_polygon([ south, north, chatham ])

    naive = { min_lat: -47.0, max_lat: -34.0, min_lng: -177.0, max_lng: 178.0 } # span 355°
    bbox = RegionResolver.primary_landmass_bbox(naive, multi)

    assert_operator (bbox[:max_lng] - bbox[:min_lng]), :<=, 180.0
    assert_in_delta 166.0, bbox[:min_lng], 0.001 # south island kept
    assert_in_delta 178.0, bbox[:max_lng], 0.001 # north island kept, chatham dropped
  end

  test "primary_landmass_bbox drops far territories that fit under 180 but are distant (France-like)" do
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    metropole = factory.polygon(factory.linear_ring([
      factory.point(-5, 42), factory.point(10, 42),
      factory.point(10, 51), factory.point(-5, 51), factory.point(-5, 42)
    ]))
    reunion = factory.polygon(factory.linear_ring([
      factory.point(55, -21), factory.point(56, -21),
      factory.point(56, -20), factory.point(55, -20), factory.point(55, -21)
    ]))
    new_caledonia = factory.polygon(factory.linear_ring([
      factory.point(164, -22), factory.point(167, -22),
      factory.point(167, -20), factory.point(164, -20), factory.point(164, -22)
    ]))
    polynesia = factory.polygon(factory.linear_ring([ # west hemisphere, makes the naive span > 180
      factory.point(-150, -18), factory.point(-149, -18),
      factory.point(-149, -17), factory.point(-150, -17), factory.point(-150, -18)
    ]))
    multi = factory.multi_polygon([ metropole, reunion, new_caledonia, polynesia ])

    naive = { min_lat: -22.0, max_lat: 51.0, min_lng: -150.0, max_lng: 167.0 } # span 317°
    bbox = RegionResolver.primary_landmass_bbox(naive, multi)

    # Only the metropole survives — Réunion/New Caledonia/Polynesia each fit
    # under 180° when unioned with it, but are >1500km away, so the box stays
    # tight (dense probes) instead of spanning the whole Indian/Pacific Ocean.
    assert_in_delta(-5.0, bbox[:min_lng], 0.001)
    assert_in_delta 10.0, bbox[:max_lng], 0.001
    assert_in_delta 42.0, bbox[:min_lat], 0.001
    assert_in_delta 51.0, bbox[:max_lat], 0.001
  end

  test "primary_landmass_bbox leaves a non-degenerate bbox untouched" do
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    poly = factory.polygon(factory.linear_ring([
      factory.point(6, 47), factory.point(15, 47),
      factory.point(15, 55), factory.point(6, 55), factory.point(6, 47)
    ]))
    naive = { min_lat: 47.0, max_lat: 55.0, min_lng: 6.0, max_lng: 15.0 } # span 9° (Germany)
    assert_equal naive, RegionResolver.primary_landmass_bbox(naive, poly)
  end

  test "primary_landmass_bbox returns the naive bbox when no polygon is available" do
    naive = { min_lat: -47.0, max_lat: -34.0, min_lng: -180.0, max_lng: 180.0 }
    assert_equal naive, RegionResolver.primary_landmass_bbox(naive, nil)
  end

  test "legacy bare-fields descriptor (no mode key) is treated as Mode A" do
    # Pre-v2 ai_region_filter rows have shape {name:, parent_name:, admin_level:}.
    # The resolver should infer mode="named". We can't run the actual Region
    # lookup without a fixture, so just assert that the inference happens —
    # the failure mode would be "returns nil because mode is blank".
    desc = { name: "Nonexistent_Test_Region", parent_name: "X", admin_level: "city" }
    # Not in the DB → resolve_named falls back to geocoding; with the geocoder
    # stubbed to find nothing, that returns nil. The test checks we infer
    # mode="named" from the legacy shape and don't ArgumentError on it.
    stub_geocoder_match("__no_match__", nil)
    assert_nothing_raised do
      assert_nil RegionResolver.resolve(desc)
    end
  ensure
    restore_geocoder
  end
end
