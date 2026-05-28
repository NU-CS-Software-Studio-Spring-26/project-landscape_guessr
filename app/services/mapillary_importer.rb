require "net/http"
require "uri"

# Imports street-imagery POINT features from Mapillary vector tiles.
#
# We always import from the z=14 `image` layer (one POINT per image; dense
# urban tiles carry thousands). For regions bigger than the fetch budget we
# don't blindly grid the bbox — most of a park/country is empty wilderness,
# so a uniform z=14 grid lands on coverage in only a handful of tiles and the
# import collapses into a few clusters. Instead we build a COVERAGE MAP from a
# few cheap low-zoom `sequence` tiles (drive paths), which reveals exactly
# which z=14 tiles have imagery, and fetch z=14 tiles only at covered
# locations — spread across the region and spatially thinned. See
# `tiles_to_fetch` / `covered_z14_tiles`.
#
# Per-image rows are stored with `url=NULL`, `external_source="mapillary"`,
# `external_id=image_id`. Signed URLs are resolved lazily at render time
# by `MapillaryUrlResolver` (they expire after ~30 days).
#
# Memory budget: at most TILE_FETCH_CAP tiles processed (4 concurrent;
# bytes discarded after decode) × PER_TILE_CAP feature hashes — ~45MB
# peak, fits Heroku's ~162MB headroom.
class MapillaryImporter
  TILE_HOST    = "tiles.mapillary.com"
  TILESET_NAME = "mly1_public"
  USER_AGENT   = WikimediaUserAgent::STRING
  READ_TIMEOUT = 30

  ZOOM  = 14
  LAYER = "image"

  # The `sequence` layer (drive paths) exists at low zooms and acts as a
  # cheap coverage map: a handful of these tiles tells us which z=14 tiles
  # actually have imagery, so we aim the expensive z=14 fetches at real
  # coverage instead of gridding mostly-empty wilderness. z=8 gives the best
  # ratio (verified: 4 z=8 tiles over Yellowstone → 330 covered z=14 tiles,
  # vs a blind 140-tile z=14 grid that found only 12).
  COVERAGE_ZOOM        = 8
  COVERAGE_PROBE_TILES = 8

  # Tunables.
  TILE_FETCH_CAP     = 140     # max z=14 tile fetches per import (spread across coverage)
  SAMPLE_TILE_BUDGET = 16      # z=14 tiles fetched for the 30-row preview
  COUNT_PROBE_TILES  = 6       # covered tiles sampled to estimate the count
  PER_TILE_CAP       = 1500    # max features kept per tile
  PER_SEQUENCE_CAP   = 3       # avoid drive-clusters
  EMPTY_TILE_BYTES   = 200     # < this = ocean / no coverage
  HARD_CAP           = 4000    # final image count per import
  CONCURRENT_FETCHES = 4

  class Error < StandardError; end

  # === Public API ===

  # Honest estimate built on the coverage map: find the z=14 tiles that
  # actually have imagery (via the sequence layer), probe a few of THEM for
  # their average feature density, and extrapolate over the tiles we'd
  # really fetch. This never returns 0 for a region that has coverage (the
  # old 4-blind-tile probe returned 0 for sparse parks) and never crashes
  # (the old clamp could get min > max when dense probe tiles summed past
  # HARD_CAP).
  def self.count(region_resolved:, min_year: nil, **)
    bbox = region_resolved&.bbox
    return 0 unless bbox

    tiles = tiles_to_fetch(bbox, TILE_FETCH_CAP)
    return 0 if tiles.empty?

    polygon = region_resolved.polygon
    probes = tiles.sample([ COUNT_PROBE_TILES, tiles.size ].min)
    counts = probes.map do |x, y|
      bytes = fetch_tile(z: ZOOM, x: x, y: y)
      feats = Mapillary::TileDecoder.decode(bytes, LAYER, ZOOM, x, y).reject { |f| f[:is_pano] }
      # Mirror the import's filtering so the per-tile figure reflects what
      # actually survives to insert (not raw, often-10× tile density): bbox +
      # polygon (a radius circle / city boundary trims edge tiles heavily) +
      # the per-sequence cap. This is what keeps "up to N" honest.
      feats = bbox_filter(feats, bbox)
      feats = polygon_refine(feats, polygon) if polygon
      limit_per_sequence(feats, PER_SEQUENCE_CAP).size
    rescue StandardError
      0
    end

    nonempty = counts.reject(&:zero?)
    return 0 if nonempty.empty?

    avg_per_tile = nonempty.sum.to_f / nonempty.size
    coverage     = nonempty.size.to_f / counts.size
    estimate = (avg_per_tile * tiles.size * coverage).round
    # clamp the floor too: a couple of dense urban probe tiles can push
    # nonempty.sum past HARD_CAP, and clamp(min, max) with min > max raises.
    estimate.clamp([ nonempty.sum, HARD_CAP ].min, HARD_CAP)
  end

  def self.sample(region_resolved:, min_year: nil, limit: 30, **)
    return [] unless region_resolved&.bbox
    features = fetch_features(region_resolved: region_resolved, max_features: limit * 6,
                              min_year: min_year, tile_budget: SAMPLE_TILE_BUDGET)
    features = features.shuffle.first(limit)
    # Resolve URLs for the preview (small batch).
    url_by_id = MapillaryUrlResolver.warm_urls(features.map { |f| f[:id] }, size: 1024)
    features.map do |f|
      {
        external_source: "mapillary",
        external_id: f[:id],
        url: url_by_id[f[:id]],
        title: "Mapillary #{f[:id]}",
        lat: f[:lat],
        lng: f[:lng],
        sequence_id: f[:sequence_id],
        captured_at: f[:captured_at]
      }
    end
  end

  def self.import!(image_set:, region_resolved:, min_year: nil)
    return unless region_resolved&.bbox
    image_set.update_columns(import_state: "fetching", import_progress: 0, import_total: 0)

    features = fetch_features(
      region_resolved: region_resolved,
      max_features: HARD_CAP,
      min_year: min_year,
      tile_budget: TILE_FETCH_CAP,
      progress_image_set: image_set
    )
    features = features.shuffle.first(HARD_CAP)

    rows = features.map do |f|
      {
        external_source: "mapillary",
        external_id: f[:id],
        url: nil,  # resolved lazily at render time
        title: nil,
        lat: f[:lat],
        lng: f[:lng],
        author: f[:creator_id],
        license: "CC-BY-SA-4.0"
      }
    end

    image_set.update_columns(import_state: "inserting", import_total: rows.size, import_progress: 0)
    Image.bulk_insert_for_source!(image_set: image_set, rows: rows, source: "mapillary")
  end

  # === Tile fetch + decode ===

  # Fetches up to `tile_budget` z=14 `image` tiles, decodes them
  # concurrently, then filters (pano / year / bbox / polygon / per-sequence)
  # and spatially thins so the result is spread, not clustered. Tiles come
  # from the coverage map (see `tiles_to_fetch`) so we don't waste the budget
  # on empty wilderness. `tile_budget` lets the preview probe cheaply (16
  # tiles) while the import samples broadly (140).
  def self.fetch_features(region_resolved:, max_features:, min_year: nil, tile_budget: TILE_FETCH_CAP, progress_image_set: nil)
    bbox = region_resolved.bbox
    polygon = region_resolved.polygon

    tiles = tiles_to_fetch(bbox, tile_budget)

    progress_image_set&.update_columns(import_total: tiles.size, import_progress: 0)

    min_ts = min_year ? Time.utc(min_year.to_i).to_i * 1000 : nil

    decoded = Concurrent::Array.new
    progress = Concurrent::AtomicFixnum.new(0)

    pool_size = [ tiles.size, CONCURRENT_FETCHES ].min
    queue = Queue.new
    tiles.each { |t| queue << t }

    threads = Array.new(pool_size) do
      Thread.new do
        loop do
          tile = queue.pop(true) rescue nil
          break unless tile
          x, y = tile
          begin
            bytes = fetch_tile(z: ZOOM, x: x, y: y)
            features = Mapillary::TileDecoder.decode(bytes, LAYER, ZOOM, x, y)
            features = features.first(PER_TILE_CAP) if features.size > PER_TILE_CAP
            decoded.concat(features) if features.any?
          rescue StandardError => e
            Rails.logger.warn "[mly tile] z=#{ZOOM} x=#{x} y=#{y}: #{e.class}: #{e.message.slice(0, 200)}"
          end
          done = progress.increment
          if progress_image_set
            ActiveRecord::Base.connection_pool.with_connection do
              progress_image_set.update_columns(import_progress: done)
            end
          end
        end
      end
    end
    threads.each(&:join)

    features = decoded.to_a
    features = features.reject { |f| f[:is_pano] }
    features = features.select { |f| f[:captured_at].to_i >= min_ts } if min_ts
    features = bbox_filter(features, bbox)
    features = polygon_refine(features, polygon) if polygon
    features = limit_per_sequence(features, PER_SEQUENCE_CAP)
    # Spatially thin so dense tiles don't dominate: keep a roughly equal
    # share per occupied z=14 cell. Then shuffle BEFORE truncating (features
    # arrive in tile-completion order, so a plain `.first` would collapse the
    # spread back into whichever tiles finished first).
    features = spatial_thin(features, max_features)
    features.shuffle.first(max_features)
  end

  # Chooses which z=14 `image` tiles to fetch. Small regions: take them all.
  # Larger regions: use the sequence-layer coverage map to fetch only tiles
  # that actually have imagery, spread across the region. Falls back to a
  # blind stratified grid only if the coverage probe finds nothing (so we
  # never regress to zero where coverage exists but the probe missed it).
  def self.tiles_to_fetch(bbox, budget)
    total = Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: ZOOM)
    return Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: ZOOM) if total <= budget

    covered = covered_z14_tiles(bbox)
    return Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: ZOOM, target: budget) if covered.empty?
    return covered if covered.size <= budget

    spread_sample_tiles(covered, budget, bbox)
  end

  # The set of z=14 tiles with Mapillary coverage, discovered from a few
  # cheap low-zoom `sequence` tiles. Each sequence LINESTRING vertex is a
  # drive position; we map it to its z=14 tile.
  def self.covered_z14_tiles(bbox)
    seq_tiles = Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: COVERAGE_ZOOM, target: COVERAGE_PROBE_TILES)
    z14 = {}
    seq_tiles.each do |x, y|
      bytes = fetch_tile(z: COVERAGE_ZOOM, x: x, y: y)
      Mapillary::TileDecoder.coverage_points(bytes, COVERAGE_ZOOM, x, y).each do |lat, lng|
        next unless lat.between?(bbox[:min_lat], bbox[:max_lat]) && lng.between?(bbox[:min_lng], bbox[:max_lng])
        z14[Mapillary::TileDecoder.lonlat_to_tile(lng, lat, ZOOM)] = true
      end
    rescue StandardError => e
      Rails.logger.warn "[mly coverage] z=#{COVERAGE_ZOOM} #{x},#{y}: #{e.class}: #{e.message.slice(0, 120)}"
    end
    z14.keys
  end

  # Pick `budget` tiles from `covered` spread evenly across the bbox: lay a
  # coarse grid over the tile range and take one covered tile per cell, so
  # the fetched tiles span the whole region rather than bunching where
  # coverage is densest.
  def self.spread_sample_tiles(covered, budget, bbox)
    x_lo, x_hi, y_lo, y_hi = Mapillary::TileDecoder.tile_range(bbox, ZOOM)
    nx = (x_hi - x_lo + 1).to_f
    ny = (y_hi - y_lo + 1).to_f
    aspect = nx / ny
    gx = [ Math.sqrt(budget * aspect).round, 1 ].max
    gy = [ (budget.to_f / gx).ceil, 1 ].max
    by_cell = covered.group_by do |x, y|
      [ ((x - x_lo) * gx / nx).floor, ((y - y_lo) * gy / ny).floor ]
    end
    by_cell.values.map(&:sample).first(budget)
  end

  # Keep a roughly equal share of features per occupied z=14 cell so a few
  # dense urban tiles don't swamp the sample. No-op when already under cap.
  def self.spatial_thin(features, max_features)
    return features if features.size <= max_features
    by_cell = features.group_by { |f| Mapillary::TileDecoder.lonlat_to_tile(f[:lng], f[:lat], ZOOM) }
    per_cell = [ (max_features.to_f / by_cell.size).ceil, 1 ].max
    by_cell.values.flat_map { |fs| fs.sample([ per_cell, fs.size ].min) }
  end

  def self.bbox_filter(features, bbox)
    features.select do |f|
      f[:lat] >= bbox[:min_lat] && f[:lat] <= bbox[:max_lat] &&
        f[:lng] >= bbox[:min_lng] && f[:lng] <= bbox[:max_lng]
    end
  end

  def self.polygon_refine(features, polygon)
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    features.select do |f|
      point = factory.point(f[:lng], f[:lat])
      polygon.contains?(point) rescue false
    end
  end

  # Cap per sequence — a single 30-minute drive in a dense city can
  # produce 5000+ images at z=14. Without this, large-city imports
  # collapse to a handful of drive-clusters and miss the rest of the region.
  def self.limit_per_sequence(features, cap)
    by_seq = features.group_by { |f| f[:sequence_id] || f[:id] }
    by_seq.flat_map { |_seq, list| list.sample([ cap, list.size ].min) }
  end

  # https://tiles.mapillary.com/maps/vtp/<tileset>/2/<z>/<x>/<y>?access_token=<token>
  # Empty tiles are valid 200 responses with tiny payloads — caller treats
  # < EMPTY_TILE_BYTES as no coverage.
  def self.fetch_tile(z:, x:, y:)
    uri = URI("https://#{TILE_HOST}/maps/vtp/#{TILESET_NAME}/2/#{z}/#{x}/#{y}")
    uri.query = URI.encode_www_form(access_token: token)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = USER_AGENT
      h.request(req)
    end
    return nil unless res.is_a?(Net::HTTPSuccess)
    res.body
  end

  def self.token
    ENV["MAPILLARY_TOKEN"].presence || (raise Error, "MAPILLARY_TOKEN not set")
  end
end
