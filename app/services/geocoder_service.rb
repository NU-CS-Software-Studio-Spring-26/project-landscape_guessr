require "net/http"
require "uri"
require "json"

# Batched Nominatim wrapper used by the AI's `geocode` tool and by
# `RegionResolver` for Mode B POI hulls. Shares the IP-wide 1 req/sec
# throttle with `Region.fetch_real_boundary!` via `Region.nominatim_request`.
#
# Two entry points:
#   * `geocode_many(queries:)` — for the AI tool: returns up to 5 candidates
#     per query with display_name/class/type/bbox so the AI can pick by
#     metadata. Caches each result for 7 days.
#   * `best_match(query)` — for backend resolution: returns the single
#     highest-quality candidate (boundary > place > leisure > other).
#
# Class is named GeocoderService to avoid collision with the popular
# `geocoder` gem's top-level `Geocoder` namespace (we don't use the gem
# here, but the constant clash would bite anyone who adds it later).
class GeocoderService
  # Class preference order. Boundary (admin polygons) is most reliable;
  # place (neighbourhoods, suburbs, cities not in our DB) is second;
  # leisure covers parks; natural covers rivers, mountains, etc.
  PREFERRED_CLASSES = %w[boundary place leisure natural].freeze
  # Avoid these classes when an alternative exists — railway stations and
  # tourism POIs are often pinpoint coords that produce ~0-area bboxes.
  DEPRIORITIZED_CLASSES = %w[railway amenity tourism shop building].freeze

  MAX_BATCH = 10

  # Hash result for each candidate. Stored in Rails.cache (memory_store)
  # so this must be a plain Hash, not a Struct (memory_store handles
  # arbitrary marshaled values but plain hashes survive cache restarts
  # if the user later swaps in a different backend).
  def self.geocode_many(queries:)
    list = Array(queries).first(MAX_BATCH).map(&:to_s).reject(&:blank?)
    list.each_with_object({}) do |query, acc|
      acc[query] = Rails.cache.fetch("geocode:#{query}", expires_in: 7.days) do
        fetch_candidates(query)
      end
    end
  end

  # Class-bonus weights for the combined relevance score. Importance is
  # Nominatim's own popularity/topic-strength score (0–1ish); a small bonus
  # nudges toward administrative/place results when importance is close.
  #
  # Critically, the bonus is small enough that a high-importance non-bonus
  # result (e.g. `man_made/tower` for the actual Eiffel Tower, importance
  # 0.62) still beats a low-importance bonus result (`natural/peak` for
  # an Alberta hill named "Eiffel Tower", importance 0.16 + bonus 0.05).
  CLASS_BONUS = {
    "boundary" => 0.30,
    "place"    => 0.20,
    "leisure"  => 0.10,
    "natural"  => 0.05
  }.freeze
  DEPRIORITIZED_PENALTY = -0.10

  # Single best-match resolution. Returns the highest-scoring candidate
  # by (importance + class_bonus - deprioritized_penalty).
  def self.best_match(query)
    candidates = geocode_many(queries: [ query ])[query] || []
    return nil if candidates.empty?

    candidates.max_by { |c| score(c) }
  end

  def self.score(candidate)
    bonus = CLASS_BONUS[candidate[:class]] || 0.0
    penalty = DEPRIORITIZED_CLASSES.include?(candidate[:class]) ? DEPRIORITIZED_PENALTY : 0.0
    candidate[:importance].to_f + bonus + penalty
  end

  # Approximate area in km² of a bbox hash. Used for sanity checks (single
  # POI that resolves to a country bbox = mismatch). cos(lat) factor uses
  # the bbox center; OK for our small-region usage.
  def self.bbox_area_km2(bbox)
    return 0.0 unless bbox.is_a?(Hash) && bbox[:min_lat] && bbox[:max_lat]
    lat_span = (bbox[:max_lat] - bbox[:min_lat]) * 111.0
    lng_span = (bbox[:max_lng] - bbox[:min_lng]) * 111.0 *
               Math.cos(((bbox[:min_lat] + bbox[:max_lat]) / 2.0) * Math::PI / 180.0)
    (lat_span * lng_span).abs
  end

  # GET /search?q=...&format=json&limit=5&polygon_geojson=0
  # Returns [] on network error or parse failure (caller falls back).
  def self.fetch_candidates(query)
    uri = URI("https://nominatim.openstreetmap.org/search")
    uri.query = URI.encode_www_form(
      q: query,
      format: "json",
      limit: 5,
      addressdetails: 0,
      polygon_geojson: 0
    )

    data = Region.nominatim_request(uri)
    return [] unless data.is_a?(Array)

    data.filter_map do |row|
      bbox_arr = row["boundingbox"]  # ["min_lat","max_lat","min_lon","max_lon"] (strings)
      bbox = if bbox_arr.is_a?(Array) && bbox_arr.size == 4
        {
          min_lat: bbox_arr[0].to_f, max_lat: bbox_arr[1].to_f,
          min_lng: bbox_arr[2].to_f, max_lng: bbox_arr[3].to_f
        }
      end

      lat = row["lat"]&.to_f
      lng = row["lon"]&.to_f
      next nil unless lat && lng

      {
        display_name: row["display_name"],
        class:        row["class"],
        type:         row["type"],
        addresstype:  row["addresstype"],
        lat:          lat,
        lng:          lng,
        bbox:         bbox,
        area_km2:     bbox ? bbox_area_km2(bbox) : 0.0,
        importance:   row["importance"].to_f
      }
    end
  rescue StandardError => e
    Rails.logger.warn "[geocoder] #{query}: #{e.class}: #{e.message.slice(0, 200)}"
    []
  end
end
