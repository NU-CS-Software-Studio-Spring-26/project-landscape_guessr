require "net/http"
require "uri"

# Imports street-imagery POINT features from Mapillary vector tiles.
# Adaptive zoom: z=14 `image` layer for small regions (cities), z=5
# `overview` layer for larger regions (states/countries/world).
#
# Per-image rows are stored with `url=NULL`, `external_source="mapillary"`,
# `external_id=image_id`. Signed URLs are resolved lazily at render time
# by `MapillaryUrlResolver` (they expire after ~30 days).
#
# Memory budget verified ~50MB peak per import (12MB MVT bytes in flight
# + 38MB feature hashes), fits Heroku's ~162MB headroom.
class MapillaryImporter
  TILE_HOST    = "tiles.mapillary.com"
  TILESET_NAME = "mly1_public"
  USER_AGENT   = WikimediaUserAgent::STRING
  READ_TIMEOUT = 30

  # Tunables (verified in plan).
  TILE_FETCH_CAP    = 100      # max tile fetches per import
  PER_TILE_CAP      = 1500     # max features kept per tile
  PER_SEQUENCE_CAP  = 3        # avoid drive-clusters
  EMPTY_TILE_BYTES  = 200      # < this = ocean / no coverage
  HARD_CAP          = 4000     # final image count per import
  CONCURRENT_FETCHES = 4
  Z14_THRESHOLD     = 100      # ≤ this → z=14 image layer; > → z=5 overview

  class Error < StandardError; end

  # === Public API ===

  def self.count(region_resolved:, **)
    return 0 unless region_resolved&.bbox
    zoom, _layer = choose_zoom_and_layer(region_resolved.bbox)
    tile_count = Mapillary::TileDecoder.tile_count_in_bbox(region_resolved.bbox, zoom: zoom)
    # Estimate: cap × average features per tile (rough). Don't actually
    # fetch tiles just to count — that'd blow the import time budget twice.
    estimate = case zoom
    when 14 then [ tile_count, TILE_FETCH_CAP ].min * 100
    else         TILE_FETCH_CAP * 200
    end
    [ estimate, HARD_CAP ].min
  end

  def self.sample(region_resolved:, min_year: nil, limit: 30, **)
    return [] unless region_resolved&.bbox
    features = fetch_features(region_resolved: region_resolved, max_features: limit * 6, min_year: min_year)
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

  # === Adaptive zoom decision ===

  def self.choose_zoom_and_layer(bbox)
    z14_count = Mapillary::TileDecoder.tile_count_in_bbox(bbox, zoom: 14)
    if z14_count <= Z14_THRESHOLD
      [ 14, "image" ]
    else
      [ 5, "overview" ]
    end
  end

  # === Tile fetch + decode ===

  def self.fetch_features(region_resolved:, max_features:, min_year: nil, progress_image_set: nil)
    bbox = region_resolved.bbox
    polygon = region_resolved.polygon
    zoom, layer = choose_zoom_and_layer(bbox)

    tiles = Mapillary::TileDecoder.tiles_for_bbox(bbox, zoom: zoom)
    tiles = tiles.shuffle.first(TILE_FETCH_CAP) if tiles.size > TILE_FETCH_CAP

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
            bytes = fetch_tile(z: zoom, x: x, y: y)
            features = Mapillary::TileDecoder.decode(bytes, layer, zoom, x, y)
            features = features.first(PER_TILE_CAP) if features.size > PER_TILE_CAP
            decoded.concat(features) if features.any?
          rescue StandardError => e
            Rails.logger.warn "[mly tile] z=#{zoom} x=#{x} y=#{y}: #{e.class}: #{e.message.slice(0, 200)}"
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
    features.first(max_features)
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
