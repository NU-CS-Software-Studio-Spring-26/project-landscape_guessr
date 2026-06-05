require "test_helper"
require "geo/hex_lattice"

class Geo::HexLatticeTest < ActiveSupport::TestCase
  # A city-sized bbox stays a fine 30km lattice (no radius scaling).
  test "small bbox keeps the base radius and full coverage" do
    bbox = { min_lat: 40.5, max_lat: 41.0, min_lng: -74.3, max_lng: -73.7 }
    probes = Geo::HexLattice.probes_for_bbox(bbox, radius_km: 30, max_probes: 200)
    assert_operator probes.size, :>=, 1
    assert(probes.all? { |p| p[:radius_km] == 30 }, "small region must keep the 30km probe radius")
  end

  # The regression: a continent-sized bbox must spread probes across the FULL
  # latitude range, not strand them in the bottom rows. Before the fix the US
  # bbox's first row alone exceeded max_probes, so every probe sat at the
  # southern edge and the interior never got one.
  test "continent-sized bbox spreads probes across the whole bbox and scales the radius" do
    # US-like degenerate-then-narrowed bbox: very wide and tall.
    bbox = { min_lat: -14.8, max_lat: 71.6, min_lng: -180.0, max_lng: -64.4 }
    probes = Geo::HexLattice.probes_for_bbox(bbox, radius_km: 30, max_probes: 200)

    assert_operator probes.size, :<=, 200
    assert_operator probes.size, :>=, 100, "should fill close to the budget"
    # Radius scaled up so the circles tile the huge bbox.
    assert_operator probes.first[:radius_km], :>, 100, "radius must scale up for a continent"

    lats = probes.map { |p| p[:lat] }
    span = bbox[:max_lat] - bbox[:min_lat]
    # Probes must reach both the southern AND northern thirds — not bunch at the
    # bottom. (The bug left every probe within one row of min_lat.)
    assert(lats.any? { |l| l > bbox[:min_lat] + span * 0.66 }, "probes must reach the northern third")
    assert(lats.any? { |l| l < bbox[:min_lat] + span * 0.34 }, "probes must reach the southern third")
  end
end
