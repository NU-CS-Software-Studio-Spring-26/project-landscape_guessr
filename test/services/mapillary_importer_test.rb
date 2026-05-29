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

  test "spread_sample_tiles fills the budget when coverage is concentrated (the Beijing bug)" do
    # 220 covered tiles bunched in one corner of a wide bbox, budget 60. The old
    # one-tile-per-grid-cell logic collapsed this to a handful (the cluster fell
    # in ~1 grid cell) — the "Beijing returns 391 images" bug. Round-robin fill
    # must use the whole budget while still drawing from the covered tiles.
    x_lo, _x_hi, y_lo, _y_hi = Mapillary::TileDecoder.tile_range(BBOX, 14)
    covered = []
    (0...20).each { |dx| (0...11).each { |dy| covered << [ x_lo + dx, y_lo + dy ] } }
    picked = MapillaryImporter.spread_sample_tiles(covered, 60, BBOX)
    assert_equal 60, picked.size, "must fill the budget from concentrated coverage, not collapse to a few"
    assert_equal picked.uniq.size, picked.size, "tiles must be unique"
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

  # The overview tier is what fixes "streets around the world" (the z14 image
  # layer doesn't exist below z14, so continent/world scale needs the z4/5
  # `overview` layer). A city must NOT trip it (overview is far too sparse for
  # one city — ~90 pts), but the world / a huge country must.
  test "use_overview? is false for a city/metro bbox, true for world/continent" do
    tokyo_metro = { min_lat: 35.5, max_lat: 35.9, min_lng: 139.5, max_lng: 139.95 }
    assert_not MapillaryImporter.use_overview?(tokyo_metro), "a single metro stays on the z14 image layer"

    world = { min_lat: -58.0, max_lat: 74.0, min_lng: -180.0, max_lng: 180.0 }
    assert MapillaryImporter.use_overview?(world), "the whole world must use the overview layer"

    # A huge country (USA-ish span incl. Alaska) also crosses into overview.
    usa = { min_lat: 18.0, max_lat: 71.5, min_lng: -179.0, max_lng: -66.0 }
    assert MapillaryImporter.use_overview?(usa), "a huge country uses the overview layer"
  end

  test "overview_zoom prefers z5 for a country but drops to z4 for the world" do
    sweden = { min_lat: 55.0, max_lat: 69.1, min_lng: 11.0, max_lng: 24.2 }
    assert_equal MapillaryImporter::OVERVIEW_MAX_ZOOM, MapillaryImporter.overview_zoom(sweden)

    world = { min_lat: -58.0, max_lat: 74.0, min_lng: -180.0, max_lng: 180.0 }
    assert_equal MapillaryImporter::OVERVIEW_MIN_ZOOM, MapillaryImporter.overview_zoom(world)
  end
end
