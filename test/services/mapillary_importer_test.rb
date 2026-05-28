require "test_helper"

# Unit tests for MapillaryImporter's pure (network-free) helpers — the tile
# spreading and feature thinning that keep large imports distributed instead
# of clustered. The network paths (count/import!) are exercised live.
class MapillaryImporterTest < ActiveSupport::TestCase
  # A wide bbox so the z=14 tile range is large.
  BBOX = { min_lat: 44.13, max_lat: 45.10, min_lng: -111.15, max_lng: -109.83 }.freeze

  test "spread_sample_tiles caps at budget and spans the tile range" do
    x_lo, x_hi, y_lo, y_hi = Mapillary::TileDecoder.tile_range(BBOX, 14)
    # A dense block of covered tiles clustered in one corner plus a few far ones.
    covered = []
    (x_lo..x_lo + 5).each { |x| (y_lo..y_lo + 5).each { |y| covered << [ x, y ] } }
    covered << [ x_hi, y_hi ] << [ x_hi, y_lo ] << [ x_lo, y_hi ]

    picked = MapillaryImporter.spread_sample_tiles(covered, 16, BBOX)
    assert picked.size <= 16, "must not exceed budget"
    assert_equal picked.uniq.size, picked.size, "tiles must be unique"
    # The far corners should be reachable — spreading shouldn't keep only the
    # dense corner block.
    xs = picked.map(&:first)
    assert (xs.max - xs.min) > (x_hi - x_lo) * 0.5, "picked tiles should span the x range"
  end

  test "spatial_thin caps total and limits per-cell density" do
    # 300 features all in one z=14 tile (a single dense drive-cluster) + 5 spread.
    base_lat = 44.5
    base_lng = -110.5
    dense = Array.new(300) { |i| { id: "d#{i}", lat: base_lat + i * 1e-6, lng: base_lng + i * 1e-6 } }
    spread = Array.new(5) { |i| { id: "s#{i}", lat: 44.2 + i * 0.1, lng: -111.0 + i * 0.1 } }

    thinned = MapillaryImporter.spatial_thin(dense + spread, 50)
    assert thinned.size <= 50, "must respect max_features"
    # The dense cluster must not dominate: each ~2.4km cell keeps a bounded share.
    by_cell = thinned.group_by { |f| Mapillary::TileDecoder.lonlat_to_tile(f[:lng], f[:lat], 14) }
    assert by_cell.size >= 5, "spread features should survive across multiple cells"
  end

  test "spatial_thin is a no-op under the cap" do
    feats = Array.new(10) { |i| { id: i.to_s, lat: 44.0 + i, lng: -110.0 } }
    assert_equal feats, MapillaryImporter.spatial_thin(feats, 50)
  end
end
