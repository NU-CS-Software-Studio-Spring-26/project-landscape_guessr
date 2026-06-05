require "net/http"
require "uri"

# Imports street-imagery POINT features from Mapillary vector tiles.
#
# Three scales, picked by region size (see `use_overview?`):
#
#   * Small (≤ TILE_FETCH_CAP z=14 tiles — a neighbourhood, radius, or most
#     cities): fetch EVERY z=14 `image` tile in the bbox. Full coverage.
#   * Medium (metro → country, where the coverage probe can fetch all its z6
#     tiles): build a COVERAGE MAP from cheap low-zoom `sequence` tiles (drive
#     paths), which reveals exactly which z=14 tiles have imagery, and fetch
#     z=14 tiles only at covered locations — spread across the region and
#     spatially thinned. See `tiles_to_fetch` / `covered_z14_tiles`.
#   * Large (continent / world / huge country): the z=14 `image` layer doesn't
#     exist below z14 and the sequence-coverage probe can only sample ~20 spots
#     at world scale (the "1514 images in 20 clusters" bug). So we switch to the
#     globally-decimated z=4/5 `overview` POINT layer — ~150 z4 tiles blanket
#     the whole world. See `use_overview?` / `fetch_overview_raw`.
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

  # The `sequence` layer (drive paths) acts as a cheap COVERAGE MAP: it tells
  # us which z=14 tiles actually have imagery, so we aim the expensive z=14
  # fetches at real coverage instead of gridding mostly-empty wilderness.
  #
  # The key to even distribution (not clusters) is COMPLETENESS: we fetch
  # EVERY coverage tile that tiles the bbox, at the highest zoom whose full
  # tiling fits the cap (more zoom = more geometry detail). A city lands at
  # ~z12 (detailed), a country at ~z6 (whole-country breadth). Only when even
  # z6 exceeds the cap (continent / whole world) do we stratified-SAMPLE the
  # coverage tiles — accepting coarser global spread. z<6 has no usable
  # sequence geometry (verified: z3 returns nothing), so we never go below it.
  COVERAGE_MIN_ZOOM   = 6
  COVERAGE_MAX_ZOOM   = 12
  # Cap for fetching EVERY tile that tiles the bbox. ~28 keeps a country like
  # Sweden (24 z6 tiles) a complete fetch-all, while pushing a dense city off
  # the heaviest zoom (Tokyo z12 = 32 tiles → z11 = 8) so the probe stays fast.
  COVERAGE_FETCH_CAP  = 28
  COVERAGE_SAMPLE_CAP = 96     # cap when stratified-sampling (continent / world)
  COVERAGE_CACHE_TTL  = 5.minutes

  # Tunables.
  TILE_FETCH_CAP     = 300     # max z=14 tile fetches per import (one image cluster each)
  SAMPLE_TILE_BUDGET = 24      # z=14 tiles fetched for the 30-row preview
  COUNT_PROBE_TILES  = 8       # covered tiles sampled to estimate the count
  PER_TILE_CAP       = 1000    # max features kept per tile (memory bound)
  PER_SEQUENCE_CAP   = 3       # avoid drive-clusters
  HARD_CAP           = 4000    # final image count per import
  CONCURRENT_FETCHES = 8

  # `overview` layer (z4-5): a globally-decimated POINT-per-image layer that
  # exists where the z14 `image` layer doesn't. One z4 tile spans a continent,
  # so the whole world is only ~153 z4 tiles — the only way to get an even
  # GLOBAL spread. NOT used for cities: within a single city the overview layer
  # is far too sparse (~90 pts), so city/metro imports stay on z14.
  OVERVIEW_LAYER        = "overview"
  OVERVIEW_MAX_ZOOM     = 5     # finer spread; used when its tiling fits the cap
  OVERVIEW_MIN_ZOOM     = 4     # whole world = 153 z4 tiles
  OVERVIEW_FETCH_CAP    = 200   # z5 tiles ≤ this → z5, else z4
  OVERVIEW_TILE_CAP     = 220   # max overview tiles per import (world z4 = 153)
  OVERVIEW_PER_TILE_CAP = 2000  # memory bound; a z4 tile can carry 8k+ points
  OVERVIEW_COUNT_PROBES = 10    # overview tiles sampled to estimate the count

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
    return overview_count(region_resolved) if use_overview?(bbox)

    tiles = tiles_to_fetch(region_resolved, TILE_FETCH_CAP)
    return 0 if tiles.empty?

    polygon = region_resolved.polygon
    probes = tiles.sample([ COUNT_PROBE_TILES, tiles.size ].min)
    # Probe tiles concurrently — a dense-city z=14 tile is ~1MB to fetch +
    # decode, so 8 sequential probes was the bulk of count latency.
    counts = Concurrent::Array.new
    each_tile_concurrent(probes, ZOOM) do |bytes, x, y|
      feats = Mapillary::TileDecoder.decode(bytes, LAYER, ZOOM, x, y).reject { |f| f[:is_pano] }
      # Mirror the import's filtering so the per-tile figure reflects what
      # actually survives to insert (not raw, often-10× tile density): bbox +
      # polygon (a radius circle / city boundary trims edge tiles heavily) +
      # the per-sequence cap. This is what keeps "up to N" honest.
      feats = bbox_filter(feats, bbox)
      feats = polygon_refine(feats, polygon) if polygon
      counts << limit_per_sequence(feats, PER_SEQUENCE_CAP).size
    end
    counts = counts.to_a

    nonempty = counts.reject(&:zero?)
    return 0 if counts.empty? || nonempty.empty?

    avg_per_tile = nonempty.sum.to_f / nonempty.size
    coverage     = nonempty.size.to_f / counts.size
    estimate = (avg_per_tile * tiles.size * coverage).round
    # clamp the floor too: a couple of dense urban probe tiles can push
    # nonempty.sum past HARD_CAP, and clamp(min, max) with min > max raises.
    estimate.clamp([ nonempty.sum, HARD_CAP ].min, HARD_CAP)
  end

  # Count for overview-scale regions: sample a handful of overview tiles, count
  # in-region points per tile, extrapolate over all overview tiles. Cheap (≤10
  # tiles) and never blocks on fetching the whole world just to size the set.
  def self.overview_count(region_resolved)
    bbox = region_resolved.bbox
    polygon = region_resolved.polygon
    z = overview_zoom(bbox)
    all = Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: z)
    return 0 if all.empty?

    probes = all.sample([ OVERVIEW_COUNT_PROBES, all.size ].min)
    counts = Concurrent::Array.new
    each_tile_concurrent(probes, z) do |bytes, x, y|
      feats = Mapillary::TileDecoder.decode(bytes, OVERVIEW_LAYER, z, x, y).reject { |f| f[:is_pano] }
      feats = bbox_filter(feats, bbox)
      feats = polygon_refine(feats, polygon) if polygon
      counts << feats.size
    end
    counts = counts.to_a
    nonempty = counts.reject(&:zero?)
    return 0 if nonempty.empty?

    avg_per_tile = nonempty.sum.to_f / nonempty.size
    coverage     = nonempty.size.to_f / counts.size
    estimate = (avg_per_tile * all.size * coverage).round
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

  # Fetches `tile_budget` z=14 `image` tiles, decodes them concurrently, then
  # filters (pano / year / bbox / polygon / per-sequence) and spatially thins
  # so the result is spread, not clustered. Tiles come from the coverage map
  # (see `tiles_to_fetch`) so the budget isn't wasted on empty wilderness.
  # `tile_budget` lets the preview probe cheaply while the import samples broadly.
  def self.fetch_features(region_resolved:, max_features:, min_year: nil, tile_budget: TILE_FETCH_CAP, progress_image_set: nil)
    bbox = region_resolved.bbox
    polygon = region_resolved.polygon

    raw =
      if use_overview?(bbox)
        fetch_overview_raw(bbox, [ tile_budget, OVERVIEW_TILE_CAP ].min, progress_image_set)
      else
        fetch_image_raw(tiles_to_fetch(region_resolved, tile_budget), progress_image_set)
      end

    filter_and_thin(raw, bbox: bbox, polygon: polygon, min_year: min_year, max_features: max_features)
  end

  # Continent / world / huge country (USA, Russia, Brazil, ...): below z14 the
  # `image` layer doesn't exist and the sequence-coverage probe can only sample
  # tiles too sparsely, so use the global `overview` layer instead. Threshold
  # mirrors the coverage probe's own fetch-all cap — if we can't fetch every z6
  # coverage tile, the region is overview-scale.
  #
  # KNOWN LIMITATION: this counts z6 tiles over the bbox RECTANGLE, so an
  # archipelago country with a huge ocean-filled bbox (Japan z6=49, Indonesia
  # 50, Chile 90, Norway 342) is wrongly sent to the sparse overview layer even
  # though its land would tile well at z14. Gating on the land polygon at z6
  # doesn't work either: a z6 tile is ~600km, so center-in-polygon undercounts
  # big blocky countries (Brazil, Australia drop below the cap and would lose
  # the overview layer they need). The correct fix is a polygon-AREA (km²)
  # threshold; deferred until that can be measured and tuned.
  def self.use_overview?(bbox)
    Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: COVERAGE_MIN_ZOOM) > COVERAGE_FETCH_CAP
  end

  # Prefer z5 (finer spread) when its full tiling fits the cap; drop to z4 only
  # for the very largest regions (z5 world = 1024 tiles, z4 world = 153).
  def self.overview_zoom(bbox)
    if Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: OVERVIEW_MAX_ZOOM) <= OVERVIEW_FETCH_CAP
      OVERVIEW_MAX_ZOOM
    else
      OVERVIEW_MIN_ZOOM
    end
  end

  # z14 `image`-layer fetch (small / medium regions). PER_TILE_CAP bounds memory.
  def self.fetch_image_raw(tiles, progress_image_set)
    decode_tiles_concurrent(tiles, ZOOM, LAYER, progress_image_set, per_tile_cap: PER_TILE_CAP)
  end

  # `overview`-layer fetch (continent / world). Fetch every overview tile that
  # tiles the bbox (stratified-sampled down to `max_tiles` for the preview).
  def self.fetch_overview_raw(bbox, max_tiles, progress_image_set)
    z = overview_zoom(bbox)
    tiles = Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: z)
    tiles = Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: z, target: max_tiles) if tiles.size > max_tiles
    decode_tiles_concurrent(tiles, z, OVERVIEW_LAYER, progress_image_set, per_tile_cap: OVERVIEW_PER_TILE_CAP)
  end

  # Fetch + decode a tile list concurrently into a flat feature array, updating
  # the import progress bar per completed tile. `per_tile_cap` bounds memory.
  def self.decode_tiles_concurrent(tiles, zoom, layer, progress_image_set, per_tile_cap: nil)
    progress_image_set&.update_columns(import_total: tiles.size, import_progress: 0)
    decoded = Concurrent::Array.new
    progress = Concurrent::AtomicFixnum.new(0)
    each_tile_concurrent(tiles, zoom) do |bytes, x, y|
      features = Mapillary::TileDecoder.decode(bytes, layer, zoom, x, y)
      features = features.first(per_tile_cap) if per_tile_cap && features.size > per_tile_cap
      decoded.concat(features) if features.any?
      done = progress.increment
      if progress_image_set
        ActiveRecord::Base.connection_pool.with_connection do
          progress_image_set.update_columns(import_progress: done)
        end
      end
    end
    decoded.to_a
  end

  # Shared post-fetch pipeline: drop panos / old / out-of-region features, cap
  # per drive, then spatially thin so dense tiles don't dominate (keep a roughly
  # equal share per occupied z=14 cell). Shuffle BEFORE truncating — features
  # arrive in tile-completion order, so a plain `.first` would collapse the
  # spread back into whichever tiles finished first.
  def self.filter_and_thin(features, bbox:, polygon:, min_year:, max_features:)
    min_ts = min_year ? Time.utc(min_year.to_i).to_i * 1000 : nil
    features = features.reject { |f| f[:is_pano] }
    features = features.select { |f| f[:captured_at].to_i >= min_ts } if min_ts
    features = bbox_filter(features, bbox)
    features = polygon_refine(features, polygon) if polygon
    features = limit_per_sequence(features, PER_SEQUENCE_CAP)
    features = spatial_thin(features, max_features)
    features.shuffle.first(max_features)
  end

  # Chooses which z=14 `image` tiles to fetch. Small regions: take them all.
  # Larger regions: use the sequence-layer coverage map to fetch only tiles
  # that actually have imagery, dropping any outside the region polygon (so a
  # country's budget isn't spent on a neighbour sharing its bbox), then spread
  # them. Falls back to a blind stratified grid only if the coverage probe
  # finds nothing (so we never regress to zero where coverage exists).
  def self.tiles_to_fetch(region_resolved, budget)
    bbox = region_resolved.bbox
    polygon = region_resolved.polygon
    total = Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: ZOOM)
    return Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: ZOOM) if total <= budget

    covered = covered_z14_tiles(bbox)
    covered = filter_tiles_in_polygon(covered, polygon) if polygon
    return Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: ZOOM, target: budget) if covered.empty?
    return covered if covered.size <= budget

    spread_sample_tiles(covered, budget, bbox)
  end

  # Keep only tiles whose centre falls inside the region polygon.
  def self.filter_tiles_in_polygon(tiles, polygon)
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    kept = tiles.select do |x, y|
      lat, lng = Mapillary::TileDecoder.tile_to_latlng(ZOOM, x, y, 2048, 2048, 4096)
      polygon.contains?(factory.point(lng, lat)) rescue true
    end
    kept.empty? ? tiles : kept # never strand the import if the polygon is odd
  end

  # The set of z=14 tiles with Mapillary coverage, discovered from low-zoom
  # `sequence` tiles. Each sequence LINESTRING vertex is a drive position; we
  # map it to its z=14 tile. Coverage tiles are fetched concurrently. The
  # result is cached briefly so the count and preview phases (same region,
  # seconds apart) share one probe instead of each paying the decode cost.
  def self.covered_z14_tiles(bbox)
    key = "mly:cov:#{bbox.values_at(:min_lat, :max_lat, :min_lng, :max_lng).map { |v| v.round(3) }.join(',')}"
    cached = Rails.cache.read(key)
    return cached if cached

    cz, seq_tiles = coverage_probe_tiles(bbox)
    z14 = Concurrent::Hash.new
    each_tile_concurrent(seq_tiles, cz) do |bytes, x, y|
      Mapillary::TileDecoder.coverage_points(bytes, cz, x, y).each do |lat, lng|
        next unless lat.between?(bbox[:min_lat], bbox[:max_lat]) && lng.between?(bbox[:min_lng], bbox[:max_lng])
        z14[Mapillary::TileDecoder.lonlat_to_tile(lng, lat, ZOOM)] = true
      end
    end
    result = z14.keys
    Rails.cache.write(key, result, expires_in: COVERAGE_CACHE_TTL) if result.size <= 50_000
    result
  end

  # Returns [zoom, tiles] for the coverage probe. Fetch EVERY tile that tiles
  # the bbox at the highest zoom (most geometry detail) whose full tiling fits
  # the cap — a city resolves to ~z12, a country to ~z6, both COMPLETE. If even
  # z6 exceeds the cap (continent / world) we stratified-sample z6 tiles up to
  # the cap, accepting coarser spread for those very large regions.
  def self.coverage_probe_tiles(bbox)
    z = COVERAGE_MAX_ZOOM.downto(COVERAGE_MIN_ZOOM).find do |zz|
      Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: zz) <= COVERAGE_FETCH_CAP
    end
    return [ z, Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: z) ] if z
    [ COVERAGE_MIN_ZOOM,
      Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: COVERAGE_MIN_ZOOM, target: COVERAGE_SAMPLE_CAP) ]
  end

  # Fetch a list of tiles concurrently, yielding (bytes, x, y) per tile. Errors
  # on one tile are logged and skipped. Shared by the coverage probe and the
  # main image fetch.
  def self.each_tile_concurrent(tiles, zoom)
    return if tiles.empty?
    queue = Queue.new
    tiles.each { |t| queue << t }
    pool = [ tiles.size, CONCURRENT_FETCHES ].min
    threads = Array.new(pool) do
      Thread.new do
        loop do
          tile = queue.pop(true) rescue nil
          break unless tile
          x, y = tile
          begin
            yield fetch_tile(z: zoom, x: x, y: y), x, y
          rescue StandardError => e
            Rails.logger.warn "[mly tile] z=#{zoom} #{x},#{y}: #{e.class}: #{e.message.slice(0, 120)}"
          end
        end
      end
    end
    threads.each(&:join)
  end

  # Pick `budget` tiles from `covered`, spread across the bbox: lay a coarse
  # grid (~budget cells) over the tile range, then round-robin across the
  # NON-EMPTY cells — one tile per cell per pass — until the budget is filled.
  #
  # The round-robin fill is what stops a region whose coverage is CONCENTRATED
  # in part of its bbox (Beijing: a dense centre inside a 210km municipality,
  # ~50 occupied cells of a 300-cell grid) from collapsing to one-tile-per-cell
  # (~50 tiles) and wasting 5/6 of the budget — the old "Beijing returns 391
  # images" bug. We still spread (first pass hits every occupied cell) but then
  # keep drawing from the covered cells until we've used the whole budget.
  def self.spread_sample_tiles(covered, budget, bbox)
    return covered if covered.size <= budget
    x_lo, x_hi, y_lo, y_hi = Mapillary::TileDecoder.tile_range(bbox, ZOOM)
    nx = (x_hi - x_lo + 1).to_f
    ny = (y_hi - y_lo + 1).to_f
    aspect = nx / ny
    gx = [ Math.sqrt(budget * aspect).round, 1 ].max
    gy = [ (budget.to_f / gx).ceil, 1 ].max
    buckets = covered.group_by { |x, y| [ ((x - x_lo) * gx / nx).floor, ((y - y_lo) * gy / ny).floor ] }
                     .values.map(&:shuffle)
    picked = []
    while picked.size < budget && buckets.any?(&:any?)
      buckets.each do |bucket|
        next if bucket.empty?
        picked << bucket.pop
        break if picked.size >= budget
      end
    end
    picked
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
  # Empty tiles are valid 200 responses with tiny payloads — the decoder treats
  # bytes < TileDecoder::EMPTY_TILE_BYTES as no coverage.
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
