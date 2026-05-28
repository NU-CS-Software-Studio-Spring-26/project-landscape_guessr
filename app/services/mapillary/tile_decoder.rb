require Rails.root.join("lib/proto/vector_tile_pb").to_s

module Mapillary
  # Decodes Mapillary's vector tiles (Mapbox MVT format) into per-image
  # POINT features with lat/lng + properties. Two layers are useful for
  # bulk import:
  #
  #   * z=14 `image` layer — POINT per image. Dense urban tile ~5-18k
  #     features, 1.2MB. Use for small regions (≤100 z=14 tiles).
  #
  #   * z=4/5 `overview` layer — POINT per image. Dense urban tile
  #     ~5-15k features, 500KB-1MB. Use for state/country/world scale.
  #
  # z=6-12 has only a `sequence` LINESTRING layer (one image_id per
  # drive) — not useful for direct point sampling and skipped here.
  #
  # Geometry decoding follows the MVT spec §4.3:
  #   - First command word: `cmd_int = (count << 3) | command_id`
  #     For POINT, command_id = 1 (MoveTo)
  #   - Each coord pair is a pair of zigzag-encoded varints
  #
  # Tile→latlng inverse follows OSM slippy-map convention:
  #   - lon = (x + px/extent) / 2^z * 360 - 180
  #   - lat = atan(sinh(π · (1 - 2 · (y + py/extent) / 2^z))) · 180/π
  class TileDecoder
    EARTH_R = 6378137.0
    # Empty/ocean tile threshold — below this is gzipped header + frame.
    # Verified by fetching empty z=4 tiles which weigh 38-200 bytes.
    EMPTY_TILE_BYTES = 200

    # Slippy-map tile coords for a (lng, lat) at the given zoom.
    def self.lonlat_to_tile(lng, lat, z)
      n = 2.0**z
      x = ((lng + 180.0) / 360.0 * n).floor
      lat_rad = lat * Math::PI / 180.0
      y = ((1.0 - Math.log(Math.tan(lat_rad) + 1.0 / Math.cos(lat_rad)) / Math::PI) / 2.0 * n).floor
      [ x, y ]
    end

    # Inverse: tile (x, y) + pixel offset (px, py) within the tile's
    # extent grid → (lat, lng) in WGS84 degrees.
    def self.tile_to_latlng(z, x, y, px, py, extent)
      n = 2.0**z
      lon = (x + px.to_f / extent) / n * 360.0 - 180.0
      lat_rad = Math.atan(Math.sinh(Math::PI * (1 - 2 * (y + py.to_f / extent) / n)))
      [ lat_rad * 180.0 / Math::PI, lon ]
    end

    # All slippy tiles (x, y) covering a bbox at the given zoom.
    #
    # WARNING: enumerates every tile in the range — only safe for small
    # regions. For anything country-scale+ at z=14 the range is millions
    # of tiles and this OOMs. Use `stratified_tiles_for_bbox` for sampling.
    def self.tiles_for_bbox(bbox, zoom:)
      x_lo, x_hi, y_lo, y_hi = tile_range(bbox, zoom)
      tiles = []
      (x_lo..x_hi).each { |x| (y_lo..y_hi).each { |y| tiles << [ x, y ] } }
      tiles
    end

    # The (x_lo, x_hi, y_lo, y_hi) tile bounds of a bbox at a zoom — four
    # integers, no allocation per tile, so it's safe at any region size.
    def self.tile_range(bbox, zoom)
      x0, y0 = lonlat_to_tile(bbox[:min_lng], bbox[:max_lat], zoom)  # NW
      x1, y1 = lonlat_to_tile(bbox[:max_lng], bbox[:min_lat], zoom)  # SE
      [ *[ x0, x1 ].minmax, *[ y0, y1 ].minmax ]
    end

    # Returns up to `target` tiles spread EVENLY across the bbox's tile
    # range, WITHOUT enumerating every tile (so it works for a single
    # neighborhood or the whole world). Lays a coarse grid sized to ~target
    # cells over the range and takes one tile per cell (cell centre).
    #
    # This is what fixes the "Chicago imported 6 images" bug: instead of
    # dropping to the sparse z=5 overview layer for medium/large regions,
    # we keep the dense z=14 `image` layer and just sample a representative
    # spread of its tiles. Each sampled tile is a real, densely-populated
    # street-level location; spreading them across the range gives coverage
    # without clustering.
    def self.stratified_tiles_for_bbox(bbox, zoom:, target:)
      x_lo, x_hi, y_lo, y_hi = tile_range(bbox, zoom)
      nx = x_hi - x_lo + 1
      ny = y_hi - y_lo + 1
      total = nx * ny
      return tiles_for_bbox(bbox, zoom: zoom) if total <= target

      # Grid dimensions proportional to the range's aspect ratio, product ≈ target.
      aspect = nx.to_f / ny
      gx = [ nx, [ 1, Math.sqrt(target * aspect).round ].max ].min
      gy = [ ny, [ 1, (target.to_f / gx).ceil ].max ].min

      tiles = []
      gy.times do |j|
        gx.times do |i|
          # Cell centre, clamped into range.
          x = x_lo + ((i + 0.5) * nx / gx).floor
          y = y_lo + ((j + 0.5) * ny / gy).floor
          tiles << [ [ x, x_hi ].min, [ y, y_hi ].min ]
        end
      end
      tiles.uniq
    end

    # Quick count for the adaptive zoom decision — no allocations.
    def self.tile_count_in_bbox(bbox, zoom:)
      x0, y0 = lonlat_to_tile(bbox[:min_lng], bbox[:max_lat], zoom)
      x1, y1 = lonlat_to_tile(bbox[:max_lng], bbox[:min_lat], zoom)
      ((x0 - x1).abs + 1) * ((y0 - y1).abs + 1)
    end

    # Decode a single tile to an array of feature hashes:
    #   { id:, lat:, lng:, is_pano:, sequence_id:, captured_at:,
    #     compass_angle:, creator_id: }
    # Skips tiles below EMPTY_TILE_BYTES (ocean/no-coverage).
    def self.decode(tile_bytes, layer_name, z, x, y)
      return [] if tile_bytes.nil? || tile_bytes.bytesize < EMPTY_TILE_BYTES

      tile = VectorTile::Tile.decode(tile_bytes)
      layer = tile.layers.find { |l| l.name == layer_name }
      return [] unless layer

      extent = layer.extent
      keys = layer.keys
      values = layer.values

      layer.features.filter_map do |f|
        # Geometry: for POINT, the first command is MoveTo + a single
        # (dx, dy) pair. Skip non-POINT features.
        next unless f.type == :POINT
        geom = f.geometry
        next if geom.size < 3

        cmd_int = geom[0]
        cmd_id  = cmd_int & 0x7
        next unless cmd_id == 1  # MoveTo

        # Zigzag decode of the dx, dy pair (POINT has a single pair).
        px = (geom[1] >> 1) ^ -(geom[1] & 1)
        py = (geom[2] >> 1) ^ -(geom[2] & 1)
        lat, lng = tile_to_latlng(z, x, y, px, py, extent)

        props = {}
        f.tags.each_slice(2) do |key_idx, val_idx|
          k = keys[key_idx]
          v = values[val_idx]
          next unless k && v
          val = extract_value(v)
          props[k] = val
        end

        {
          id:            props["id"].to_s,
          lat:           lat,
          lng:           lng,
          is_pano:       truthy?(props["is_pano"]),
          sequence_id:   props["sequence_id"]&.to_s,
          captured_at:   to_int(props["captured_at"]),
          compass_angle: props["compass_angle"],
          creator_id:    props["creator_id"]&.to_s
        }
      end
    end

    # MVT Value is a union — pick whichever field is populated. proto3-style
    # implicit presence means we can't distinguish "explicit false" from
    # "unset bool" cheaply, so bool comes LAST and we return nil if no
    # other field is set. Callers handle nil defensively.
    def self.extract_value(v)
      return v.string_value unless v.string_value.empty?
      return v.int_value if v.int_value != 0
      return v.uint_value if v.uint_value != 0
      return v.sint_value if v.sint_value != 0
      return v.float_value if v.float_value != 0.0
      return v.double_value if v.double_value != 0.0
      return true if v.bool_value
      nil
    end

    def self.truthy?(val)
      val == true || val == 1 || val == 1.0
    end

    def self.to_int(val)
      return 0 if val.nil?
      val.to_i
    rescue StandardError
      0
    end
  end
end
