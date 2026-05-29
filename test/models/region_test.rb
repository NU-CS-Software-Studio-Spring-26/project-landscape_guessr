require "test_helper"

# Unit tests for Region's pure (network-free) boundary helpers — the candidate
# selection and island clipping that make "streets in <City>" resolve to the
# real metropolis instead of a province-with-islands or a reverse-geocode
# sliver. The live Nominatim paths are exercised separately.
class RegionTest < ActiveSupport::TestCase
  # A small square ring around (lng, lat) of half-width `h` degrees.
  def square(lng, lat, h)
    [ [ [ lng - h, lat - h ], [ lng + h, lat - h ], [ lng + h, lat + h ], [ lng - h, lat + h ], [ lng - h, lat - h ] ] ]
  end

  # --- clip_city_boundary: the bug the evaluator caught ---

  test "clip_city_boundary keeps the central polygon containing the anchor and drops a far, LARGER island" do
    central = square(139.7, 35.7, 0.1)   # small, contains the Tokyo anchor
    island  = square(142.5, 27.0, 1.0)   # far Ogasawara-style island, much LARGER by area
    geo = { "type" => "MultiPolygon", "coordinates" => [ island, central ] }

    clipped = Region.clip_city_boundary(geo, [ 35.7, 139.7 ])
    # Area-based "keep largest" would keep the island and exclude the anchor;
    # centroid-anchored clipping must keep central, drop the island.
    assert_equal "Polygon", clipped["type"], "only the central polygon should survive"
    assert_equal central, clipped["coordinates"]
    assert Region.point_in_ring?(139.7, 35.7, clipped["coordinates"][0]), "anchor must be inside the kept polygon"
  end

  test "clip_city_boundary keeps a contiguous metro piece across water (within the gap)" do
    central = square(139.7, 35.7, 0.1)
    near    = square(139.92, 35.7, 0.05)  # ~10km east — a Chongming/Staten-Island-style piece
    far     = square(142.5, 27.0, 0.5)
    geo = { "type" => "MultiPolygon", "coordinates" => [ central, near, far ] }

    clipped = Region.clip_city_boundary(geo, [ 35.7, 139.7 ])
    assert_equal "MultiPolygon", clipped["type"]
    assert_equal 2, clipped["coordinates"].size, "central + near piece kept, far island dropped"
    assert_includes clipped["coordinates"], near
    refute_includes clipped["coordinates"], far
  end

  test "clip_city_boundary is a no-op for a single Polygon" do
    geo = { "type" => "Polygon", "coordinates" => square(2.35, 48.85, 0.1) }
    assert_equal geo, Region.clip_city_boundary(geo, [ 48.85, 2.35 ])
  end

  test "bbox_gap_km is 0 for overlap and grows with separation" do
    a = { min_lat: 35.6, max_lat: 35.8, min_lng: 139.6, max_lng: 139.8 }
    assert_equal 0.0, Region.bbox_gap_km(a, a)
    far = { min_lat: 26.0, max_lat: 28.0, min_lng: 141.5, max_lng: 143.5 }
    assert_operator Region.bbox_gap_km(a, far), :>, 500, "Ogasawara-distance gap is hundreds of km"
  end

  # --- pick_boundary_candidate: limit=5 rescue + city-over-state preference ---

  test "pick_boundary_candidate prefers a containing polygon over a leading Point" do
    city = square(10.0, 10.0, 0.1)
    features = [
      { "geometry" => { "type" => "Point", "coordinates" => [ 10.0, 10.0 ] }, "properties" => {} },
      { "geometry" => { "type" => "Polygon", "coordinates" => city }, "properties" => { "addresstype" => "city" } }
    ]
    picked = Region.pick_boundary_candidate(features, [ 10.0, 10.0 ])
    assert_equal city, picked["coordinates"], "the Point #1 must be skipped for the polygon #2 (the Istanbul/Cusco rescue)"
  end

  test "pick_boundary_candidate prefers the local city polygon over a same-name state" do
    state = { "type" => "Polygon", "coordinates" => square(10.0, 10.0, 5.0) }   # big, contains anchor
    city  = { "type" => "Polygon", "coordinates" => square(10.0, 10.0, 0.2) }   # small, contains anchor
    features = [
      { "geometry" => state, "properties" => { "addresstype" => "state" } },
      { "geometry" => city,  "properties" => { "addresstype" => "city" } }
    ]
    picked = Region.pick_boundary_candidate(features, [ 10.0, 10.0 ])
    assert_equal city["coordinates"], picked["coordinates"]
  end

  test "pick_boundary_candidate returns nil when there are no polygon candidates" do
    features = [ { "geometry" => { "type" => "Point", "coordinates" => [ 1, 1 ] }, "properties" => {} } ]
    assert_nil Region.pick_boundary_candidate(features, [ 1.0, 1.0 ])
  end
end
