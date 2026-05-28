require "test_helper"

class MapillaryTileDecoderTest < ActiveSupport::TestCase
  test "lonlat_to_tile + tile_to_latlng round-trip within 1 pixel" do
    lat, lng = 41.8781, -87.6298  # Chicago
    z = 14
    x, y = Mapillary::TileDecoder.lonlat_to_tile(lng, lat, z)
    rt_lat, rt_lng = Mapillary::TileDecoder.tile_to_latlng(z, x, y, 0, 0, 4096)
    # Tile-corner coords are at the NW edge of the tile, so they're slightly
    # less than the input lat (north of original) — within one tile span.
    tile_lat_span = 360.0 / (2.0**z)
    assert (rt_lat - lat).abs < tile_lat_span, "lat diff > one tile span"
    assert (rt_lng - lng).abs < tile_lat_span, "lng diff > one tile span"
  end

  test "tiles_for_bbox covers the bbox at z=14" do
    bbox = { min_lat: 41.85, max_lat: 41.90, min_lng: -87.65, max_lng: -87.60 }
    tiles = Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: 14)
    assert tiles.size >= 1
    assert tiles.all? { |t| t.is_a?(Array) && t.size == 2 }
  end

  test "tile_count_in_bbox matches tiles_for_bbox.size" do
    bbox = { min_lat: 41.85, max_lat: 41.90, min_lng: -87.65, max_lng: -87.60 }
    assert_equal Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: 14).size,
                 Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: 14)
  end

  test "stratified_tiles_for_bbox returns all tiles when range fits target" do
    bbox = { min_lat: 41.85, max_lat: 41.90, min_lng: -87.65, max_lng: -87.60 }
    all = Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: 14)
    sampled = Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: 14, target: 500)
    assert_equal all.sort, sampled.sort
  end

  test "stratified_tiles_for_bbox samples ~target tiles spread across a large range" do
    # Whole-world bbox at z=14 has billions of tiles; must NOT enumerate.
    bbox = { min_lat: -60.0, max_lat: 70.0, min_lng: -170.0, max_lng: 170.0 }
    sampled = Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: 14, target: 100)
    assert sampled.size <= 130, "expected ~100, got #{sampled.size}"
    assert sampled.size >= 80, "expected ~100, got #{sampled.size}"
    assert_equal sampled.uniq.size, sampled.size, "tiles must be unique"
    # Spread on BOTH axes — a bug that collapsed the y-grid to one row still
    # spanned x fully, so check y too (regression guard).
    x_lo, x_hi, y_lo, y_hi = Mapillary::TileDecoder.tile_range(bbox, 14)
    xs = sampled.map(&:first)
    ys = sampled.map(&:last)
    assert (xs.max - xs.min) > (x_hi - x_lo) * 0.5, "samples should span the x range"
    assert (ys.max - ys.min) > (y_hi - y_lo) * 0.5, "samples should span the y range"
    assert ys.uniq.size >= 5, "samples should cover many latitude rows, got #{ys.uniq.size}"
  end

  test "decode returns [] for empty/ocean tile bytes" do
    assert_empty Mapillary::TileDecoder.decode("", "image", 14, 0, 0)
    assert_empty Mapillary::TileDecoder.decode(nil, "image", 14, 0, 0)
    # < EMPTY_TILE_BYTES threshold
    assert_empty Mapillary::TileDecoder.decode("x" * 50, "image", 14, 0, 0)
  end
end
