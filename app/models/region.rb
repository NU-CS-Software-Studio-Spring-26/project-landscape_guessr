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
  scope :cities, -> { where(admin_level: "city") }

  def self.descendants_of(region_ids)
    return [] if region_ids.empty?

    placeholders = region_ids.map { "?" }.join(",")
    base_sql = sanitize_sql_array(
      [ "WITH RECURSIVE tree AS (
          SELECT id FROM regions WHERE id IN (#{placeholders})
          UNION ALL
          SELECT r.id FROM regions r JOIN tree t ON r.parent_id = t.id
        )
        SELECT id FROM tree", *region_ids.map(&:to_i) ]
    )
    connection.select_values(base_sql).map(&:to_i)
  end

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

    # Combined relevance score: importance (level + population) minus distance penalty.
    # Higher score = more relevant. log10(pop) keeps populous places competitive even when far.
    # Score = log10(population) + continent_boost + trigram_similarity*5 - distance_penalty
    # - log10(pop): population dominance
    # - continent_boost: keeps continents near top
    # - trigram*5: rewards exact name matches over partial ("Paris" beats "Parish")
    # - distance: tiebreaker for nearby places when zoomed in
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
    geom.buffer(0) rescue geom
  rescue
    nil
  end

  def contains_point?(lat, lng)
    geom = rgeo_boundary
    return false unless geom

    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    point = factory.point(lng.to_f, lat.to_f)
    geom.contains?(point)
  rescue
    false
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

  # Reverse-geocode a point. Returns an ordered list of candidates from most-
  # specific (city) to broadest (country), each carrying everything the caller
  # needs to either show it to the user or resolve it into a Region row via
  # resolve_candidate. Returns [] on failure (no land, API down, no country in
  # the response) — failures aren't cached so retries can succeed.
  #
  # A candidate looks like:
  #   {
  #     name: "Auvergne-Rhône-Alpes",
  #     admin_level: "admin1",
  #     country_code: "FR",
  #     ancestor_chain: [
  #       { name: "France", admin_level: "country", country_code: "FR" }
  #     ]
  #   }
  # The ancestor_chain is the path of parents from country down to (but not
  # including) the candidate itself. Country candidates have an empty chain.
  def self.reverse_geocode(lat, lng)
    cache_key = "maptiler_reverse:v2:#{lat.to_f.round(3)}:#{lng.to_f.round(3)}"
    Rails.cache.fetch(cache_key, expires_in: 1.day, skip_nil: true) do
      require "net/http"
      key = ENV["MAPTILER_KEY"].presence || "biJMFiy9HEvnGGS540u4"
      uri = URI("https://api.maptiler.com/geocoding/#{lng.to_f},#{lat.to_f}.json")
      # language=en lets us share normalize_admin_name rules (which key off
      # English admin words like "State of", "County"); MapTiler still returns
      # native names for some levels (e.g. Vietnam's "Hà Nội") which the
      # normalizer's unaccent step handles.
      uri.query = URI.encode_www_form(key: key, language: "en")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 3
      http.read_timeout = 5
      response = http.request(Net::HTTP::Get.new(uri))
      next nil unless response.is_a?(Net::HTTPSuccess)

      candidates = build_candidates_from_features(JSON.parse(response.body)["features"])
      candidates.presence
    end || []
  rescue => e
    Rails.logger.warn("MapTiler reverse failed: #{e.message}")
    []
  end

  # MapTiler features come most-specific first. Each feature has a `place_type`
  # like "address" / "municipality" / "region" / "country". The same admin level
  # surfaces under different place_types across countries, so we map by-priority:
  #   country  ← place_type "country"
  #   admin1   ← "region" or "subregion" (when subregion isn't the country itself)
  #   admin2   ← "county", or "subregion" if it wasn't claimed for admin1
  #   city     ← first match in CITY_TYPE_PRIORITY
  #
  # We don't try to disambiguate which slot a given feature *should* live in —
  # we just produce one candidate per level we can identify. The caller resolves
  # whichever the user picks.
  CITY_TYPE_PRIORITY = %w[
    municipality joint_municipality municipal_district sub_municipality
    joint_submunicipality locality place neighbourhood
  ].freeze

  def self.build_candidates_from_features(features)
    return [] if features.blank?

    by_type = {}
    features.each do |f|
      type = Array(f["place_type"]).first
      next unless type && f["text"]
      by_type[type] ||= f
    end
    Array(features.first["context"]).each do |c|
      type = c["id"]&.split(".")&.first
      next unless type && c["text"]
      by_type[type] ||= c
    end

    country = by_type["country"]
    return [] unless country

    cc = (country["country_code"] || country.dig("properties", "country_code"))&.upcase
    return [] unless cc
    country_name = country["text"]

    # Slot the geocoder's features into our admin levels.
    admin1_feature = pick_admin1_feature(by_type, country_name)
    admin2_feature = pick_admin2_feature(by_type, admin1_feature)
    city_feature   = pick_city_feature(by_type)

    # Build each level's entry (sans ancestor_chain) plus a running chain so
    # each candidate's ancestor_chain contains every broader level that was
    # picked. A city candidate can be resolved fully standalone — no re-call to
    # the reverse-geocode needed.
    country_entry = { name: country_name, admin_level: "country", country_code: cc }
    country_candidate = country_entry.merge(ancestor_chain: [])
    chain = [ country_entry ]

    admin1_candidate = nil
    if admin1_feature
      admin1_entry = { name: admin1_feature["text"], admin_level: "admin1", country_code: cc }
      admin1_candidate = admin1_entry.merge(ancestor_chain: chain.dup)
      chain << admin1_entry
    end

    admin2_candidate = nil
    if admin2_feature && admin1_feature
      admin2_entry = { name: admin2_feature["text"], admin_level: "admin2", country_code: cc }
      admin2_candidate = admin2_entry.merge(ancestor_chain: chain.dup)
      chain << admin2_entry
    end

    city_candidate = nil
    if city_feature
      city_name = clean_admin_name(city_feature["text"])
      if city_name.present?
        city_candidate = { name: city_name, admin_level: "city", country_code: cc, ancestor_chain: chain.dup }
      end
    end

    # Most-specific (city) → broadest (country). The UI shows them in this
    # order so the user's "best match" is at the top.
    [ city_candidate, admin2_candidate, admin1_candidate, country_candidate ].compact
  end

  def self.pick_admin1_feature(by_type, country_name)
    [ by_type["region"], by_type["subregion"] ].compact.find { |f| f["text"] != country_name }
  end

  def self.pick_admin2_feature(by_type, admin1_feature)
    return by_type["county"] if by_type["county"]
    # subregion only doubles as admin2 if it wasn't already used for admin1
    sub = by_type["subregion"]
    sub if sub && sub != admin1_feature
  end

  def self.pick_city_feature(by_type)
    CITY_TYPE_PRIORITY.lazy.map { |t| by_type[t] }.find { |f| f }
  end

  # Resolve a candidate hash (as produced by reverse_geocode) to an actual
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
  # insert a new one. Race-safe: if a concurrent request inserts the same row
  # between our find and our insert, the second insert fails normalize matching
  # too (because the column index is non-unique) — accept the rare duplicate;
  # both rows resolve to the same place.
  def self.find_or_create_under(parent, name, level)
    return nil if parent.nil? || name.blank? || !ADMIN_LEVELS.include?(level)
    norm = normalize_admin_name(name)
    return nil if norm.blank?

    scope = where(parent_id: parent.id, admin_level: level, normalized_name: norm)
    existing = scope.order(Arel.sql("COALESCE(regions.population, 0) DESC, regions.id ASC")).first
    return existing if existing

    create!(parent: parent, name: name, admin_level: level)
  end

  # Strip English prefixes that appear in MapTiler names but not in GeoNames.
  # "City of Albany" → "Albany". For "City"/"Town"/"Village"/"Municipality"/
  # "Borough", we require "of" after — otherwise "City Heights" would wrongly
  # become "Heights". "Greater" is stripped unconditionally ("Greater London"
  # → "London") since GeoNames doesn't carry the "Greater" prefix.
  def self.clean_admin_name(name)
    return nil if name.blank?
    cleaned = name.sub(/\A(City|Town|Village|Municipality|Borough)\s+of\s+/i, "")
    cleaned = cleaned.sub(/\AGreater\s+/i, "")
    cleaned.strip.presence || name
  end

  # GeoNames admin1 names and MapTiler's reported names disagree in many countries:
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

  # SQL fragment producing the same normalized form for a column. Use inside
  # WHERE clauses where the comparison needs to happen server-side. Builds a
  # plain string — caller is responsible for ensuring `column` is a trusted
  # identifier (we only pass literal column names).
  def self.normalize_admin_name_sql(column)
    "regexp_replace(" \
      "regexp_replace(" \
        "regexp_replace(" \
          "lower(unaccent(#{column}))," \
          "'^#{ADMIN_PREFIX_RE}\\s+', '', 'i'" \
        ")," \
        "'\\s+#{ADMIN_SUFFIX_RE}$', '', 'i'" \
      ")," \
      "'[^a-z0-9]+', '', 'g'" \
    ")"
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
