class Region < ApplicationRecord
  belongs_to :parent, class_name: "Region", optional: true
  has_many :children, class_name: "Region", foreign_key: :parent_id, dependent: :destroy

  ADMIN_LEVELS = %w[continent country admin1 admin2 city].freeze

  validates :admin_level, inclusion: { in: ADMIN_LEVELS }
  validates :name, presence: true

  # Keep `normalized_name` in lockstep with `name`. The migration backfilled
  # existing rows via SQL; this callback handles every insert/update going
  # forward — including the lazy-created rows from geocoder picks.
  before_validation :set_normalized_name

  scope :continents, -> { where(admin_level: "continent") }
  scope :countries, -> { where(admin_level: "country") }
  scope :admin1s, -> { where(admin_level: "admin1") }
  scope :admin2s, -> { where(admin_level: "admin2") }

  def self.search(query, map_center: nil, limit: 20, **_opts)
    words = query.split(/\s+/).reject { |w| w.length < 2 }
    return none if words.empty?

    # Filter: each word must match by either (a) word-boundary prefix on name/parent/
    # grandparent, (b) ISO code prefix, or (c) trigram similarity (for typo tolerance).
    # The whole-query trigram threshold also catches multi-word fuzzy matches.
    # unaccent() handles diacritics so "munchen" matches "München".
    prefix_pattern = ->(w) { "\\y#{Regexp.escape(w)}" }
    full_query = words.join(" ")

    joined = joins("LEFT JOIN regions AS parents ON regions.parent_id = parents.id " \
                   "LEFT JOIN regions AS grandparents ON parents.parent_id = grandparents.id")

    word_conditions = words.map do
      "(unaccent(regions.name) ~* unaccent(?) OR unaccent(parents.name) ~* unaccent(?) " \
        "OR unaccent(grandparents.name) ~* unaccent(?) OR regions.iso_code ILIKE ?)"
    end.join(" AND ")
    word_values = words.flat_map do |w|
      pat = prefix_pattern.call(w)
      [ pat, pat, pat, "#{sanitize_sql_like(w)}%" ]
    end

    # Trigram fallback: similarity >= 0.4 on full query name (catches typos)
    trigram_condition = "similarity(unaccent(regions.name), unaccent(?)) >= 0.4"

    scope = joined.where("(#{word_conditions}) OR (#{trigram_condition})", *word_values, full_query)

    scope = scope.limit(limit)

    # Combined relevance score:
    #   ln(pop+1)/ln(10) + continent_boost(10 if continent else 0) + similarity*5 - distance_penalty
    # The first term is mathematically log10(pop+1) — written via natural log
    # so it works without any Postgres extension. Higher score = more relevant.
    # - ln(pop)/ln(10): population dominance, log-scaled so a 100M city doesn't
    #   crush a 1M city by 100×
    # - continent boost: keeps the 7 continent rows near the top
    # - similarity*5: rewards exact name matches over partial ("Paris" > "Parish")
    # - distance penalty (only when map_center given): tiebreaker for nearby places
    full_query = words.join(" ")
    similarity_sql = sanitize_sql_array([
      "GREATEST(similarity(unaccent(regions.name), unaccent(?)), " \
      "COALESCE(similarity(unaccent(parents.name), unaccent(?)), 0))", full_query, full_query
    ])

    importance_sql = <<~SQL.squish
      LN(COALESCE(regions.population, 1) + 1) / LN(10) +
      CASE WHEN regions.admin_level = 'continent' THEN 10 ELSE 0 END +
      (#{similarity_sql}) * 5
    SQL

    if map_center
      lat = map_center[:lat].to_f
      lng = map_center[:lng].to_f
      # Light distance penalty: ln(dist+1)/4. At dist=1° penalty=~0.17, dist=50°=~1.0.
      distance_sql = sanitize_sql_array([
        "CASE WHEN regions.min_lat IS NULL THEN 0 ELSE LN(SQRT(" \
        "POWER(((regions.min_lat + regions.max_lat) / 2.0 - ?), 2) + " \
        "POWER(((regions.min_lng + regions.max_lng) / 2.0 - ?), 2)) + 1) / 4.0 END", lat, lng
      ])
      score_sql = "(#{importance_sql}) - (#{distance_sql})"
    else
      score_sql = importance_sql
    end

    scope.select("regions.*").order(Arel.sql("(#{score_sql}) DESC, regions.name"))
  end

  # Memoized on the instance — compute_matching_image_ids and the click-resolution
  # path can ask for the same region's polygon many times per request, and each
  # `RGeo::GeoJSON.decode + make_valid` on a country-sized polygon is non-trivial.
  # `@rgeo_boundary` may be nil if there's no boundary or decode fails; track
  # "have we computed?" separately with `@rgeo_boundary_computed`.
  def rgeo_boundary
    return @rgeo_boundary if @rgeo_boundary_computed
    @rgeo_boundary_computed = true
    @rgeo_boundary = compute_rgeo_boundary
  end

  def compute_rgeo_boundary
    return nil unless boundary
    geom = RGeo::GeoJSON.decode(boundary.to_json)
    return nil unless geom
    geom.make_valid
  rescue RGeo::Error::InvalidGeometry
    # buffer(0) is the standard trick to repair self-intersecting polygons.
    # If even that fails, return the un-validated geom — point-in-polygon
    # against it is still cheap and roughly correct for our use case.
    geom.buffer(0) rescue geom
  rescue JSON::ParserError, RGeo::Error::RGeoError
    nil
  end

  def needs_boundary_upgrade?
    return false if admin_level == "continent"
    boundary.blank?
  end

  # Per-region negative cache: once Nominatim has failed to return a boundary
  # for this row, suppress further attempts for 6 hours. Without this, every
  # click that hits a never-found region (small admin2s, disputed territory)
  # re-incurs the 1.1s Nominatim rate-limit toll.
  BOUNDARY_FAILURE_TTL = 6.hours

  def fetch_real_boundary!
    return boundary unless needs_boundary_upgrade?
    return nil if boundary_fetch_recently_failed?

    ancestors = ancestor_names
    search_parts = [ name ]
    search_parts << ancestors[:admin1] if admin_level != "admin1" && ancestors[:admin1]
    search_parts << ancestors[:country] if ancestors[:country]
    search_query = search_parts.join(", ")

    geojson = self.class.nominatim_search_boundary(search_query)

    if !geojson && min_lat && max_lat && min_lng && max_lng
      lat = (min_lat + max_lat) / 2.0
      lng = (min_lng + max_lng) / 2.0
      geojson = self.class.nominatim_reverse_boundary(lat, lng)
    end

    unless geojson
      mark_boundary_fetch_failed!
      return nil
    end

    update!(boundary: geojson)
    recompute_bbox!
    geojson
  end

  def boundary_fetch_recently_failed?
    key = "region_boundary_fail:#{id}"
    Rails.cache.exist?(key)
  end

  def mark_boundary_fetch_failed!
    Rails.cache.write("region_boundary_fail:#{id}", Time.current, expires_in: BOUNDARY_FAILURE_TTL)
  end

  def self.nominatim_search_boundary(query)
    require "net/http"
    params = {
      q: query, format: "geojson",
      polygon_geojson: 1, polygon_threshold: 0.0001, limit: 1
    }
    uri = URI("https://nominatim.openstreetmap.org/search")
    uri.query = URI.encode_www_form(params)

    data = nominatim_request(uri)
    return nil unless data

    feature = data.dig("features", 0)
    geom = feature&.dig("geometry")
    return nil unless geom && %w[Polygon MultiPolygon].include?(geom["type"])
    geom
  rescue => e
    Rails.logger.warn("Nominatim search failed: #{e.message}")
    nil
  end

  def self.nominatim_reverse_boundary(lat, lng)
    require "net/http"
    params = { lat: lat, lon: lng, format: "json", polygon_geojson: 1, zoom: 10 }
    uri = URI("https://nominatim.openstreetmap.org/reverse")
    uri.query = URI.encode_www_form(params)

    data = nominatim_request(uri)
    return nil unless data

    geojson = data["geojson"]
    return nil unless geojson && %w[Polygon MultiPolygon].include?(geojson["type"])
    geojson
  rescue => e
    Rails.logger.warn("Nominatim reverse failed: #{e.message}")
    nil
  end

  # Resolve a candidate hash (as produced by the JS-side Nominatim reverse) to an actual
  # Region row, lazily creating intermediate parents as needed. Returns the
  # Region row, or nil if the country isn't in our DB.
  #
  # At each level: normalize the geocoder's name and look for an existing row
  # under the resolved parent with a matching normalized_name. Hit → reuse.
  # Miss → insert. So "Lagos State" maps to GeoNames "Lagos" (same normalized
  # form), but "Masovian Voivodeship" is created fresh under Poland because no
  # existing row normalizes to "masovian".
  def self.resolve_candidate(candidate)
    return nil unless candidate.is_a?(Hash)
    cc = candidate[:country_code] || candidate["country_code"]
    return nil if cc.blank?
    iso3 = IsoCountryCodes.alpha3(cc)
    country = Region.find_by(iso_code: iso3, admin_level: "country") if iso3
    return nil unless country

    parent = country
    # Walk the chain top-down (we stored it country-first → candidate-deepest).
    chain = Array(candidate[:ancestor_chain] || candidate["ancestor_chain"])
    chain.each do |entry|
      level = entry[:admin_level] || entry["admin_level"]
      next if level == "country"
      parent = find_or_create_under(parent, entry[:name] || entry["name"], level)
      return parent unless parent
    end

    target_level = candidate[:admin_level] || candidate["admin_level"]
    if target_level == "country"
      country
    else
      find_or_create_under(parent, candidate[:name] || candidate["name"], target_level)
    end
  end

  # Find a region with the same normalized name under `parent` at `level`, or
  # insert a new one.
  #
  # Ordering preference among candidates with the same normalized_name:
  #   1. has a boundary (real data)
  #   2. has a population (real data)
  #   3. higher population
  #   4. lower id (stable tiebreaker — likely the GeoNames-seeded original)
  # This ensures that, given a junk stub row from a bad-name geocoder pick AND
  # a real GeoNames row with the same normalized name, we pick the real one.
  #
  # If the chosen row is a stub (no boundary, no population, no iso_code) and
  # the incoming candidate has a longer/better name, promote the stub's name
  # to the new one. Avoids polluting the DB with both "South" and "South
  # County" rows for the same place.
  def self.find_or_create_under(parent, name, level)
    return nil if parent.nil? || name.blank? || !ADMIN_LEVELS.include?(level)
    norm = normalize_admin_name(name)
    return nil if norm.blank?

    scope = where(parent_id: parent.id, admin_level: level, normalized_name: norm)
    order_sql = "(CASE WHEN boundary IS NULL THEN 1 ELSE 0 END), " \
                "(CASE WHEN population IS NULL THEN 1 ELSE 0 END), " \
                "COALESCE(population, 0) DESC, id ASC"
    existing = scope.order(Arel.sql(order_sql)).first
    if existing
      promote_stub_name(existing, name)
      return existing
    end

    create!(parent: parent, name: name, admin_level: level)
  end

  # When we matched a row that's clearly a stub (no boundary / population /
  # iso_code) and the new candidate has a longer name with the same normalized
  # form, overwrite the stub's name. "South" → "South County" for example.
  def self.promote_stub_name(region, new_name)
    return unless region.boundary.blank? && region.population.blank? && region.iso_code.blank?
    return if region.name == new_name
    return if region.name.length >= new_name.length  # keep the longer one
    region.update_columns(name: new_name, normalized_name: normalize_admin_name(new_name))
  end

  # GeoNames admin1 names and reverse-geocoder names disagree in many countries:
  #   "Lagos State"           (MapTiler)  vs  "Lagos"           (GeoNames)
  #   "Autonomous City of …"  (MapTiler)  vs  "Buenos Aires …"  (GeoNames)
  #   "Hà Nội"                (MapTiler)  vs  "Hanoi"           (GeoNames)
  #   "Nairobi"               (MapTiler)  vs  "Nairobi County"  (GeoNames)
  #   "Special Capital Region of Jakarta" vs  "Jakarta Special Capital Region"
  # Normalize both sides for matching: lowercase, unaccent, strip common admin
  # prefix words, strip common admin suffix words, remove all non-alphanumerics.
  # After this, the failing pairs above all collapse to the same string.
  ADMIN_PREFIX_RE = "(state of|land|province of|region of|kingdom of|republic of|" \
    "autonomous city of|special capital region of|capital district of|" \
    "federal district of|metropolitan region of|metro|greater|" \
    "estado de|provincia de|departamento de)".freeze
  ADMIN_SUFFIX_RE = "(county|province|state|region|department|voivodeship|prefecture|" \
    "district|territory|oblast|krai|governorate|emirate|" \
    "special capital region|metropolitan region|capital district|f\\.d\\.)".freeze

  def self.normalize_admin_name(name)
    return "" if name.blank?
    s = ActiveSupport::Inflector.transliterate(name.to_s).downcase
    s = s.sub(/\A#{ADMIN_PREFIX_RE}\s+/i, "")
    s = s.sub(/\s+#{ADMIN_SUFFIX_RE}\z/i, "")
    s.gsub(/[^a-z0-9]+/, "")
  end


  # Nominatim allows 1 req/sec per IP. The last-request timestamp lives in
  # Rails.cache so multiple Puma workers / Sidekiq workers share the throttle —
  # a process-local instance var would let 3 workers fire 3 req/sec and risk an
  # IP ban. Sleep duration is computed from the shared timestamp, then we write
  # the new one before releasing.
  NOMINATIM_RATE_LIMIT_KEY = "nominatim_last_request_at".freeze
  NOMINATIM_MIN_GAP = 1.1

  def self.nominatim_request(uri)
    nominatim_wait_for_slot!

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "LandscapeGuessr/1.0 (region-boundary-fetch; b5f9c9@u.northwestern.edu)"
    response = http.request(request)
    Rails.cache.write(NOMINATIM_RATE_LIMIT_KEY, Process.clock_gettime(Process::CLOCK_MONOTONIC), expires_in: 1.minute)
    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end

  def self.nominatim_wait_for_slot!
    last = Rails.cache.read(NOMINATIM_RATE_LIMIT_KEY) || 0
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - last
    sleep(NOMINATIM_MIN_GAP - elapsed) if elapsed < NOMINATIM_MIN_GAP
  end

  def boundary_coord_count
    return 0 unless boundary.is_a?(Hash)
    case boundary["type"]
    when "Polygon" then boundary["coordinates"].sum(&:size)
    when "MultiPolygon" then boundary["coordinates"].sum { |p| p.sum(&:size) }
    else 0
    end
  end

  # Flatten a GeoJSON Polygon/MultiPolygon geometry hash to a flat array of
  # [lng, lat] coords. Shared between Region#recompute_bbox! and the rake
  # seed task's bbox compute step — kept as a class method so callers don't
  # need a Region instance.
  def self.extract_all_coords(geometry)
    return [] unless geometry.is_a?(Hash)
    case geometry["type"]
    when "Polygon" then geometry["coordinates"].flatten(1)
    when "MultiPolygon" then geometry["coordinates"].flatten(2)
    else []
    end
  end

  def self.compute_bbox(geometry)
    coords = extract_all_coords(geometry)
    return nil if coords.empty?
    lats = coords.map { |c| c[1] }
    lngs = coords.map { |c| c[0] }
    { min_lat: lats.min, max_lat: lats.max, min_lng: lngs.min, max_lng: lngs.max }
  end

  private

  def ancestor_names
    result = {}
    current = self
    while current.parent_id
      current = current.parent
      break unless current
      case current.admin_level
      when "country" then result[:country] = current.name
      when "admin1" then result[:admin1] = current.name
      end
    end
    result
  end

  def recompute_bbox!
    bbox = self.class.compute_bbox(boundary)
    update_columns(bbox) if bbox
  end

  def set_normalized_name
    self.normalized_name = self.class.normalize_admin_name(name) if name.present?
  end
end
