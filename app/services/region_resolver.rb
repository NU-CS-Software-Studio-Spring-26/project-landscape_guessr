# Unifies the AI-emitted region descriptor (Mode A in-DB named region or
# Mode B POI hull, with optional radius transform) into a `Result` with a
# bbox and optional polygon. Importers consume this; they don't know which
# mode produced it.
#
# Descriptor shape (any of):
#   { mode: "named", name: "Chicago", admin_level: "city", parent_name: "Illinois", radius_meters: nil }
#   { mode: "pois",  pois: ["Eiffel Tower"], label: nil, radius_meters: 2000 }
#   { mode: "pois",  pois: ["San Francisco", "Oakland", "San Jose"], label: "Bay Area" }
#
# Returns nil if invalid (caller refuses the prompt with a helpful message).
class RegionResolver
  Result = Struct.new(
    :bbox, :polygon, :label, :source,
    :admin_level, :parent_name, :region_id,
    keyword_init: true
  ) do
    # When an importer still expects the old { name:, admin_level:, parent_name: }
    # hash (Wikidata polygon refinement path), Mode A returns a usable one and
    # other modes return nil (no in-DB Region for polygon refine).
    def to_legacy_filter
      return nil unless source == :named
      { name: label, admin_level: admin_level, parent_name: parent_name }
    end
  end

  # Whole-globe region for "streets around the world" / "anywhere". Latitude
  # is trimmed to the populated band (skips the empty polar caps) and the full
  # longitude span; no polygon — the whole world has nothing to refine against.
  WORLD_BBOX = { min_lat: -58.0, max_lat: 74.0, min_lng: -180.0, max_lng: 180.0 }.freeze

  # Cap for radius transform — anything above 50km is almost certainly a
  # prompt that should use Mode A (city/state level) instead.
  MAX_RADIUS_METERS = 50_000
  # Reject hulls larger than this (likely the AI listed unrelated POIs).
  MAX_HULL_AREA_KM2 = 100_000.0
  # Hulls smaller than this get padded out so the importer has something
  # to query (single-POI Mode B without radius would otherwise have a
  # point bbox).
  MIN_HULL_AREA_KM2 = 0.25  # 500m × 500m

  # Builds a Result centred on a single coordinate. Used by Commons to
  # anchor a `nearcoord:` filter on a region-less subject's own location
  # (e.g. Mount Fuji's P625) so deepcategory pollution + far-flung
  # mistagged files get pruned. The bbox is small on purpose — the Commons
  # hex-lattice turns it into a single 30km nearcoord probe at the centre.
  def self.around_point(lat:, lng:, radius_m: 500.0, label: nil)
    Result.new(
      bbox: bbox_around(lat, lng, radius_m),
      polygon: nil, label: label, source: :point,
      admin_level: nil, parent_name: nil, region_id: nil
    )
  end

  def self.resolve(descriptor)
    return nil if descriptor.blank?
    d = descriptor.transform_keys(&:to_sym) rescue descriptor

    # Whole-world prompts ("streets around the world"): no named region to
    # look up — hand back the global bbox directly.
    return world_result if d[:mode].to_s == "global" || d[:admin_level].to_s == "world"

    # Backwards-compat: pre-v2 ai_region_filter was a bare {name:,
    # parent_name:, admin_level:} hash. Treat as Mode A.
    mode = d[:mode].to_s
    if mode.blank? && d[:name].present? && d[:admin_level].present?
      mode = "named"
    end

    base = case mode
    when "named" then resolve_named(d)
    when "pois"  then resolve_pois(d)
    end
    return nil unless base

    radius = d[:radius_meters]
    radius.present? ? apply_radius(base, radius.to_f) : base
  end

  def self.world_result
    Result.new(
      bbox: WORLD_BBOX.dup, polygon: nil, label: "the world",
      source: :global, admin_level: "world", parent_name: nil, region_id: nil
    )
  end

  def self.resolve_named(d)
    region = WikidataImporter.resolve_region_filter(
      name: d[:name], admin_level: d[:admin_level], parent_name: d[:parent_name]
    )
    return nil unless region

    # Force boundary upgrade for point-bbox seeded rows (cities) — same fix
    # as wikidata Paris path. Without this, named cities have point bboxes.
    WikidataImporter.ensure_real_bbox!(region)
    # Also ensure a real boundary polygon (no-op for cities that just got one,
    # or for continents). Countries/states otherwise have only a rectangular
    # bbox, so Commons/Mapillary would import points from neighbours sharing
    # the bbox (e.g. "streets in Sweden" landing in Finland/Latvia). Cheap and
    # cached: ~0.9s once per region via Nominatim, then stored.
    region.fetch_real_boundary! if region.boundary.blank?
    return nil unless region.min_lat && region.max_lat && region.min_lng && region.max_lng

    Result.new(
      bbox: {
        min_lat: region.min_lat, max_lat: region.max_lat,
        min_lng: region.min_lng, max_lng: region.max_lng
      },
      polygon: region.rgeo_boundary,
      label: region.name,
      source: :named,
      admin_level: d[:admin_level],
      parent_name: d[:parent_name],
      region_id: region.id
    )
  end

  def self.resolve_pois(d)
    queries = Array(d[:pois]).first(10).map(&:to_s).reject(&:blank?)
    return nil if queries.empty?

    candidates_by_query = GeocoderService.geocode_many(queries: queries)
    bests = queries.filter_map { |q| GeocoderService.best_match(q) || candidates_by_query[q]&.first }
    return nil if bests.empty?

    bbox = hull_bbox(bests)
    bbox = pad_bbox_to_min_area(bbox, MIN_HULL_AREA_KM2)
    area = GeocoderService.bbox_area_km2(bbox)
    return nil if area > MAX_HULL_AREA_KM2

    Result.new(
      bbox: bbox,
      polygon: nil,
      label: d[:label].presence || queries.first,
      source: :pois,
      admin_level: nil,
      parent_name: nil,
      region_id: nil
    )
  end

  # Recenters a square of radius_meters around the base centroid. Drops the
  # polygon (caller wants "within Nm of centroid", not "intersect base").
  def self.apply_radius(base, radius_meters)
    return nil if radius_meters <= 0 || radius_meters > MAX_RADIUS_METERS

    center_lat = (base.bbox[:min_lat] + base.bbox[:max_lat]) / 2.0
    center_lng = (base.bbox[:min_lng] + base.bbox[:max_lng]) / 2.0
    bbox = bbox_around(center_lat, center_lng, radius_meters)

    Result.new(
      bbox: bbox,
      # A circular polygon so "within Nm of X" is enforced as an actual
      # circle — the bbox alone is a square whose corners reach ~1.4×N, which
      # is what let "10 miles around Yellowstone" import points well outside
      # the intended radius. Importers refine against this.
      polygon: circle_polygon(center_lat, center_lng, radius_meters),
      label: "within #{radius_meters.to_i}m of #{base.label}",
      source: base.source,
      admin_level: base.admin_level,
      parent_name: base.parent_name,
      region_id: base.region_id
    )
  end

  # Compute a bbox that covers a list of POI candidates. For each POI, we
  # union the candidate's own bbox (so a neighborhood with a real polygon
  # contributes its full extent, not just its centroid).
  def self.hull_bbox(candidates)
    boxes = candidates.filter_map { |c| c[:bbox] }
    points = candidates.map { |c| [ c[:lat], c[:lng] ] }

    lats = boxes.flat_map { |b| [ b[:min_lat], b[:max_lat] ] } + points.map(&:first)
    lngs = boxes.flat_map { |b| [ b[:min_lng], b[:max_lng] ] } + points.map(&:last)
    {
      min_lat: lats.min, max_lat: lats.max,
      min_lng: lngs.min, max_lng: lngs.max
    }
  end

  # Pad a degenerate (point) bbox out to at least `min_area_km2`.
  def self.pad_bbox_to_min_area(bbox, min_area_km2)
    area = GeocoderService.bbox_area_km2(bbox)
    return bbox if area >= min_area_km2

    center_lat = (bbox[:min_lat] + bbox[:max_lat]) / 2.0
    center_lng = (bbox[:min_lng] + bbox[:max_lng]) / 2.0
    radius_m = Math.sqrt(min_area_km2) * 1000.0 / 2.0
    bbox_around(center_lat, center_lng, radius_m)
  end

  # An approximate circle (segments-gon) centered at (lat, lng), as an RGeo
  # spherical polygon. Used to enforce radius prompts ("within Nm of X") as a
  # real circle rather than the enclosing square bbox.
  def self.circle_polygon(lat, lng, radius_m, segments: 64)
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    dlat = radius_m / 111_320.0
    dlng = radius_m / (111_320.0 * Math.cos(lat * Math::PI / 180.0))
    pts = (0..segments).map do |i|
      theta = 2.0 * Math::PI * i / segments
      factory.point(lng + dlng * Math.cos(theta), lat + dlat * Math.sin(theta))
    end
    factory.polygon(factory.linear_ring(pts))
  rescue StandardError => e
    Rails.logger.warn "[region circle] #{e.class}: #{e.message.slice(0, 120)}"
    nil
  end

  # Compute a bbox centered at (lat, lng) extending radius_m in each direction.
  # Conservative cos(lat) factor for the longitude span.
  def self.bbox_around(lat, lng, radius_m)
    dlat = radius_m / 111_320.0
    dlng = radius_m / (111_320.0 * Math.cos(lat * Math::PI / 180.0))
    {
      min_lat: lat - dlat, max_lat: lat + dlat,
      min_lng: lng - dlng, max_lng: lng + dlng
    }
  end
end
