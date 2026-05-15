class RegionsController < ApplicationController
  def search
    query = params[:q].to_s.strip
    return render(json: []) if query.length < 2

    map_center = if params[:lat].present? && params[:lng].present?
      { lat: params[:lat].to_f, lng: params[:lng].to_f }
    end

    regions = Region.search(query, map_center: map_center, limit: 20).to_a
    ancestor_map = load_ancestors(regions)

    render json: regions.map { |r|
      ancestors = collect_ancestors(r, ancestor_map)
      {
        id: r.id,
        name: r.name,
        admin_level: r.admin_level,
        parent_id: r.parent_id,
        parent_name: ancestor_display(ancestors, r.admin_level),
        full_name: ancestors.reverse.map(&:name).join(" > ")
      }
    }
  end

  def tree
    parent_id = params[:parent_id]
    regions = if parent_id.present?
      Region.where(parent_id: parent_id).order(:name)
    else
      Region.continents.order(:name)
    end

    region_ids = regions.map(&:id)
    parents_with_children = Region.where(parent_id: region_ids).distinct.pluck(:parent_id).to_set

    render json: regions.map { |r|
      {
        id: r.id,
        name: r.name,
        admin_level: r.admin_level,
        has_children: parents_with_children.include?(r.id)
      }
    }
  end

  # Cap the per-request payload — without this an authenticated user can pass
  # `ids[]` with thousands of region IDs and force thousands of Nominatim fetches
  # in one request, both saturating Nominatim's 1/sec limit and holding a web
  # worker for tens of seconds.
  MAX_BOUNDARIES_PER_REQUEST = 50
  MAX_INLINE_FETCHES_PER_REQUEST = 3

  def boundaries
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?).first(MAX_BOUNDARIES_PER_REQUEST)
    return render(json: { type: "FeatureCollection", features: [] }) if ids.empty?

    regions = Region.where(id: ids)
    inline_budget = MAX_INLINE_FETCHES_PER_REQUEST

    features = regions.flat_map do |r|
      if r.admin_level == "continent"
        if r.boundary.present?
          [ {
            type: "Feature",
            id: r.id,
            geometry: r.boundary,
            properties: { name: r.name, admin_level: r.admin_level }
          } ]
        else
          continent_child_features(r)
        end
      else
        if r.needs_boundary_upgrade? && inline_budget.positive?
          inline_budget -= 1
          r.fetch_real_boundary!
        end
        next [] if r.boundary.blank?

        [ {
          type: "Feature",
          id: r.id,
          geometry: validated_geojson(r),
          properties: { name: r.name, admin_level: r.admin_level }
        } ]
      end
    end

    render json: { type: "FeatureCollection", features: features }
  end

  def fetch_boundary
    region = Region.find(params[:id])
    boundary = region.fetch_real_boundary!

    if boundary
      render json: { id: region.id, boundary: boundary }
    else
      render json: { id: region.id, error: "Could not fetch boundary" }, status: :not_found
    end
  end

  # POST /regions/resolve.json
  #
  # Takes one candidate (as produced by the JS-side Nominatim reverse) and
  # either finds the existing Region row it represents or creates one — plus
  # walks the ancestor chain creating intermediates as needed. Returns the
  # resolved region's id so the caller can add it to a filtered set.
  #
  # Click-time reverse-geocoding lives in the browser (region_filter_controller
  # .js#nominatimReverse) so it (a) shares the rate limit across user IPs
  # rather than chokepointing on the server's IP and (b) uses the same
  # provider as our boundary fetch, so the names we get back match what
  # Nominatim's search endpoint returns when we lazy-fetch the polygon below.
  def resolve
    candidate = candidate_params
    return render(json: { error: "missing fields" }, status: :unprocessable_entity) if candidate.nil?

    region = Region.resolve_candidate(candidate)
    return render(json: { error: "could not resolve" }, status: :not_found) unless region

    # If the row is brand-new, it has no boundary yet. Try to fetch one. If
    # the geocoder gave us a name Nominatim's search can't find a polygon
    # for (e.g. truncated / wrong / too-generic names), don't leave a junk
    # row stranded in the DB — destroy it and tell the client we couldn't
    # resolve. Existing rows with boundary failures are kept (they may have
    # population / bbox / image links that are still useful).
    was_new = region.previously_new_record?
    if region.needs_boundary_upgrade?
      region.fetch_real_boundary!
      if region.boundary.blank? && was_new
        region.destroy
        return render(json: { error: "no boundary available for this region" }, status: :not_found)
      end
    end

    render json: {
      region_id: region.id,
      name: region.name,
      admin_level: region.admin_level,
      boundary_ready: region.boundary.present?
    }
  rescue => e
    Rails.logger.error("[regions#resolve] #{e.class}: #{e.message}")
    render json: { error: "resolution failed" }, status: :internal_server_error
  end

  private

  # Whitelist the candidate JSON. We accept it as nested params or as a JSON
  # blob in `candidate`. The ancestor_chain is structured but bounded — at most
  # 4 entries (country → admin1 → admin2), each with a fixed key set.
  ALLOWED_ADMIN_LEVELS = Region::ADMIN_LEVELS

  def candidate_params
    raw = params[:candidate]
    return nil if raw.blank?

    # Allow either a hash (nested params) or a JSON string (some clients
    # JSON-stringify before posting).
    raw = JSON.parse(raw) rescue nil if raw.is_a?(String)
    return nil unless raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)

    h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.transform_keys(&:to_s)
    name = h["name"].to_s.strip
    level = h["admin_level"].to_s
    cc = h["country_code"].to_s.upcase
    return nil if name.blank? || cc.blank?
    return nil unless ALLOWED_ADMIN_LEVELS.include?(level)

    chain = Array(h["ancestor_chain"]).first(4).map do |entry|
      next nil unless entry.is_a?(Hash) || entry.is_a?(ActionController::Parameters)
      eh = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.transform_keys(&:to_s)
      entry_level = eh["admin_level"].to_s
      next nil unless ALLOWED_ADMIN_LEVELS.include?(entry_level)
      entry_name = eh["name"].to_s.strip
      next nil if entry_name.blank?
      { name: entry_name, admin_level: entry_level, country_code: cc }
    end.compact

    {
      name: name,
      admin_level: level,
      country_code: cc,
      ancestor_chain: chain
    }
  end

  # Walk up to 4 levels (city → admin2 → admin1 → country → continent),
  # one bulk query per level. Returns id → region map of all ancestors.
  def load_ancestors(regions)
    ancestor_map = regions.index_by(&:id)
    current_level = regions
    4.times do
      parent_ids = current_level.filter_map(&:parent_id).reject { |id| ancestor_map.key?(id) }.uniq
      break if parent_ids.empty?
      next_level = Region.where(id: parent_ids).to_a
      next_level.each { |r| ancestor_map[r.id] = r }
      current_level = next_level
    end
    ancestor_map
  end

  def collect_ancestors(region, ancestor_map)
    chain = [ region ]
    current = region
    while current.parent_id && (parent = ancestor_map[current.parent_id])
      chain << parent
      current = parent
      break if chain.size > 5
    end
    chain
  end

  def ancestor_display(chain, level)
    case level
    when "city", "admin2"
      a1 = chain.find { |r| r.admin_level == "admin1" }
      c = chain.find { |r| r.admin_level == "country" }
      [ a1&.name, c&.name ].compact.join(", ")
    when "admin1"
      chain.find { |r| r.admin_level == "country" }&.name
    when "country"
      chain.find { |r| r.admin_level == "continent" }&.name
    end
  end

  def continent_child_features(continent)
    children = continent.children.to_a

    children.select(&:needs_boundary_upgrade?).first(5).each do |c|
      c.fetch_real_boundary!
    end

    children.select { |c| c.boundary.present? }.map do |country|
      {
        type: "Feature",
        id: country.id,
        geometry: validated_geojson(country),
        properties: { name: country.name, admin_level: "country" }
      }
    end
  end

  def validated_geojson(region)
    geom = region.rgeo_boundary
    return region.boundary unless geom
    RGeo::GeoJSON.encode(geom)
  rescue
    region.boundary
  end
end
