require "net/http"
require "uri"

# Imports street-imagery POINT features from Mapillary vector tiles.
#
# We always use the z=14 `image` layer (one POINT per image, dense urban
# tiles carry thousands of features). For regions bigger than the tile-
# fetch budget we take a STRATIFIED sample of z=14 tiles spread evenly
# across the bbox (see TileDecoder#stratified_tiles_for_bbox) rather than
# dropping to the sparse z=5 `overview` layer — the overview layer only
# carries ~90 features inside a city-sized bbox, which is what produced
# the "Chicago imported 6 images" bug.
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

  # Tunables.
  TILE_FETCH_CAP     = 140     # max tile fetches per import (spread across bbox)
  SAMPLE_TILE_BUDGET = 16      # tiles fetched for the 30-row preview
  COUNT_PROBE_TILES  = 4       # tiles fetched to estimate the count
  PER_TILE_CAP       = 1500    # max features kept per tile
  PER_SEQUENCE_CAP   = 3       # avoid drive-clusters
  EMPTY_TILE_BYTES   = 200     # < this = ocean / no coverage
  HARD_CAP           = 4000    # final image count per import
  CONCURRENT_FETCHES = 4

  class Error < StandardError; end

  # === Public API ===

  # Honest estimate: probe a few stratified tiles, average their feature
  # counts, and extrapolate over the tiles we'd actually fetch — scaled by
  # the fraction of probed tiles that had any coverage. Cheap (a handful of
  # tile fetches) and far closer to the imported total than the old blind
  # "tiles × 100" guess that reported 4000 for a region that imported 6.
  def self.count(region_resolved:, min_year: nil, **)
    bbox = region_resolved&.bbox
    return 0 unless bbox

    total_tiles = Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: ZOOM)
    probes = Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: ZOOM, target: COUNT_PROBE_TILES)
    counts = probes.map do |x, y|
      bytes = fetch_tile(z: ZOOM, x: x, y: y)
      Mapillary::TileDecoder.decode(bytes, LAYER, ZOOM, x, y).count { |f| !f[:is_pano] }
    rescue StandardError
      0
    end

    nonempty = counts.reject(&:zero?)
    return 0 if nonempty.empty?

    avg_per_tile = nonempty.sum.to_f / nonempty.size
    coverage     = nonempty.size.to_f / counts.size
    fetched      = [ total_tiles, TILE_FETCH_CAP ].min
    # /3: per-sequence cap thins dense tiles heavily before insert; without
    # this the estimate runs ~3× hot. Empirically lands within ~2× of actual.
    estimate = (avg_per_tile * fetched * coverage / 3.0).round
    estimate.clamp(nonempty.sum, HARD_CAP)
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

  # Fetches up to `tile_budget` z=14 `image` tiles spread evenly across the
  # region, decodes them concurrently, then filters (pano / year / bbox /
  # polygon / per-sequence). `tile_budget` lets the preview probe cheaply
  # (16 tiles) while the import samples broadly (140).
  def self.fetch_features(region_resolved:, max_features:, min_year: nil, tile_budget: TILE_FETCH_CAP, progress_image_set: nil)
    bbox = region_resolved.bbox
    polygon = region_resolved.polygon

    tiles = Mapillary::TileDecoder.stratified_tiles_for_bbox(bbox, zoom: ZOOM, target: tile_budget)

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
    # Shuffle BEFORE truncating: features arrive in tile-completion order, so
    # a plain `.first` would keep only the handful of tiles that finished
    # first — collapsing the stratified spread back into a cluster. Random
    # draw keeps the sample distributed across every fetched tile.
    features.shuffle.first(max_features)
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
