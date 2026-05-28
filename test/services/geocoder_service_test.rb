require "test_helper"

class GeocoderServiceTest < ActiveSupport::TestCase
  test "bbox_area_km2 returns ~0 for point bbox" do
    bbox = { min_lat: 41.0, max_lat: 41.0, min_lng: -87.0, max_lng: -87.0 }
    assert_in_delta 0.0, GeocoderService.bbox_area_km2(bbox), 0.001
  end

  test "bbox_area_km2 returns roughly 1 deg² ≈ 12000 km² at the equator" do
    bbox = { min_lat: 0.0, max_lat: 1.0, min_lng: 0.0, max_lng: 1.0 }
    area = GeocoderService.bbox_area_km2(bbox)
    # cos(0.5°) ≈ 1, so area ≈ 111 * 111 = 12321 km²
    assert_in_delta 12_321, area, 50
  end

  test "score combines importance + class bonus" do
    eiffel_paris = { class: "man_made", importance: 0.62 }
    eiffel_alberta = { class: "natural", importance: 0.16 }
    # man_made has no bonus, natural has +0.05 — but the importance gap is
    # 0.46, so Paris still wins handily.
    assert GeocoderService.score(eiffel_paris) > GeocoderService.score(eiffel_alberta)
  end

  test "boundary class gets +0.3 bonus over the same-importance plain class" do
    boundary = { class: "boundary", importance: 0.5 }
    plain    = { class: "other",    importance: 0.5 }
    assert_in_delta 0.30, GeocoderService.score(boundary) - GeocoderService.score(plain), 0.01
  end

  test "deprioritized classes get a small negative" do
    railway = { class: "railway", importance: 0.5 }
    plain   = { class: "other",   importance: 0.5 }
    assert GeocoderService.score(railway) < GeocoderService.score(plain)
  end
end
